import Foundation

/// How the classifier did on one turn, for telemetry and evals.
public struct ClassifierRun: Equatable, Sendable {
    /// Nil if the classifier failed.
    public var classification: RouteClassification?
    public var latency: TimeInterval
    /// Why the classifier failed, if it did.
    public var failure: FailureCause?

    public init(classification: RouteClassification?, latency: TimeInterval, failure: FailureCause? = nil) {
        self.classification = classification
        self.latency = latency
        self.failure = failure
    }
}

/// The router's answer for one turn.
public enum RoutingResult: Equatable, Sendable {
    case routed(RouteDecision, classifier: ClassifierRun?)
    case blocked(reason: String)

    public var decision: RouteDecision? {
        if case .routed(let decision, _) = self { decision } else { nil }
    }
}

/// Picks a route for each turn: hard rules first, then the on-device classifier (SPEC §6).
public struct Router: Sendable {
    public var mapping: ComplexityMapping
    private let classifier: any RouteClassifier

    public init(classifier: any RouteClassifier, mapping: ComplexityMapping = .standard) {
        self.classifier = classifier
        self.mapping = mapping
    }

    /// - Parameter classifyDecidedTurns: also classify turns a rule settled, to choose a
    ///   structured output (e.g. a receipt for a scanned image). It never changes the route.
    public func route(_ prompt: String, input: RoutingInput, classifyDecidedTurns: Bool = false) async -> RoutingResult {
        let allowed: [Route]
        switch RoutingRules.evaluate(input) {
        case .decided(let decision):
            guard classifyDecidedTurns else { return .routed(decision, classifier: nil) }
            return .routed(decision, classifier: await classify(prompt, previous: input.previousPrompt))
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .open(let routes):
            allowed = routes
        }

        let run = await classify(prompt, previous: input.previousPrompt)
        return .routed(Self.decide(run, mapping: mapping, allowed: allowed, input: input), classifier: run)
    }

    private func classify(_ prompt: String, previous: String?) async -> ClassifierRun {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let classification = try await classifier.classify(prompt, previous: previous)
            return ClassifierRun(classification: classification, latency: start.duration(to: clock.now).seconds)
        } catch {
            return ClassifierRun(classification: nil, latency: start.duration(to: clock.now).seconds, failure: FailureCause(error))
        }
    }

    /// The classifier step as a pure function: map the complexity to a route and fit it to
    /// what's allowed. A failed or unusable classification falls back to Apple Cloud.
    static func decide(
        _ run: ClassifierRun,
        mapping: ComplexityMapping,
        allowed: [Route],
        input: RoutingInput
    ) -> RouteDecision {
        guard let classification = run.classification, let target = mapping.route(for: classification.complexity) else {
            let route = RoutingRules.resolve(.appleCloud, allowed: allowed) ?? allowed[0]
            let cause = run.failure.map { " (\($0.label))" } ?? ""
            return RouteDecision(route: route, reason: "Couldn't classify\(cause), so using a mid-size model", source: .classifier)
        }
        // `allowed` is never empty for an open outcome.
        let route = RoutingRules.resolve(target, allowed: allowed) ?? allowed[0]
        let reason: String
        if route == target {
            reason = classification.reason
        } else if input.isAvailable(target), !input.fits(target) {
            reason = "\(classification.reason) (too long for \(target.displayName))"
        } else {
            reason = "\(classification.reason) (\(target.displayName) unavailable)"
        }
        return RouteDecision(route: route, reason: reason, source: .classifier)
    }
}
