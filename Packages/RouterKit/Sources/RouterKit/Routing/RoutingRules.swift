/// Everything the hard rules look at for one turn. Built by the app; plain values so the
/// rules stay pure and unit-testable.
public struct RoutingInput: Equatable, Sendable {
    /// Set by Settings or the composer. Wins over everything.
    public var override: Route?
    /// Why the turn must stay off Claude, or nil if it may leave the device.
    public var privacyReason: String?
    public var isOnline: Bool
    public var availability: [Route: ProviderAvailability]
    /// Estimated tokens for instructions, tools, transcript, the new turn and reserved output.
    public var estimatedTokens: Int
    /// Usable context per route. A missing route counts as unlimited.
    public var contextBudgets: [Route: Int]
    public var hasImage: Bool
    /// Routes whose model accepts images.
    public var visionRoutes: Set<Route>

    public init(
        override: Route? = nil,
        privacyReason: String? = nil,
        isOnline: Bool = true,
        availability: [Route: ProviderAvailability],
        estimatedTokens: Int = 0,
        contextBudgets: [Route: Int] = [:],
        hasImage: Bool = false,
        visionRoutes: Set<Route> = []
    ) {
        self.override = override
        self.privacyReason = privacyReason
        self.isOnline = isOnline
        self.availability = availability
        self.estimatedTokens = estimatedTokens
        self.contextBudgets = contextBudgets
        self.hasImage = hasImage
        self.visionRoutes = visionRoutes
    }

    public var isPrivate: Bool { privacyReason != nil }

    func fits(_ route: Route) -> Bool {
        contextBudgets[route].map { estimatedTokens <= $0 } ?? true
    }

    func isAvailable(_ route: Route) -> Bool {
        availability[route]?.isAvailable ?? false
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

/// Layer 0 and Layer A of the router (SPEC §6): deterministic, run before the classifier.
public enum RoutingRules {
    public static func evaluate(_ input: RoutingInput) -> RuleOutcome {
        // Layer 0: the user's choice.
        if let override = input.override {
            if let reason = input.availability[override]?.reason {
                return .blocked(reason: "\(override.displayName) unavailable: \(reason)")
            }
            return .decided(.forced(override))
        }

        // A1 Privacy and A2 availability narrow the candidates.
        var allowed = Route.allCases.filter(input.isAvailable)
        if input.isPrivate {
            allowed.removeAll { $0 == .claude }
        }
        if !input.isOnline {
            allowed.removeAll { $0 != .onDevice }
        }
        guard !allowed.isEmpty else {
            return .blocked(reason: blockedReason(input))
        }

        // A3 Context fit: only routes large enough for the conversation.
        let fitting = allowed.filter(input.fits)
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
            return .decided(decision(route, reason: "Image attached", input: input))
        }

        // Privacy settles the route: the cheapest private route that fits.
        if input.isPrivate {
            return .decided(decision(smallestFit, reason: input.privacyReason ?? "Private", input: input))
        }
        if !input.isOnline {
            return .decided(RouteDecision(route: .onDevice, reason: "Offline", source: .rule))
        }
        if smallestFit != allowed.first {
            return .decided(RouteDecision(route: smallestFit, reason: "Too long for \(allowed[0].displayName)", source: .rule))
        }
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
