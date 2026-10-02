import Foundation

/// How the classifier did on one turn, for telemetry and evals.
public struct ClassifierRun: Equatable, Sendable {
    /// Nil if the classifier failed.
    public var classification: RouteClassification?
    public var latency: TimeInterval
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

    public func route(_ prompt: String, input: RoutingInput) async -> RoutingResult {
        let allowed: [Route]
        switch RoutingRules.evaluate(input) {
        case .decided(let decision):
            return .routed(decision, classifier: nil)
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .open(let routes):
            allowed = routes
        }

        let clock = ContinuousClock()
        let start = clock.now
        let classification = try? await classifier.classify(prompt)
        let run = ClassifierRun(classification: classification, latency: start.duration(to: clock.now).seconds)
        return .routed(Self.decide(classification, mapping: mapping, allowed: allowed), classifier: run)
    }

    /// The classifier step as a pure function: map the complexity to a route and fit it to
    /// what's allowed. A failed or unusable classification falls back to Apple Cloud.
    static func decide(_ classification: RouteClassification?, mapping: ComplexityMapping, allowed: [Route]) -> RouteDecision {
        guard let classification, let target = mapping.route(for: classification.complexity) else {
            let route = RoutingRules.resolve(.appleCloud, allowed: allowed) ?? allowed[0]
            return RouteDecision(route: route, reason: "Couldn't classify, so using a mid-size model", source: .classifier)
        }
        // `allowed` is never empty for an open outcome.
        let route = RoutingRules.resolve(target, allowed: allowed) ?? allowed[0]
        let reason = route == target
            ? classification.reason
            : "\(classification.reason) (\(target.displayName) unavailable)"
        return RouteDecision(route: route, reason: reason, source: .classifier)
    }
}
