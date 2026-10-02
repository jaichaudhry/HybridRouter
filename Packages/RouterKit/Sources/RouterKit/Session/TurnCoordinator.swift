import FoundationModels

/// Runs one user turn end to end: route it, answer it, and escalate on failure (SPEC §6).
@MainActor
public struct TurnCoordinator {
    public struct Request: Sendable {
        public var prompt: String
        public var override: Route?
        /// Why the turn must stay off Claude, or nil.
        public var privacyReason: String?
        public var hasImage: Bool
        /// Structured output for this turn, if the scenario wants it.
        public var schema: GenerationSchema?

        public init(prompt: String, override: Route? = nil, privacyReason: String? = nil, hasImage: Bool = false, schema: GenerationSchema? = nil) {
            self.prompt = prompt
            self.override = override
            self.privacyReason = privacyReason
            self.hasImage = hasImage
            self.schema = schema
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
        /// Every step that ran, including failed attempts that returned normally.
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

        var steps: [StepMetrics] = []
        var escalationCause: FailureCause?
        while true {
            onEvent(.routed(decision))
            let cause: FailureCause
            do {
                let result = try await session.respond(to: request.prompt, decision: decision, schema: request.schema) {
                    onEvent(.partial($0))
                }
                var metrics = result.metrics
                metrics.escalationCause = escalationCause?.label
                metrics.classifierLatency = steps.isEmpty ? classifier?.latency : nil
                steps.append(metrics)
                guard result.content.isEmpty else {
                    return Outcome(content: result.content, decision: decision, steps: steps, classifier: classifier, failure: nil)
                }
                // Claude refusals and truncation return normally with nothing in them.
                session.discardLastTurn()
                cause = .emptyReply
            } catch {
                cause = FailureCause(error)
            }

            switch policy.next(after: cause, decision: decision, input: input) {
            case .retry(let next):
                escalationCause = cause
                decision = next
            case .stop(let reason):
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
            hasImage: request.hasImage,
            visionRoutes: vision
        )
    }
}
