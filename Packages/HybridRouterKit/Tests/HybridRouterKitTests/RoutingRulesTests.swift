import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

struct RoutingRulesTests {
    private static let allAvailable: [Route: ProviderAvailability] = [
        .onDevice: .available, .appleCloud: .available, .cloud: .available,
    ]
    private static let budgets: [Route: Int] = [.onDevice: 4_000, .appleCloud: 32_000, .cloud: 1_000_000]

    private func input(
        override: Route? = nil,
        privacyReason: String? = nil,
        isOnline: Bool = true,
        availability: [Route: ProviderAvailability] = allAvailable,
        tokens: Int = 500,
        hasImage: Bool = false,
        visionRoutes: Set<Route> = [.onDevice, .cloud]
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
        let outcome = RoutingRules.evaluate(input(override: .cloud, tokens: 2_000_000, hasImage: true, visionRoutes: []))
        #expect(outcome == .decided(.forced(.cloud)))
    }

    @Test func forcingACloudRouteOfflineSaysWhy() {
        #expect(RoutingRules.evaluate(input(override: .cloud, isOnline: false))
            == .blocked(reason: "Offline: Claude needs a network connection."))
        #expect(RoutingRules.evaluate(input(override: .onDevice, isOnline: false)) == .decided(.forced(.onDevice)))
    }

    @Test func overrideToAnUnavailableRouteSaysWhy() {
        var availability = Self.allAvailable
        availability[.cloud] = .unavailable(reason: "Claude not configured")
        #expect(RoutingRules.evaluate(input(override: .cloud, availability: availability))
            == .blocked(reason: "Claude unavailable: Claude not configured"))
    }

    @Test func privacyWinsOverForcingClaude() {
        #expect(RoutingRules.evaluate(input(override: .cloud, privacyReason: "phone number"))
            == .blocked(reason: "Kept private (phone number), so this can't go to Claude."))
        #expect(RoutingRules.evaluate(input(override: .appleCloud, privacyReason: "phone number"))
            == .decided(.forced(.appleCloud)))
    }

    // MARK: A1 privacy

    @Test func privateTurnStaysOnDevice() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Phone number"))
        #expect(outcome == .decided(RouteDecision(route: .onDevice, reason: "Kept private: Phone number", source: .rule, decidedByPrivacy: true)))
    }

    @Test func privateTurnTooBigForDeviceGoesToAppleCloudNeverClaude() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Medical", tokens: 10_000))
        #expect(outcome == .decided(RouteDecision(route: .appleCloud, reason: "Kept private: Medical", source: .rule, decidedByPrivacy: true)))
    }

    @Test func privateTurnTooBigForAppleCloudIsBlocked() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Medical", tokens: 50_000))
        #expect(outcome == .blocked(reason: "Too long to keep private. Start a new chat or shorten it."))
    }

    @Test func privateTurnWithOnlyClaudeAvailableIsBlocked() {
        let availability: [Route: ProviderAvailability] = [
            .onDevice: .unavailable(reason: "off"), .appleCloud: .unavailable(reason: "off"), .cloud: .available,
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
        availability[.cloud] = .unavailable(reason: "Claude not configured")
        #expect(RoutingRules.evaluate(input(availability: availability)) == .open(allowed: [.onDevice, .appleCloud]))
    }

    @Test func nothingAvailableIsBlocked() {
        let none: [Route: ProviderAvailability] = [:]
        #expect(RoutingRules.evaluate(input(availability: none)) == .blocked(reason: "No model is available right now."))
    }

    // MARK: A3 context fit

    @Test func tooLongForDeviceLeavesTheLargerRoutesToTheClassifier() {
        #expect(RoutingRules.evaluate(input(tokens: 10_000)) == .open(allowed: [.appleCloud, .cloud]))
    }

    @Test func tooLongForAppleCloudGoesToClaude() {
        let outcome = RoutingRules.evaluate(input(tokens: 100_000))
        #expect(outcome == .decided(RouteDecision(route: .cloud, reason: "Chat too long for On-device", source: .rule, tooLongFor: .onDevice)))
    }

    @Test func tooLongForEverythingIsBlocked() {
        let outcome = RoutingRules.evaluate(input(tokens: 2_000_000))
        #expect(outcome == .blocked(reason: "This conversation is too long for any available model."))
    }

    @Test func tooLongWhileOnDeviceIsUnavailableIsStillOpen() {
        var availability = Self.allAvailable
        availability[.onDevice] = .unavailable(reason: "off")
        // Apple Cloud is the cheapest available and fits, so the classifier still decides.
        #expect(RoutingRules.evaluate(input(availability: availability, tokens: 10_000)) == .open(allowed: [.appleCloud, .cloud]))
    }

    @Test func routesWithoutABudgetCountAsUnlimited() {
        let unbounded = RoutingInput(availability: Self.allAvailable, estimatedTokens: 5_000_000)
        #expect(RoutingRules.evaluate(unbounded) == .open(allowed: [.onDevice, .appleCloud, .cloud]))
    }

    // MARK: A4 capability

    @Test func imagePrefersOnDevice() {
        let outcome = RoutingRules.evaluate(input(hasImage: true))
        #expect(outcome == .decided(RouteDecision(route: .onDevice, reason: "Image attached", source: .rule)))
    }

    @Test func imageSkipsRoutesWithoutVision() {
        let outcome = RoutingRules.evaluate(input(hasImage: true, visionRoutes: [.cloud]))
        #expect(outcome == .decided(RouteDecision(route: .cloud, reason: "Image attached", source: .rule)))
    }

    @Test func privateImageNeverGoesToClaude() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Scanned receipt", hasImage: true, visionRoutes: [.cloud]))
        #expect(outcome == .blocked(reason: "No available model can read images."))
    }

    @Test func privateImageOnDeviceSaysKeptPrivate() {
        let outcome = RoutingRules.evaluate(input(privacyReason: "Scanned receipt", hasImage: true))
        #expect(outcome == .decided(RouteDecision(route: .onDevice, reason: "Kept private: Scanned receipt", source: .rule, decidedByPrivacy: true)))
    }

    // MARK: open turns

    @Test func ordinaryTurnIsLeftToTheClassifier() {
        #expect(RoutingRules.evaluate(input()) == .open(allowed: [.onDevice, .appleCloud, .cloud]))
    }

    // MARK: resolve

    @Test func resolveKeepsAnAllowedTarget() {
        #expect(RoutingRules.resolve(.appleCloud, allowed: [.onDevice, .appleCloud]) == .appleCloud)
    }

    @Test func resolvePrefersTheNextRouteUp() {
        #expect(RoutingRules.resolve(.onDevice, allowed: [.appleCloud, .cloud]) == .appleCloud)
    }

    @Test func resolveFallsBackDownWhenNothingIsAbove() {
        #expect(RoutingRules.resolve(.cloud, allowed: [.onDevice, .appleCloud]) == .appleCloud)
    }

    @Test func resolveWithNothingAllowedIsNil() {
        #expect(RoutingRules.resolve(.cloud, allowed: []) == nil)
    }

    // MARK: Chats too long for a route

    /// 4,000 budget on-device; the history takes 4,500 of the 5,000 estimated tokens.
    private func longChat(override: Route? = nil, privacyReason: String? = nil,
                          availability: [Route: ProviderAvailability] = allAvailable, base: Int = 500) -> RoutingInput {
        var input = self.input(override: override, privacyReason: privacyReason, availability: availability, tokens: 5_000)
        input.contextBudgets = [.onDevice: 4_000, .appleCloud: 32_000, .cloud: 1_000_000]
        input.baseTokens = base
        return input
    }

    @Test func aForcedRouteStaysAndAnswersFromRecentTurns() {
        let outcome = RoutingRules.evaluate(longChat(override: .onDevice))
        #expect(outcome == .decided(RouteDecision(route: .onDevice, reason: "Forced: On-device", source: .userOverride, historyBudget: 3_500)))
    }

    @Test func aForcedRouteTooSmallForTheMessageItselfIsBlocked() {
        #expect(RoutingRules.evaluate(longChat(override: .onDevice, base: 4_500))
            == .blocked(reason: "This message is too long for On-device on its own."))
    }

    @Test func whenNothingFitsTheChatIsAnsweredFromRecentTurns() {
        let onlyOnDevice: [Route: ProviderAvailability] = [.onDevice: .available, .appleCloud: .unavailable(reason: "off"), .cloud: .unavailable(reason: "off")]
        #expect(RoutingRules.evaluate(longChat(availability: onlyOnDevice))
            == .decided(RouteDecision(route: .onDevice, reason: "Only On-device is available", source: .rule, historyBudget: 3_500)))
    }

    @Test func aLongPrivateChatStaysOnDeviceInsteadOfBeingBlocked() {
        var availability = Self.allAvailable
        availability[.appleCloud] = .unavailable(reason: "off")
        // Before 0.4: "Too long to keep private. Start a new chat or shorten it."
        #expect(RoutingRules.evaluate(longChat(privacyReason: "health information", availability: availability))
            == .decided(RouteDecision(route: .onDevice, reason: "Kept private: health information", source: .rule, historyBudget: 3_500, decidedByPrivacy: true)))
    }

    @Test func byDefaultALargerModelThatFitsIsUsed() {
        var availability = Self.allAvailable
        availability[.appleCloud] = .unavailable(reason: "off")
        #expect(RoutingRules.evaluate(longChat(availability: availability))
            == .decided(RouteDecision(route: .cloud, reason: "Chat too long for On-device", source: .rule, tooLongFor: .onDevice)))
    }

    @Test func withoutABaseEstimateNothingIsTrimmed() {
        var input = longChat(override: .onDevice)
        input.baseTokens = nil
        #expect(RoutingRules.evaluate(input) == .decided(.forced(.onDevice)))
    }
}

struct ComplexityMappingTests {
    @Test func standardMappingFollowsTheSpec() {
        #expect(ComplexityMapping.standard.route(for: "simple") == .onDevice)
        #expect(ComplexityMapping.standard.route(for: "moderate") == .appleCloud)
        #expect(ComplexityMapping.standard.route(for: "complex") == .cloud)
        #expect(ComplexityMapping.standard.route(for: "unknown") == nil)
    }
}

struct RouteMentionTests {
    private static let allAvailable: [Route: ProviderAvailability] = [
        .onDevice: .available, .appleCloud: .available, .cloud: .available,
    ]

    @Test(arguments: [
        ("hmm but claude can?", Route.cloud),
        ("Ask Claude to check this", .cloud),
        ("Can Apple Cloud do it instead?", .appleCloud),
        ("Use Private Cloud Compute for this", .appleCloud),
        ("What would Muse Wonder say?", .cloud),
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
        let input = RoutingInput(availability: Self.allAvailable, namedRoute: .cloud)
        #expect(RoutingRules.evaluate(input) == .decided(RouteDecision(route: .cloud, reason: "You asked for Claude", source: .rule)))
    }

    @Test func privacyWinsOverANamedRoute() {
        let input = RoutingInput(privacyReason: "card number", availability: Self.allAvailable, namedRoute: .cloud)
        guard case .decided(let decision) = RoutingRules.evaluate(input) else {
            Issue.record("expected a decision")
            return
        }
        #expect(decision.route != .cloud)
        #expect(decision.reason.hasPrefix("Kept private"))
    }

    @Test func anUnavailableNamedRouteLeavesItToTheClassifier() {
        var availability = Self.allAvailable
        availability[.appleCloud] = .unavailable(reason: "Not enabled")
        let input = RoutingInput(availability: availability, namedRoute: .appleCloud)
        #expect(RoutingRules.evaluate(input) == .open(allowed: [.onDevice, .cloud]))
    }

    @Test func eachRouteIsToldWhichModelItIs() {
        let all: [Route: String] = [.onDevice: "Apple's on-device model", .appleCloud: "Apple Private Cloud Compute", .cloud: "Claude"]
        #expect(RoutingProfile.routeNote(for: .onDevice, models: all).contains("This reply is from Apple's on-device model"))
        #expect(RoutingProfile.routeNote(for: .cloud, models: all).contains("This reply is from Claude"))
        var models = all
        models[.cloud] = "Muse Wonder"
        let muse = RoutingProfile.routeNote(for: .cloud, models: models)
        #expect(muse.contains("shared by 3 models: Apple's on-device model, Apple Private Cloud Compute and Muse Wonder"))
        #expect(muse.contains("This reply is from Muse Wonder"))
        // Said only when asked, or models sign every reply with it.
        #expect(muse.contains("Don't mention this or sign your reply with a model name unless the user asks"))
    }

    @Test func routeNoteListsOnlyAvailableModels() {
        let twoModels = RoutingProfile.routeNote(for: .onDevice, models: [.onDevice: "Apple's on-device model", .cloud: "Claude"])
        #expect(twoModels.contains("shared by 2 models: Apple's on-device model and Claude"))
        #expect(!twoModels.contains("Private Cloud Compute"))
        #expect(RoutingProfile.routeNote(for: .onDevice, models: [.onDevice: "Apple's on-device model"]) == "This reply is from Apple's on-device model.")
    }

    @Test func reasonsNameTheModelServingTheCloudRoute() {
        let muse = RouteLabels(cloud: .museWonder)
        let named = RoutingInput(availability: Self.allAvailable, namedRoute: .cloud, labels: muse)
        #expect(RoutingRules.evaluate(named) == .decided(RouteDecision(route: .cloud, reason: "You asked for Muse Wonder", source: .rule)))
        let forced = RoutingInput(override: .cloud, privacyReason: "card number", availability: Self.allAvailable, labels: muse)
        #expect(RoutingRules.evaluate(forced) == .blocked(reason: "Kept private (card number), so this can't go to Muse Wonder."))
    }
}

struct RouteLabelsTests {
    @Test func theCloudRouteIsNamedForItsModel() {
        #expect(RouteLabels.standard.name(.cloud) == "Claude")
        #expect(RouteLabels(cloud: .museWonder).name(.cloud) == "Muse Wonder")
        #expect(RouteLabels(cloud: .museWonder).symbol(.cloud) == "infinity")
        #expect(RouteLabels(cloud: .museWonder).name(.appleCloud) == "Apple Cloud")
    }

    @Test func aReplyKeepsTheNameOfTheModelThatWroteIt() {
        let muse = RouteLabels(cloud: .museWonder)
        #expect(muse.name(.cloud, modelID: "claude-sonnet-5-5") == "Claude")
        #expect(RouteLabels.standard.name(.cloud, modelID: "muse-wonder-1.0") == "Muse Wonder")
        #expect(muse.name(.onDevice, modelID: "apple-on-device") == "On-device")
    }

    @MainActor @Test func aSessionIsLabelledByItsCloudProvider() {
        let costTable = CostTable(updated: "", source: "", models: [:])
        let session = RoutedSession(
            instructions: "", onDevice: FakeProvider(route: .onDevice, reply: ""), appleCloud: FakeProvider(route: .appleCloud, reply: ""),
            cloud: MuseProvider(apiKey: "test"), costTable: costTable
        )
        #expect(session.labels == RouteLabels(cloud: .museWonder))
        #expect(session.availability(of: .cloud) == .available)
        #expect(MuseProvider(apiKey: nil).availability == .unavailable(reason: "Muse Wonder not configured"))
    }

    @Test func forcedAndBlockedReasonsNameTheCloudModel() {
        let muse = RouteLabels(cloud: .museWonder)
        var forced = RoutingInput(override: .cloud, availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available], labels: muse)
        #expect(RoutingRules.evaluate(forced) == .decided(RouteDecision(route: .cloud, reason: "Forced: Muse Wonder", source: .userOverride)))
        forced.isOnline = false
        #expect(RoutingRules.evaluate(forced) == .blocked(reason: "Offline: Muse Wonder needs a network connection."))
        forced.isOnline = true
        forced.availability[.cloud] = .unavailable(reason: "no key")
        #expect(RoutingRules.evaluate(forced) == .blocked(reason: "Muse Wonder unavailable: no key"))
    }

    @Test func anUnknownCloudProviderIsNamedByItself() {
        let labels = RouteLabels(cloud: FakeProvider(route: .cloud, reply: "x", modelID: "gemini-3", displayName: "Gemini"))
        #expect(labels.name(.cloud) == "Gemini")
        #expect(labels.symbol(.cloud) == Route.cloud.symbolName)
        // A reply from a known model keeps its own name.
        #expect(labels.name(.cloud, modelID: "claude-sonnet-5-5") == "Claude")
    }
}
