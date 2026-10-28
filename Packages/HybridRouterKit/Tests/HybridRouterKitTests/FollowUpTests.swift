import Synchronization
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

struct FollowUpTests {
    @Test(arguments: ["Why?", "How come?", "  Really? ", "Such as?"])
    func bareQuestionsAreFollowUps(_ prompt: String) {
        #expect(FollowUp.isBare(prompt))
    }

    @Test(arguments: ["Thanks, that helps", "What would you change?", "Make it shorter", "?", "Why"])
    func otherMessagesAreNot(_ prompt: String) {
        #expect(!FollowUp.isBare(prompt))
    }

    @Test func followUpStaysOnThePreviousRoute() {
        let input = RoutingInput(
            availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available],
            followsUpOn: .cloud
        )
        #expect(RoutingRules.evaluate(input) == .decided(RouteDecision(route: .cloud, reason: "Follow-up", source: .rule)))
    }

    @Test func followUpCantBreakPrivacy() {
        let input = RoutingInput(
            privacyReason: "Medical",
            availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available],
            followsUpOn: .cloud
        )
        #expect(RoutingRules.evaluate(input).decidedRoute == .onDevice)
    }

    private static let all: [Route: ProviderAvailability] = [.onDevice: .available, .appleCloud: .available, .cloud: .available]

    @Test func aTurnAfterTheCloudModelStaysThere() {
        let input = RoutingInput(availability: Self.all, previousRoute: .cloud)
        #expect(RoutingRules.evaluate(input) == .decided(RouteDecision(route: .cloud, reason: "Same model as the last reply", source: .rule)))
    }

    @Test func aTurnAfterAppleCloudCanMoveUpButNotDown() async {
        let input = RoutingInput(availability: Self.all, previousRoute: .appleCloud)
        #expect(RoutingRules.evaluate(input) == .open(allowed: [.appleCloud, .cloud]))
        let simple = await Router(classifier: FakeClassifier.always("simple")).route("Shorter", input: input)
        #expect(simple.decision?.route == .appleCloud)
        #expect(simple.decision?.reason == "Quick conversation (same model as the last reply)")
        let complex = await Router(classifier: FakeClassifier.always("complex")).route("Which is better?", input: input)
        #expect(complex.decision?.route == .cloud)
    }

    @Test func aTurnAfterOnDeviceIsOpen() {
        #expect(RoutingRules.evaluate(RoutingInput(availability: Self.all, previousRoute: .onDevice)) == .open(allowed: [.onDevice, .appleCloud, .cloud]))
    }

    @Test func aTurnAfterTheCloudModelStillMovesUpWhenTheChatIsTooLong() {
        // The previous route doesn't fit any more: the usual too-long handling applies.
        let input = RoutingInput(availability: Self.all, estimatedTokens: 9_000, contextBudgets: [.onDevice: 4_000, .appleCloud: 8_000],
                                 previousRoute: .appleCloud)
        #expect(RoutingRules.evaluate(input).decidedRoute == .cloud)
    }

    @Test func afterAPrivateTurnTheChatStaysOnApplesModels() async {
        let input = RoutingInput(availability: Self.all, previousRoute: .cloud, hasPrivateHistory: true)
        #expect(RoutingRules.evaluate(input) == .open(allowed: [.onDevice, .appleCloud]))
        let complex = await Router(classifier: FakeClassifier.always("complex")).route("Which is better?", input: input)
        #expect(complex.decision?.route == .appleCloud)
        #expect(complex.decision?.reason == "Kept private: earlier messages were private")
        #expect(complex.decision?.decidedByPrivacy == true)

        // With Apple Cloud off, the reason says why rather than "only On-device is available".
        let onlyDevice = RoutingInput(availability: [.onDevice: .available, .appleCloud: .unavailable(reason: "off"), .cloud: .available],
                                      hasPrivateHistory: true)
        #expect(RoutingRules.evaluate(onlyDevice) == .decided(RouteDecision(
            route: .onDevice, reason: "Kept private: earlier messages were private", source: .rule, decidedByPrivacy: true)))
    }

    @Test func afterAPrivateTurnNamingTheCloudModelStillReachesIt() {
        let input = RoutingInput(availability: Self.all, hasPrivateHistory: true, namedRoute: .cloud)
        #expect(RoutingRules.evaluate(input).decidedRoute == .cloud)
        // A private turn never does, named or not.
        let privateTurn = RoutingInput(privacyReason: "card number", availability: Self.all, hasPrivateHistory: true, namedRoute: .cloud)
        #expect(RoutingRules.evaluate(privateTurn).decidedRoute == .onDevice)
    }

    @Test func aBareFollowUpToANamedCloudReplyStaysThereInAPrivateChat() {
        // The user asked for the cloud model last turn; "Why?" continues that.
        let input = RoutingInput(availability: Self.all, followsUpOn: .cloud, previousRoute: .cloud, hasPrivateHistory: true)
        #expect(RoutingRules.evaluate(input) == .decided(RouteDecision(route: .cloud, reason: "Follow-up", source: .rule)))
    }

    @Test func namingTheCloudModelInALongPrivateChatSaysItIsTooLong() async {
        let input = RoutingInput(availability: Self.all, estimatedTokens: 9_000, contextBudgets: [.cloud: 8_000],
                                 hasPrivateHistory: true, namedRoute: .cloud)
        let decision = await Router(classifier: FakeClassifier.always("complex")).route("Ask Claude which is better", input: input).decision
        #expect(decision?.tooLongFor == .cloud)
        #expect(decision?.decidedByPrivacy == false)
    }

    @Test func eachVariantGetsItsTunedInstructions() {
        #expect(OnDeviceClassifier.InstructionSet.tuned(for: .core3) == .core)
        #expect(OnDeviceClassifier.InstructionSet.tuned(for: .coreAdvanced3) == .advancedB)
    }

    @Test func shortMessagesGetThePreviousOne() {
        let prompt = OnDeviceClassifier.classifierPrompt("Now do the same for Osaka", previous: "Plan 3 days in Kyoto")
        #expect(prompt == "Previous message: Plan 3 days in Kyoto\nMessage to label: Now do the same for Osaka")
        // Short but not referring back: no context, so the previous label can't bleed in.
        #expect(OnDeviceClassifier.classifierPrompt("Make a packing list for the kids", previous: "Weigh the trade-offs") == "Make a packing list for the kids")
        #expect(OnDeviceClassifier.classifierPrompt("Make it shorter", previous: "Write a toast").hasPrefix("Previous message:"))
        let long = "Plan a relaxed four day trip to Lisbon for two people who love food and walking"
        #expect(OnDeviceClassifier.classifierPrompt(long, previous: "Hi") == long)
        #expect(OnDeviceClassifier.classifierPrompt("Hi", previous: nil) == "Hi")
    }
}

/// Records what the router asked it, so tests can check the context it was given.
final class RecordingClassifier: RouteClassifier {
    let previous = Mutex<[String?]>([])

    func classify(_ prompt: String, previous: String?) async throws -> RouteClassification {
        self.previous.withLock { $0.append(previous) }
        return RouteClassification(complexity: "simple", task: "chat")
    }
}

@MainActor
struct FollowUpCoordinatorTests {
    private func session() -> RoutedSession {
        RoutedSession(
            instructions: "Be brief.",
            onDevice: FakeProvider(route: .onDevice, reply: "device"),
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"),
            cloud: FakeProvider(route: .cloud, reply: "claude"),
            costTable: CostTable(updated: "", source: "", models: [:])
        )
    }

    @Test func bareFollowUpReusesTheLastRoute() async {
        let routed = session()
        let coordinator = TurnCoordinator(router: Router(classifier: FakeClassifier.always("complex")),
                                          estimator: FixedTokenEstimator(100), isOnline: { true })
        _ = await coordinator.run(.init(prompt: "Which offer should I take?"), in: routed)
        let followUp = await TurnCoordinator(router: Router(classifier: FakeClassifier.always("simple")),
                                             estimator: FixedTokenEstimator(100), isOnline: { true })
            .run(.init(prompt: "Why?"), in: routed)
        #expect(followUp.decision == RouteDecision(route: .cloud, reason: "Follow-up", source: .rule))
    }

    @Test func classifierSeesThePreviousMessage() async {
        let routed = session()
        let recorder = RecordingClassifier()
        let coordinator = TurnCoordinator(router: Router(classifier: recorder), estimator: FixedTokenEstimator(100), isOnline: { true })
        _ = await coordinator.run(.init(prompt: "Plan 3 days in Kyoto"), in: routed)
        _ = await coordinator.run(.init(prompt: "Now do Osaka"), in: routed)
        #expect(recorder.previous.withLock { $0 } == [nil, "Plan 3 days in Kyoto"])
        #expect(routed.lastPromptText == "Now do Osaka")
        #expect(routed.lastRoute == .onDevice)
    }
}

extension RuleOutcome {
    var decidedRoute: Route? {
        if case .decided(let decision) = self { decision.route } else { nil }
    }
}
