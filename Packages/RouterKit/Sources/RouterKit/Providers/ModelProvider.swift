import FoundationModels

/// Whether a route can take a turn right now, and if not, a reason the UI can show.
public enum ProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

/// One model behind a route. Providers are injected so tests can use fakes.
public protocol ModelProvider: Sendable {
    var route: Route { get }
    /// Identifier used for telemetry and the cost table, e.g. "claude-sonnet-5-5".
    var modelID: String { get }
    var model: any LanguageModel { get }
    var availability: ProviderAvailability { get }
    /// The model's context window in tokens, or nil if unknown (treated as unlimited).
    func contextSize() async -> Int?
}
