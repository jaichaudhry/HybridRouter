/// The router's answer for one user turn: where it runs, why, and which layer decided.
public struct RouteDecision: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case rule
        case classifier
        case escalation
        case userOverride
    }

    public var route: Route
    /// One short sentence shown to the user.
    public var reason: String
    public var source: Source
    /// Tokens of the earlier conversation the route may see, when the whole chat doesn't fit
    /// it: it answers from the most recent turns that fit. Nil when it sees everything.
    public var historyBudget: Int?
    /// A smaller route the router preferred, skipped because the chat is too long for it.
    public var tooLongFor: Route?
    /// The route was chosen to keep the turn private, and `reason` already says so
    /// ("Kept private: card number").
    public var decidedByPrivacy: Bool

    public init(
        route: Route,
        reason: String,
        source: Source,
        historyBudget: Int? = nil,
        tooLongFor: Route? = nil,
        decidedByPrivacy: Bool = false
    ) {
        self.route = route
        self.reason = reason
        self.source = source
        self.historyBudget = historyBudget
        self.tooLongFor = tooLongFor
        self.decidedByPrivacy = decidedByPrivacy
    }

    /// True when the route sees only the recent part of the conversation.
    public var trimsHistory: Bool { historyBudget != nil }

    public static func forced(_ route: Route, labels: RouteLabels = .standard) -> RouteDecision {
        RouteDecision(route: route, reason: "Forced: \(labels.name(route))", source: .userOverride)
    }
}
