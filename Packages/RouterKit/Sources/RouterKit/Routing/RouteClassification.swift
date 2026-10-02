import FoundationModels

/// The on-device classifier's read of a turn (SPEC §6 Layer B).
@Generable
public struct RouteClassification: Equatable, Sendable {
    @Guide(description: "How hard the request is", .anyOf(["simple", "moderate", "complex"]))
    public var complexity: String

    @Guide(description: "What the user wants", .anyOf(["chat", "rewrite", "extract", "summarize", "plan", "reason", "code"]))
    public var task: String

    @Guide(description: "One short sentence, shown to the user, saying why this route fits")
    public var reason: String

    public init(complexity: String, task: String, reason: String) {
        self.complexity = complexity
        self.task = task
        self.reason = reason
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
