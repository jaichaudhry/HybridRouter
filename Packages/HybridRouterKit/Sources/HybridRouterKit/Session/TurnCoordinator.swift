import FoundationModels
import OSLog

/// A schema a scenario wants for certain kinds of turns, e.g. an itinerary for planning turns.
public struct StructuredOutput: Sendable {
    public var schema: GenerationSchema
    /// Classifier tasks that get the schema, e.g. ["plan"].
    public var tasks: Set<String>
    /// Classifier complexities that get the schema; simple turns usually want plain text.
    public var complexities: Set<String>
    /// Only for turns with an attached image, e.g. a receipt.
    public var requiresImage: Bool
    /// An extra check on the message, for formats a label alone can't pick: "5 weekend trip
    /// ideas" can be labeled planning without asking for a day-by-day itinerary.
    public var matchesPrompt: (@Sendable (String) -> Bool)?

    public init(
        schema: GenerationSchema,
        tasks: Set<String>,
        complexities: Set<String> = ["moderate", "complex"],
        requiresImage: Bool = false,
        matchesPrompt: (@Sendable (String) -> Bool)? = nil
    ) {
        self.schema = schema
        self.tasks = tasks
        self.complexities = complexities
        self.requiresImage = requiresImage
        self.matchesPrompt = matchesPrompt
    }

    /// Whether a turn with this classification should be structured. If the classifier
    /// couldn't label the turn, it stays plain text.
    public func applies(to classification: RouteClassification?, hasImage: Bool = false, prompt: String = "") -> Bool {
        guard let classification, hasImage || !requiresImage else { return false }
        guard matchesPrompt?(prompt) ?? true else { return false }
        return tasks.contains(classification.task) && complexities.contains(classification.complexity)
    }
}

/// Runs one user turn end to end: route it, answer it, and escalate on failure.
@MainActor
public struct TurnCoordinator {
    public struct Request: Sendable {
        public var prompt: String
        public var override: Route?
        /// Why the turn must stay off the cloud model, or nil.
        public var privacyReason: String?
        public var images: [ImageInput]
        /// Structured outputs the scenario wants for some turns; the first that applies is used.
        public var structuredOutputs: [StructuredOutput]

        public init(
            prompt: String,
            images: [ImageInput] = [],
            override: Route? = nil,
            privacyReason: String? = nil,
            structuredOutputs: [StructuredOutput] = []
        ) {
            self.prompt = prompt
            self.images = images
            self.override = override
            self.privacyReason = privacyReason
            self.structuredOutputs = structuredOutputs
        }
    }

    public enum Event: Sendable {
        /// A route was chosen, or the turn escalated to a new one.
        case routed(RouteDecision)
        case partial(TurnContent)
    }

    public struct Outcome: Sendable {
        /// The final reply, if any step succeeded.
        public var content: TurnContent?
        /// The route that produced the reply, or the last one tried.
        public var decision: RouteDecision?
        /// Every step that ran, including failed attempts.
        public var steps: [StepMetrics]
        public var classifier: ClassifierRun?
        /// Shown to the user when the turn couldn't be answered.
        public var failure: String?
    }

    public var router: Router
    public var policy: EscalationPolicy
    public var estimator: any TokenEstimator
    /// Share of each model's context window the router may plan to use.
    public var contextMargin: Double
    private let isOnline: @Sendable () -> Bool
    private static let logger = Logger(subsystem: "dev.hybridrouter", category: "routing")
    /// A rough allowance per attached image. The on-device tokenizer can't count images.
    static let imageTokens = 800

    public init(
        router: Router,
        policy: EscalationPolicy = EscalationPolicy(),
        estimator: any TokenEstimator,
        contextMargin: Double = 0.9,
        isOnline: @escaping @Sendable () -> Bool
    ) {
        self.router = router
        self.policy = policy
        self.estimator = estimator
        self.contextMargin = contextMargin
        self.isOnline = isOnline
    }

    /// Warms the router's classifier, e.g. when the app comes to the foreground.
    public func prewarm() async {
        await router.prewarm()
    }

    public func run(
        _ request: Request,
        in session: RoutedSession,
        onEvent: (Event) -> Void = { _ in }
    ) async -> Outcome {
        var input = await routingInput(for: request, in: session)
        var decision: RouteDecision
        let classifier: ClassifierRun?
        // With structured outputs on offer, rule-decided turns (images, privacy) are still
        // classified on-device so a scan can get its receipt card.
        let classifyDecided = !request.structuredOutputs.isEmpty
        switch await router.route(request.prompt, input: input, classifyDecidedTurns: classifyDecided) {
        case .blocked(let reason):
            return Outcome(content: nil, decision: nil, steps: [], classifier: nil, failure: reason)
        case .routed(let routed, let run):
            decision = routed
            classifier = run
        }

        let structured = request.structuredOutputs.first {
            $0.applies(to: classifier?.classification, hasImage: !request.images.isEmpty, prompt: request.prompt)
        }
        var steps: [StepMetrics] = []
        var escalationCause: FailureCause?
        var tried: Set<Route> = []
        var retries = 0
        while true {
            onEvent(.routed(decision))
            tried.insert(decision.route)
            let cause: FailureCause
            func record(_ metrics: StepMetrics, failure: FailureCause?) {
                var metrics = metrics
                metrics.escalationCause = escalationCause?.label
                metrics.classifierLatency = steps.isEmpty ? classifier?.latency : nil
                metrics.failure = failure?.label
                steps.append(metrics)
            }
            do {
                let result = try await session.respond(
                    to: request.prompt,
                    images: request.images,
                    decision: decision,
                    schema: structured?.schema,
                    isPrivate: request.privacyReason != nil
                ) { onEvent(.partial($0)) }
                guard result.content.isEmpty else {
                    record(result.metrics, failure: nil)
                    return Outcome(
                        content: result.content,
                        decision: decision,
                        steps: steps,
                        classifier: classifier,
                        failure: isTruncated(result, in: session) ? "Reply was cut off at the length limit." : nil
                    )
                }
                // Claude refusals and truncation return normally with nothing in them.
                session.discardLastTurn()
                cause = .emptyReply
                record(result.metrics, failure: cause)
            } catch let failure as RoutedSession.StepFailure {
                cause = FailureCause(failure)
                record(failure.metrics, failure: cause)
            } catch RoutedSession.Error.busy {
                // Another turn is running on this session; retrying elsewhere would hit the same.
                return Outcome(content: nil, decision: decision, steps: steps, classifier: classifier,
                               failure: "Another reply is still in progress.")
            } catch {
                cause = FailureCause(error)
            }

            // Re-check what's reachable: the network or a route may have gone away mid-turn.
            input = await refreshed(input, in: session)
            switch policy.next(after: cause, decision: decision, input: input, tried: tried, retries: retries) {
            case .retry(let next, let delay):
                Self.logger.info("Retrying \(decision.route.rawValue, privacy: .public) → \(next.route.rawValue, privacy: .public): \(cause.label, privacy: .public)")
                retries = next.route == decision.route ? retries + 1 : 0
                escalationCause = cause
                decision = next
                if delay > .zero {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return Outcome(content: nil, decision: decision, steps: steps, classifier: classifier,
                                       failure: "\(input.labels.name(decision.route)) couldn't answer (\(FailureCause.cancelled.label)).")
                    }
                }
            case .stop(let reason):
                Self.logger.notice("Turn failed on \(decision.route.rawValue, privacy: .public): \(cause.label, privacy: .public)")
                return Outcome(content: nil, decision: decision, steps: steps, classifier: classifier, failure: reason)
            }
        }
    }

    /// Whether a reply reached the route's length cap. Claude's max_tokens stop doesn't throw,
    /// and the turn's output tokens add up every request in a tool loop, so only a turn without
    /// tool calls (one request) can be judged from them.
    private func isTruncated(_ result: RoutedSession.TurnResult, in session: RoutedSession) -> Bool {
        guard let limit = session.provider(for: result.metrics.route).maximumResponseTokens,
              result.metrics.usage.output >= limit else { return false }
        let turn = session.transcript.reversed().prefix { !$0.isPrompt }
        return !turn.contains { if case .toolCalls = $0 { true } else { false } }
    }

    /// `input` with availability and connectivity as they are now.
    private func refreshed(_ input: RoutingInput, in session: RoutedSession) async -> RoutingInput {
        var input = input
        input.isOnline = isOnline()
        for route in Route.allCases {
            input.availability[route] = session.availability(of: route)
        }
        return input
    }

    func routingInput(for request: Request, in session: RoutedSession) async -> RoutingInput {
        var availability: [Route: ProviderAvailability] = [:]
        var budgets: [Route: Int] = [:]
        var vision: Set<Route> = []
        for route in Route.allCases {
            let provider = session.provider(for: route)
            availability[route] = provider.availability
            if let size = await provider.contextSize() {
                budgets[route] = Int(Double(size) * contextMargin)
            }
            if provider.model.capabilities.contains(.vision) {
                vision.insert(route)
            }
        }
        // Each route is checked against the history it will see: with a window, a long chat can
        // still fit the on-device model.
        let history = Array(session.transcript)
        let fixed = session.fixedPromptText + "\n" + request.prompt
        let images = Self.imageTokens * request.images.count
        let fullEstimate = await estimator.estimate(history: history, prompt: fixed) + images
        // What the turn needs without the earlier conversation, so a route too small for the
        // whole chat can still answer from its recent turns. Only counted when something doesn't fit.
        let needsTrimming = budgets.values.contains { fullEstimate > $0 }
        let base = needsTrimming ? await estimator.estimate(history: [], prompt: fixed) + images : nil
        var perRoute: [Route: Int] = [:]
        for route in Route.allCases where session.historyPolicy.limits[route] != nil {
            let visible = session.historyPolicy.visibleHistory(history, for: route)
            perRoute[route] = visible.count == history.count
                ? fullEstimate
                : await estimator.estimate(history: visible, prompt: fixed) + images
        }
        return RoutingInput(
            override: request.override,
            privacyReason: request.privacyReason,
            isOnline: isOnline(),
            availability: availability,
            estimatedTokens: fullEstimate,
            estimatedTokensByRoute: perRoute,
            baseTokens: base,
            contextBudgets: budgets,
            hasImage: !request.images.isEmpty,
            visionRoutes: vision,
            followsUpOn: FollowUp.isBare(request.prompt) ? session.lastRoute : nil,
            previousRoute: session.lastRoute,
            hasPrivateHistory: !session.privatePromptIDs.isEmpty,
            previousPrompt: session.lastPromptText,
            namedRoute: RouteMention.named(in: request.prompt),
            labels: session.labels
        )
    }
}
