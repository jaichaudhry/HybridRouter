import Foundation

/// Everything the hard rules look at for one turn. Built by the app; plain values so the
/// rules stay pure and unit-testable.
public struct RoutingInput: Equatable, Sendable {
    /// Set by Settings or the composer. Wins over everything.
    public var override: Route?
    /// Why the turn must stay off the cloud model, or nil if it may leave the device.
    public var privacyReason: String?
    public var isOnline: Bool
    public var availability: [Route: ProviderAvailability]
    /// Estimated tokens for instructions, tools, transcript, the new turn and reserved output.
    public var estimatedTokens: Int
    /// Estimates for routes that see less of the history (see ``HistoryPolicy``). Other routes use
    /// `estimatedTokens`.
    public var estimatedTokensByRoute: [Route: Int]
    /// Estimated tokens for everything but the earlier conversation: instructions, tools, the
    /// new turn and reserved output. When set, a route too small for the whole chat can still
    /// answer from its recent turns. Nil means the history can't be trimmed.
    public var baseTokens: Int?
    /// Stay on the route the router or user picked even when the chat is too long for it, and
    /// trim the history, rather than moving to a larger route. Set from ``Router/whenTooLong``.
    public var staysWhenTooLong: Bool
    /// Usable context per route. A missing route counts as unlimited.
    public var contextBudgets: [Route: Int]
    public var hasImage: Bool
    /// Routes whose model accepts images.
    public var visionRoutes: Set<Route>
    /// The route of the previous reply, if this turn is a bare follow-up question to it
    /// ("Why?"). Such turns stay on that route.
    public var followsUpOn: Route?
    /// The previous user message, shown to the classifier for short turns.
    public var previousPrompt: String?
    /// A route the user named in the message ("ask Claude"). See ``RouteMention``.
    public var namedRoute: Route?
    /// Route names for reasons, with the cloud route named for the model serving it.
    public var labels: RouteLabels
    /// The kind of exact answer the message asks for (counting, arithmetic, …), if the router
    /// checks for one. See ``ExactAnswerDetector``.
    public var exactAnswer: ExactAnswerDetector.Kind?

    public init(
        override: Route? = nil,
        privacyReason: String? = nil,
        isOnline: Bool = true,
        availability: [Route: ProviderAvailability],
        estimatedTokens: Int = 0,
        estimatedTokensByRoute: [Route: Int] = [:],
        baseTokens: Int? = nil,
        staysWhenTooLong: Bool = false,
        contextBudgets: [Route: Int] = [:],
        hasImage: Bool = false,
        visionRoutes: Set<Route> = [],
        followsUpOn: Route? = nil,
        previousPrompt: String? = nil,
        namedRoute: Route? = nil,
        labels: RouteLabels = .standard,
        exactAnswer: ExactAnswerDetector.Kind? = nil
    ) {
        self.override = override
        self.privacyReason = privacyReason
        self.isOnline = isOnline
        self.availability = availability
        self.estimatedTokens = estimatedTokens
        self.estimatedTokensByRoute = estimatedTokensByRoute
        self.baseTokens = baseTokens
        self.staysWhenTooLong = staysWhenTooLong
        self.contextBudgets = contextBudgets
        self.hasImage = hasImage
        self.visionRoutes = visionRoutes
        self.followsUpOn = followsUpOn
        self.previousPrompt = previousPrompt
        self.namedRoute = namedRoute
        self.labels = labels
        self.exactAnswer = exactAnswer
    }

    public var isPrivate: Bool { privacyReason != nil }

    func fits(_ route: Route) -> Bool {
        contextBudgets[route].map { (estimatedTokensByRoute[route] ?? estimatedTokens) <= $0 } ?? true
    }

    /// Whether the route can take the turn with only part of the history: the new turn
    /// itself fits.
    func fitsWithTrimming(_ route: Route) -> Bool {
        guard let baseTokens else { return false }
        return contextBudgets[route].map { baseTokens <= $0 } ?? true
    }

    /// The decision with its history budget set if the whole chat doesn't fit its route.
    func budgeted(_ decision: RouteDecision) -> RouteDecision {
        guard !fits(decision.route), fitsWithTrimming(decision.route),
              let budget = contextBudgets[decision.route], let baseTokens else { return decision }
        var decision = decision
        decision.historyBudget = max(budget - baseTokens, 0)
        return decision
    }

    func isAvailable(_ route: Route) -> Bool {
        availability[route]?.isAvailable ?? false
    }
}

/// Recognizes a bare follow-up question such as "Why?" or "How come?": one or two words
/// ending in a question mark. Longer follow-ups go to the classifier with the previous message.
public enum FollowUp {
    public static func isBare(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        return trimmed.hasSuffix("?")
            && (1...2).contains(words.count)
            && trimmed.contains(where: \.isLetter)
    }
}

/// Finds a route the user asked for by name, such as "ask Claude" or "but Claude can?".
/// Either cloud model's name ("Claude", "Muse Wonder") asks for the cloud route, whichever model
/// serves it. Only the cloud route and Apple Cloud count: "on device" turns up in ordinary questions ("store it
/// on device"), and On-device is where most turns go anyway.
public enum RouteMention {
    /// The single route named in the message, or nil if none or both are named.
    public static func named(in prompt: String) -> Route? {
        let names: [(Route, String)] = [
            (.cloud, #"\b(claude|muse wonder)\b"#),
            (.appleCloud, #"\b(apple cloud|private cloud compute)\b"#),
        ]
        let named = names.filter { prompt.range(of: $0.1, options: [.regularExpression, .caseInsensitive]) != nil }
        return named.count == 1 ? named[0].0 : nil
    }
}

/// What the hard rules concluded.
public enum RuleOutcome: Equatable, Sendable {
    /// A rule settled the route.
    case decided(RouteDecision)
    /// No rule settled it; the classifier picks among these routes (cheapest first).
    case open(allowed: [Route])
    /// No route can take the turn.
    case blocked(reason: String)
}

/// The router's first stage: the user's override and deterministic rules, run before the classifier.
public enum RoutingRules {
    public static func evaluate(_ input: RoutingInput) -> RuleOutcome {
        switch evaluateRules(input) {
        case .decided(let decision): .decided(input.budgeted(decision))
        case let other: other
        }
    }

    private static func evaluateRules(_ input: RoutingInput) -> RuleOutcome {
        // Layer 0: the user's choice.
        if let override = input.override {
            // Privacy wins over a forced route: forcing the cloud model on a private turn is blocked.
            if let reason = input.privacyReason, override == .cloud {
                return .blocked(reason: "Kept private (\(reason)), so this can't go to \(input.labels.name(.cloud)).")
            }
            if let reason = input.availability[override]?.reason {
                return .blocked(reason: "\(input.labels.name(override)) unavailable: \(reason)")
            }
            if !input.isOnline, override != .onDevice {
                return .blocked(reason: "Offline: \(input.labels.name(override)) needs a network connection.")
            }
            // A chosen route stays chosen: if the chat is too long for it, it answers from the
            // most recent turns instead of moving.
            if !input.fits(override), input.baseTokens != nil, !input.fitsWithTrimming(override) {
                return .blocked(reason: "This message is too long for \(input.labels.name(override)) on its own.")
            }
            return .decided(.forced(override, labels: input.labels))
        }

        // A1 Privacy and A2 availability narrow the candidates.
        var allowed = Route.allCases.filter(input.isAvailable)
        if input.isPrivate {
            allowed.removeAll { $0 == .cloud }
        }
        if !input.isOnline {
            allowed.removeAll { $0 != .onDevice }
        }
        guard !allowed.isEmpty else {
            return .blocked(reason: blockedReason(input))
        }

        // A3 Context fit: only routes large enough for the conversation. When none is, or the
        // app prefers to stay on the picked route, routes that can answer from the most recent
        // turns count too.
        var fitting = allowed.filter(input.fits)
        if fitting.isEmpty || input.staysWhenTooLong {
            let trimmable = allowed.filter(input.fitsWithTrimming)
            if !trimmable.isEmpty { fitting = trimmable }
        }
        guard let smallestFit = fitting.first else {
            return .blocked(reason: input.isPrivate
                ? "Too long to keep private. Start a new chat or shorten it."
                : "This conversation is too long for any available model.")
        }

        // A4 Capability: an image needs a model that can see it. Prefer the cheapest.
        if input.hasImage {
            guard let route = fitting.first(where: input.visionRoutes.contains) else {
                return .blocked(reason: "No available model can read images.")
            }
            return .decided(decision(route, reason: input.privacyReason ?? "Image attached", input: input))
        }

        // Privacy settles the route: the cheapest private route that fits.
        if input.isPrivate {
            return .decided(decision(smallestFit, reason: input.privacyReason ?? "Private", input: input))
        }
        if !input.isOnline {
            return .decided(RouteDecision(route: .onDevice, reason: "Offline", source: .rule))
        }
        // The user asked for a model by name. Privacy, availability and context size were
        // checked above, so a private turn that names the cloud model has already stayed off it.
        if let named = input.namedRoute, fitting.contains(named) {
            return .decided(RouteDecision(route: named, reason: "You asked for \(input.labels.name(named))", source: .rule))
        }
        // A bare follow-up ("Why?") stays with the model that gave the previous reply.
        if let previous = input.followsUpOn, fitting.contains(previous) {
            return .decided(RouteDecision(route: previous, reason: "Follow-up", source: .rule))
        }

        // A question with one exact answer (counting, arithmetic, dates, conversions) goes to
        // the cloud model: the on-device model gets about half of these wrong.
        if let exact = input.exactAnswer, fitting.contains(.cloud) {
            return .decided(RouteDecision(route: .cloud, reason: "Needs an exact answer (\(exact.label))", source: .rule))
        }

        // Only one route is available and big enough: no choice left for the classifier.
        if fitting.count == 1 {
            if smallestFit == allowed.first {
                return .decided(RouteDecision(route: smallestFit, reason: "Only \(input.labels.name(smallestFit)) is available", source: .rule))
            }
            return .decided(RouteDecision(
                route: smallestFit,
                reason: "Chat too long for \(input.labels.name(allowed[0]))",
                source: .rule,
                tooLongFor: allowed[0]
            ))
        }
        // Otherwise the classifier still picks, among the routes that fit, so a long
        // conversation can still reach the cloud model for a complex turn.
        return .open(allowed: fitting)
    }

    /// Picks the mapped route if allowed; otherwise the nearest allowed route above it,
    /// then below it.
    public static func resolve(_ target: Route, allowed: [Route]) -> Route? {
        if allowed.contains(target) { return target }
        let order = Route.allCases
        guard let index = order.firstIndex(of: target) else { return allowed.first }
        let above = order[(index + 1)...].first(where: allowed.contains)
        let below = order[..<index].reversed().first(where: allowed.contains)
        return above ?? below
    }

    private static func decision(_ route: Route, reason: String, input: RoutingInput) -> RouteDecision {
        let prefix = input.isPrivate ? "Kept private: " : ""
        return RouteDecision(route: route, reason: prefix + reason, source: .rule)
    }

    private static func blockedReason(_ input: RoutingInput) -> String {
        if !input.isOnline {
            return input.availability[.onDevice].flatMap(\.reason) ?? "Offline and the on-device model is unavailable."
        }
        if input.isPrivate {
            return "No private model is available right now."
        }
        return "No model is available right now."
    }
}

extension ProviderAvailability {
    var reason: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }
}
