import Testing
@testable import RouterKit

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
