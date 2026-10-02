import RouterKitTesting
import Testing
@testable import RouterKit

struct RouterTests {
    private let everything = RoutingInput(availability: [.onDevice: .available, .appleCloud: .available, .claude: .available])

    @Test(arguments: [("simple", Route.onDevice), ("moderate", .appleCloud), ("complex", .claude)])
    func classifierComplexityPicksTheRoute(complexity: String, expected: Route) async {
        let router = Router(classifier: FakeClassifier.always(complexity, task: "plan"))
        let result = await router.route("Hi", input: everything)
        let reason = RouteClassification(complexity: complexity, task: "plan").reason
        #expect(result.decision == RouteDecision(route: expected, reason: reason, source: .classifier))
        guard case .routed(_, let run) = result else { Issue.record("not routed"); return }
        #expect(run?.classification?.complexity == complexity)
        #expect((run?.latency ?? -1) >= 0)
    }

    @Test func rulesSkipTheClassifier() async {
        let router = Router(classifier: FakeClassifier.always("complex"))
        var input = everything
        input.override = .onDevice
        let result = await router.route("Hi", input: input)
        #expect(result == .routed(.forced(.onDevice), classifier: nil))
    }

    @Test func blockedTurnsAreReported() async {
        let router = Router(classifier: FakeClassifier.always("simple"))
        let result = await router.route("Hi", input: RoutingInput(availability: [:]))
        #expect(result == .blocked(reason: "No model is available right now."))
        #expect(result.decision == nil)
    }

    @Test func classifierFailureFallsBackToAppleCloud() async {
        let router = Router(classifier: FakeClassifier.failing)
        let result = await router.route("Hi", input: everything)
        #expect(result.decision?.route == .appleCloud)
        guard case .routed(_, let run) = result else { Issue.record("not routed"); return }
        #expect(run?.classification == nil)
    }

    @Test func classifierFailureWithoutAppleCloudUsesTheNearestRoute() {
        let decision = Router.decide(nil, mapping: .standard, allowed: [.onDevice], input: everything)
        #expect(decision.route == .onDevice)
    }

    @Test func unknownComplexityIsTreatedAsAFailure() {
        let odd = RouteClassification(complexity: "galactic", task: "chat")
        #expect(Router.decide(odd, mapping: .standard, allowed: [.onDevice, .appleCloud], input: everything).route == .appleCloud)
    }

    @Test func unavailableTargetMovesUpAndSaysWhy() {
        let simple = RouteClassification(complexity: "simple", task: "chat")
        var input = everything
        input.availability[.onDevice] = .unavailable(reason: "off")
        let decision = Router.decide(simple, mapping: .standard, allowed: [.appleCloud, .claude], input: input)
        #expect(decision == RouteDecision(route: .appleCloud, reason: "Quick conversation (On-device unavailable)", source: .classifier))
    }

    @Test func longConversationsStillReachClaudeForComplexTurns() async {
        var input = everything
        input.estimatedTokens = 10_000
        input.contextBudgets = [.onDevice: 3_686, .appleCloud: 29_491, .claude: 900_000]
        let complex = await Router(classifier: FakeClassifier.always("complex", task: "reason")).route("Realistic?", input: input)
        #expect(complex.decision == RouteDecision(route: .claude, reason: "Complex reasoning", source: .classifier))
        let simple = await Router(classifier: FakeClassifier.always("simple")).route("Thanks", input: input)
        #expect(simple.decision == RouteDecision(route: .appleCloud, reason: "Quick conversation (too long for On-device)", source: .classifier))
    }

    @Test func scenariosCanRemapComplexity() async {
        let mapping = ComplexityMapping(simple: .onDevice, moderate: .claude, complex: .claude)
        let router = Router(classifier: FakeClassifier.always("moderate"), mapping: mapping)
        #expect(await router.route("Plan", input: everything).decision?.route == .claude)
    }
}

struct RouteClassificationTests {
    @Test func reasonsReadNaturally() {
        #expect(RouteClassification(complexity: "complex", task: "reason").reason == "Complex reasoning")
        #expect(RouteClassification(complexity: "moderate", task: "plan").reason == "Multi-step planning")
        #expect(RouteClassification(complexity: "simple", task: "rewrite").reason == "Quick rewrite")
        #expect(RouteClassification(complexity: "simple", task: "other").reason == "Quick request")
    }
}
