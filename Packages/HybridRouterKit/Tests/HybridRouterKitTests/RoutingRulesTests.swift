import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

struct RoutingRulesTests {
    private static let allAvailable: [Route: ProviderAvailability] = [
        .onDevice: .available, .appleCloud: .available, .claude: .available,
    ]
    private static let budgets: [Route: Int] = [.onDevice: 4_000, .appleCloud: 32_000, .claude: 1_000_000]

    private func input(
        override: Route? = nil,
        privacyReason: String? = nil,
        isOnline: Bool = true,
        availability: [Route: ProviderAvailability] = allAvailable,
        tokens: Int = 500,
        hasImage: Bool = false,
        visionRoutes: Set<Route> = [.onDevice, .claude]
    ) -> RoutingInput {
        RoutingInput(
            override: override,
            privacyReason: privacyReason,
            isOnline: isOnline,
            availability: availability,
            estimatedTokens: tokens,
            contextBudgets: Self.budgets,
            hasImage: hasImage,
            visionRoutes: visionRoutes
        )
    }

    // MARK: Layer 0

    @Test func overrideWinsOverTheOtherRules() {
        let outcome = RoutingRules.evaluate(input(override: .claude, tokens: 2_000_000, hasImage: true, visionRoutes: []))
        #expect(outcome == .decided(.forced(.claude)))
    }

    @Test func forcingACloudRouteOfflineSaysWhy() {
        #expect(RoutingRules.evaluate(input(override: .claude, isOnline: false))
            == .blocked(reason: "Offline: Claude needs a network connection."))
        #expect(RoutingRules.evaluate(input(override: .onDevice, isOnline: false)) == .decided(.forced(.onDevice)))
    }

    @Test func overrideToAnUnavailableRouteSaysWhy() {
        var availability = Self.allAvailable
        availability[.claude] = .unavailable(reason: "Claude not configured")
        #expect(RoutingRules.evaluate(input(override: .claude, availability: availability))
            == .blocked(reason: "Claude unavailable: Claude not configured"))
    }

    @Test func privacyWinsOverForcingClaude() {
        #expect(RoutingRules.evaluate(input(override: .claude, privacyReason: "phone number"))
            == .blocked(reason: "Kept private (phone number), so this can't go to Claude."))
        #expect(RoutingRules.evaluate(input(override: .appleCloud, privacyReason: "phone number"))
            == .decided(.forced(.appleCloud)))
    }

    // MARK: A1 privacy

    @Test func privateTurnStaysOnDevice() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Phone number"))
        #expect(outcome == .decided(RouteDecision(route: .onDevice, reason: "Kept private: Phone number", source: .rule)))
    }

    @Test func privateTurnTooBigForDeviceGoesToAppleCloudNeverClaude() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Medical", tokens: 10_000))
        #expect(outcome == .decided(RouteDecision(route: .appleCloud, reason: "Kept private: Medical", source: .rule)))
    }

    @Test func privateTurnTooBigForAppleCloudIsBlocked() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Medical", tokens: 50_000))
        #expect(outcome == .blocked(reason: "Too long to keep private. Start a new chat or shorten it."))
    }

    @Test func privateTurnWithOnlyClaudeAvailableIsBlocked() {
        let availability: [Route: ProviderAvailability] = [
            .onDevice: .unavailable(reason: "off"), .appleCloud: .unavailable(reason: "off"), .claude: .available,
        ]
        let outcome = RoutingRules.evaluate(input(privacyReason: "PII", availability: availability))
        #expect(outcome == .blocked(reason: "No private model is available right now."))
    }

    // MARK: A2 availability

    @Test func offlineGoesOnDevice() {
        let outcome = RoutingRules.evaluate(input(isOnline: false))
        #expect(outcome == .decided(RouteDecision(route: .onDevice, reason: "Offline", source: .rule)))
    }

    @Test func offlineWithoutOnDeviceIsBlockedWithItsReason() {
        var availability = Self.allAvailable
        availability[.onDevice] = .unavailable(reason: "Apple Intelligence is turned off in Settings")
        let outcome = RoutingRules.evaluate(input(isOnline: false, availability: availability))
        #expect(outcome == .blocked(reason: "Apple Intelligence is turned off in Settings"))
    }

    @Test func unavailableRoutesAreNotCandidates() {
        var availability = Self.allAvailable
        availability[.claude] = .unavailable(reason: "Claude not configured")
        #expect(RoutingRules.evaluate(input(availability: availability)) == .open(allowed: [.onDevice, .appleCloud]))
    }

    @Test func nothingAvailableIsBlocked() {
        let none: [Route: ProviderAvailability] = [:]
        #expect(RoutingRules.evaluate(input(availability: none)) == .blocked(reason: "No model is available right now."))
    }

    // MARK: A3 context fit

    @Test func tooLongForDeviceLeavesTheLargerRoutesToTheClassifier() {
        #expect(RoutingRules.evaluate(input(tokens: 10_000)) == .open(allowed: [.appleCloud, .claude]))
    }

    @Test func tooLongForAppleCloudGoesToClaude() {
        let outcome = RoutingRules.evaluate(input(tokens: 100_000))
        #expect(outcome == .decided(RouteDecision(route: .claude, reason: "Too long for On-device", source: .rule)))
    }

    @Test func tooLongForEverythingIsBlocked() {
        let outcome = RoutingRules.evaluate(input(tokens: 2_000_000))
        #expect(outcome == .blocked(reason: "This conversation is too long for any available model."))
    }

    @Test func tooLongWhileOnDeviceIsUnavailableIsStillOpen() {
        var availability = Self.allAvailable
        availability[.onDevice] = .unavailable(reason: "off")
        // Apple Cloud is the cheapest available and fits, so the classifier still decides.
        #expect(RoutingRules.evaluate(input(availability: availability, tokens: 10_000)) == .open(allowed: [.appleCloud, .claude]))
    }

    @Test func routesWithoutABudgetCountAsUnlimited() {
        let unbounded = RoutingInput(availability: Self.allAvailable, estimatedTokens: 5_000_000)
        #expect(RoutingRules.evaluate(unbounded) == .open(allowed: [.onDevice, .appleCloud, .claude]))
    }

    // MARK: A4 capability

    @Test func imagePrefersOnDevice() {
        let outcome = RoutingRules.evaluate(input(hasImage: true))
        #expect(outcome == .decided(RouteDecision(route: .onDevice, reason: "Image attached", source: .rule)))
    }

    @Test func imageSkipsRoutesWithoutVision() {
        let outcome = RoutingRules.evaluate(input(hasImage: true, visionRoutes: [.claude]))
        #expect(outcome == .decided(RouteDecision(route: .claude, reason: "Image attached", source: .rule)))
    }

    @Test func privateImageNeverGoesToClaude() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Scanned receipt", hasImage: true, visionRoutes: [.claude]))
        #expect(outcome == .blocked(reason: "No available model can read images."))
    }

    @Test func privateImageOnDeviceSaysKeptPrivate() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Scanned receipt", hasImage: true))
        #expect(outcome == .decided(RouteDecision(route: .onDevice, reason: "Kept private: Scanned receipt", source: .rule)))
    }

    // MARK: open turns

    @Test func ordinaryTurnIsLeftToTheClassifier() {
        #expect(RoutingRules.evaluate(input()) == .open(allowed: [.onDevice, .appleCloud, .claude]))
    }

    // MARK: resolve

    @Test func resolveKeepsAnAllowedTarget() {
        #expect(RoutingRules.resolve(.appleCloud, allowed: [.onDevice, .appleCloud]) == .appleCloud)
    }

    @Test func resolvePrefersTheNextRouteUp() {
        #expect(RoutingRules.resolve(.onDevice, allowed: [.appleCloud, .claude]) == .appleCloud)
    }

    @Test func resolveFallsBackDownWhenNothingIsAbove() {
        #expect(RoutingRules.resolve(.claude, allowed: [.onDevice, .appleCloud]) == .appleCloud)
    }

    @Test func resolveWithNothingAllowedIsNil() {
        #expect(RoutingRules.resolve(.claude, allowed: []) == nil)
    }
}

struct ComplexityMappingTests {
    @Test func standardMappingFollowsTheSpec() {
        #expect(ComplexityMapping.standard.route(for: "simple") == .onDevice)
        #expect(ComplexityMapping.standard.route(for: "moderate") == .appleCloud)
        #expect(ComplexityMapping.standard.route(for: "complex") == .claude)
        #expect(ComplexityMapping.standard.route(for: "unknown") == nil)
    }
}

struct RouteMentionTests {
    private static let allAvailable: [Route: ProviderAvailability] = [
        .onDevice: .available, .appleCloud: .available, .claude: .available,
    ]

    @Test(arguments: [
        ("hmm but claude can?", Route.claude),
        ("Ask Claude to check this", .claude),
        ("Can Apple Cloud do it instead?", .appleCloud),
        ("Use Private Cloud Compute for this", .appleCloud),
        ("What would Muse Wonder say?", .claude),
    ])
    func findsANamedRoute(prompt: String, route: Route) {
        #expect(RouteMention.named(in: prompt) == route)
    }

    @Test(arguments: [
        "Give me three dinner ideas",
        "Store the file on device",
        "Is Claude better than Apple Cloud here?",
        "Claudette is coming to dinner",
    ])
    func ignoresMessagesThatDontNameOneRoute(prompt: String) {
        #expect(RouteMention.named(in: prompt) == nil)
    }

    @Test func namingARouteSendsTheTurnThere() {
        let input = RoutingInput(availability: Self.allAvailable, namedRoute: .claude)
        #expect(RoutingRules.evaluate(input) == .decided(RouteDecision(route: .claude, reason: "You asked for Claude", source: .rule)))
    }

    @Test func privacyWinsOverANamedRoute() {
        let input = RoutingInput(privacyReason: "card number", availability: Self.allAvailable, namedRoute: .claude)
        guard case .decided(let decision) = RoutingRules.evaluate(input) else {
            Issue.record("expected a decision")
            return
        }
        #expect(decision.route != .claude)
        #expect(decision.reason.hasPrefix("Kept private"))
    }

    @Test func anUnavailableNamedRouteLeavesItToTheClassifier() {
        var availability = Self.allAvailable
        availability[.appleCloud] = .unavailable(reason: "Not enabled")
        let input = RoutingInput(availability: availability, namedRoute: .appleCloud)
        #expect(RoutingRules.evaluate(input) == .open(allowed: [.onDevice, .claude]))
    }

    @Test func eachRouteIsToldWhichModelItIs() {
        #expect(RoutingProfile.routeNote(for: .onDevice).contains("This reply is from Apple's on-device model"))
        #expect(RoutingProfile.routeNote(for: .claude).contains("This reply is from Claude"))
        #expect(RoutingProfile.routeNote(for: .claude) == RoutingProfile.routeNote(for: .claude))
        let muse = RoutingProfile.routeNote(for: .claude, cloud: .museWonder)
        #expect(muse.contains("Apple Private Cloud Compute and Muse Wonder"))
        #expect(muse.contains("This reply is from Muse Wonder"))
        // Said only when asked, or models sign every reply with it.
        #expect(muse.contains("Don't mention this unless the user asks"))
    }

    @Test func reasonsNameTheModelServingTheCloudRoute() {
        let muse = RouteLabels(cloud: .museWonder)
        let named = RoutingInput(availability: Self.allAvailable, namedRoute: .claude, labels: muse)
        #expect(RoutingRules.evaluate(named) == .decided(RouteDecision(route: .claude, reason: "You asked for Muse Wonder", source: .rule)))
        let forced = RoutingInput(override: .claude, privacyReason: "card number", availability: Self.allAvailable, labels: muse)
        #expect(RoutingRules.evaluate(forced) == .blocked(reason: "Kept private (card number), so this can't go to Muse Wonder."))
    }
}

struct RouteLabelsTests {
    @Test func theCloudRouteIsNamedForItsModel() {
        #expect(RouteLabels.standard.name(.claude) == "Claude")
        #expect(RouteLabels(cloud: .museWonder).name(.claude) == "Muse Wonder")
        #expect(RouteLabels(cloud: .museWonder).symbol(.claude) == "infinity")
        #expect(RouteLabels(cloud: .museWonder).name(.appleCloud) == "Apple Cloud")
    }

    @Test func aReplyKeepsTheNameOfTheModelThatWroteIt() {
        let muse = RouteLabels(cloud: .museWonder)
        #expect(muse.name(.claude, modelID: "claude-sonnet-5-5") == "Claude")
        #expect(RouteLabels.standard.name(.claude, modelID: "muse-wonder-1.0") == "Muse Wonder")
        #expect(muse.name(.onDevice, modelID: "apple-on-device") == "On-device")
    }

    @MainActor @Test func aSessionIsLabelledByItsCloudProvider() {
        let costTable = CostTable(updated: "", source: "", models: [:])
        let session = RoutedSession(
            instructions: "", onDevice: FakeProvider(route: .onDevice, reply: ""), appleCloud: FakeProvider(route: .appleCloud, reply: ""),
            claude: MuseProvider(apiKey: "test"), costTable: costTable
        )
        #expect(session.labels == RouteLabels(cloud: .museWonder))
        #expect(session.availability(of: .claude) == .available)
        #expect(MuseProvider(apiKey: nil).availability == .unavailable(reason: "Muse Wonder not configured"))
    }
}
