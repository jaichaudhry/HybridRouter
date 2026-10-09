import FoundationModels
import OSLog

/// A schema a scenario wants for certain kinds of turns, e.g. an itinerary for planning turns.
public struct StructuredOutput: Sendable {
    public var schema: GenerationSchema
    /// Classifier tasks that get the schema, e.g. ["plan"].
    public var tasks: Set<String>
    /// Classifier complexities that get the schema; simple turns usually want plain text.
    public var complexities: Set<String>

    public init(schema: GenerationSchema, tasks: Set<String>, complexities: Set<String> = ["moderate", "complex"]) {
        self.schema = schema
        self.tasks = tasks
        self.complexities = complexities
    }

    /// Whether a turn with this classification should be structured. Turns the classifier
    /// didn't see (overrides, rule decisions) stay plain text.
    public func applies(to classification: RouteClassification?) -> Bool {
        guard let classification else { return false }
        return tasks.contains(classification.task) && complexities.contains(classification.complexity)
    }
}

/// Runs one user turn end to end: route it, answer it, and escalate on failure (SPEC §6).
@MainActor
public struct TurnCoordinator {
    public struct Request: Sendable {
        public var prompt: String
        public var override: Route?
        /// Why the turn must stay off Claude, or nil.
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

    public func run(
        _ request: Request,
        in session: RoutedSession,
        onEvent: (Event) -> Void = { _ in }
    ) async -> Outcome {
        let input = await routingInput(for: request, in: session)
        var decision: RouteDecision
        let classifier: ClassifierRun?
        switch await router.route(request.prompt, input: input) {
        case .blocked(let reason):
            return Outcome(content: nil, decision: nil, steps: [], classifier: nil, failure: reason)
        case .routed(let routed, let run):
            decision = routed
            classifier = run
        }

        let structured = request.structuredOutputs.first { $0.applies(to: classifier?.classification) }
        var steps: [StepMetrics] = []
        var escalationCause: FailureCause?
        while true {
            onEvent(.routed(decision))
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
                    // A reply that reached the length cap stopped early. Keep it, but say so.
                    let limit = session.provider(for: decision.route).maximumResponseTokens
                    let truncated = limit.map { result.metrics.usage.output >= $0 } ?? false
                    return Outcome(
                        content: result.content,
                        decision: decision,
                        steps: steps,
                        classifier: classifier,
                        failure: truncated ? "Reply was cut off at the length limit." : nil
                    )
                }
                // Claude refusals and truncation return normally with nothing in them.
                session.discardLastTurn()
                cause = .emptyReply
                record(result.metrics, failure: cause)
            } catch let failure as RoutedSession.StepFailure {
                cause = FailureCause(failure)
                record(failure.metrics, failure: cause)
            } catch {
                cause = FailureCause(error)
            }

            switch policy.next(after: cause, decision: decision, input: input) {
            case .retry(let next):
                Self.logger.info("Escalating \(decision.route.rawValue, privacy: .public) → \(next.route.rawValue, privacy: .public): \(cause.label, privacy: .public)")
                escalationCause = cause
                decision = next
            case .stop(let reason):
                Self.logger.notice("Turn failed on \(decision.route.rawValue, privacy: .public): \(cause.label, privacy: .public)")
                return Outcome(content: nil, decision: decision, steps: steps, classifier: classifier, failure: reason)
            }
        }
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
        return RoutingInput(
            override: request.override,
            privacyReason: request.privacyReason,
            isOnline: isOnline(),
            availability: availability,
            estimatedTokens: await estimator.estimate(history: Array(session.transcript), prompt: request.prompt),
            contextBudgets: budgets,
            hasImage: !request.images.isEmpty,
            visionRoutes: vision,
            followsUpOn: FollowUp.isBare(request.prompt) ? session.lastRoute : nil,
            previousPrompt: session.lastPromptText
        )
    }
}
