import Synchronization
import RouterKitTesting
import Testing
@testable import RouterKit

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
            availability: [.onDevice: .available, .appleCloud: .available, .claude: .available],
            followsUpOn: .claude
        )
        #expect(RoutingRules.evaluate(input) == .decided(RouteDecision(route: .claude, reason: "Follow-up", source: .rule)))
    }

    @Test func followUpCantBreakPrivacy() {
        let input = RoutingInput(
            privacyReason: "Medical",
            availability: [.onDevice: .available, .appleCloud: .available, .claude: .available],
            followsUpOn: .claude
        )
        #expect(RoutingRules.evaluate(input).decidedRoute == .onDevice)
    }

    @Test func shortMessagesGetThePreviousOne() {
        let prompt = OnDeviceClassifier.classifierPrompt("Now do the same for Osaka", previous: "Plan 3 days in Kyoto")
        #expect(prompt == "Previous message: Plan 3 days in Kyoto\nMessage to label: Now do the same for Osaka")
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
            claude: FakeProvider(route: .claude, reply: "claude"),
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
        #expect(followUp.decision == RouteDecision(route: .claude, reason: "Follow-up", source: .rule))
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
