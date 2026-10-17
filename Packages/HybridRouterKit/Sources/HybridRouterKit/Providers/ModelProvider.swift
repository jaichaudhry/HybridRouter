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
    /// The model's name in reasons and badges, e.g. "Claude". Defaults to the route's name.
    var displayName: String { get }
    var model: any LanguageModel { get }
    var availability: ProviderAvailability { get }
    /// The model's context window in tokens, or nil if unknown (treated as unlimited).
    func contextSize() async -> Int?
    /// A cap on reply length, if the route sets one. A reply that reaches it was cut off.
    var maximumResponseTokens: Int? { get }
    /// True for a stand-in model serving another route (e.g. Apple Cloud simulated on-device).
    var isSimulated: Bool { get }
}

extension ModelProvider {
    public var displayName: String { route.displayName }
    public var maximumResponseTokens: Int? { nil }
    public var isSimulated: Bool { false }
}
