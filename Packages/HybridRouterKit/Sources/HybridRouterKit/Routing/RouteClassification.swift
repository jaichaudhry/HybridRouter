import FoundationModels

/// The on-device classifier's read of a turn.
///
/// The reason shown to the user is derived from these labels rather than generated: on an
/// M1 Max, generating it added about 600 ms per turn.
@Generable
public struct RouteClassification: Equatable, Sendable {
    @Guide(.anyOf(["simple", "moderate", "complex"]))
    public var complexity: String

    @Guide(.anyOf(["chat", "rewrite", "extract", "summarize", "plan", "reason", "code"]))
    public var task: String

    public init(complexity: String, task: String) {
        self.complexity = complexity
        self.task = task
    }

    /// A short reason for the route badge, e.g. "Complex reasoning".
    public var reason: String {
        let subject = switch task {
        case "chat": "conversation"
        case "rewrite": "rewrite"
        case "extract": "extraction"
        case "summarize": "summary"
        case "plan": "planning"
        case "reason": "reasoning"
        case "code": "coding"
        default: "request"
        }
        let size = switch complexity {
        case "simple": "Quick"
        case "moderate": "Multi-step"
        default: "Complex"
        }
        return "\(size) \(subject)"
    }
}

/// Which route each complexity maps to. Scenarios can change it.
public struct ComplexityMapping: Equatable, Sendable {
    public var simple: Route
    public var moderate: Route
    public var complex: Route

    public static let standard = ComplexityMapping(simple: .onDevice, moderate: .appleCloud, complex: .claude)

    public init(simple: Route, moderate: Route, complex: Route) {
        self.simple = simple
        self.moderate = moderate
        self.complex = complex
    }

    /// The mapped route, or nil for a complexity the classifier shouldn't produce.
    public func route(for complexity: String) -> Route? {
        switch complexity {
        case "simple": simple
        case "moderate": moderate
        case "complex": complex
        default: nil
        }
    }
}
