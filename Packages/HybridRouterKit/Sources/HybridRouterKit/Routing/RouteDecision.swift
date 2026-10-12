/// The router's answer for one user turn: where it runs, why, and which layer decided.
public struct RouteDecision: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case rule
        case classifier
        case escalation
        case userOverride
    }

    public var route: Route
    /// One short sentence shown to the user.
    public var reason: String
    public var source: Source

    public init(route: Route, reason: String, source: Source) {
        self.route = route
        self.reason = reason
        self.source = source
    }

    public static func forced(_ route: Route) -> RouteDecision {
        RouteDecision(route: route, reason: "Forced: \(route.displayName)", source: .userOverride)
    }
}
