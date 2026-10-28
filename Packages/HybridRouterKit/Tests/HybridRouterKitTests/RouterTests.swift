import Foundation
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

struct RouterTests {
    private let everything = RoutingInput(availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available])

    @Test(arguments: [("simple", Route.onDevice), ("moderate", .appleCloud), ("complex", .cloud)])
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

    @Test func classifierFailureSaysWhy() {
        let run = ClassifierRun(classification: nil, latency: 0, failure: .guardrail)
        #expect(Router.decide(run, mapping: .standard, allowed: [.onDevice, .appleCloud], input: everything).reason
            == "Couldn't classify (safety filter), so using a mid-size model")
    }

    @Test func classifierFailureFallsBackToAppleCloud() async {
        let router = Router(classifier: FakeClassifier.failing)
        let result = await router.route("Hi", input: everything)
        #expect(result.decision?.route == .appleCloud)
        guard case .routed(_, let run) = result else { Issue.record("not routed"); return }
        #expect(run?.classification == nil)
    }

    /// Answers after `delay`. With `ignoresCancellation`, it waits on a timer that cancelling
    /// can't interrupt, like a stalled on-device request.
    private struct SlowClassifier: RouteClassifier {
        let delay: Double
        var ignoresCancellation = false

        func classify(_ prompt: String, previous: String?) async throws -> RouteClassification {
            if ignoresCancellation {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
                }
            } else {
                try await Task.sleep(for: .seconds(delay))
            }
            return RouteClassification(complexity: "simple", task: "chat")
        }
    }

    @Test(arguments: [false, true])
    func aStalledClassifierTimesOutAndFallsBack(ignoresCancellation: Bool) async {
        let router = Router(classifier: SlowClassifier(delay: 5, ignoresCancellation: ignoresCancellation),
                            classifierTimeout: .milliseconds(100))
        let start = ContinuousClock.now
        let result = await router.route("Hi", input: everything)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(result.decision == RouteDecision(route: .appleCloud, reason: "Couldn't classify (timed out), so using a mid-size model", source: .classifier))
        guard case .routed(_, let run) = result else { Issue.record("not routed"); return }
        #expect(run?.failure == .timeout)
    }

    @Test func aClassifierWithinTheLimitIsUsed() async {
        let router = Router(classifier: SlowClassifier(delay: 0.05), classifierTimeout: .seconds(2))
        #expect(await router.route("Hi", input: everything).decision?.route == .onDevice)
    }

    @Test func prewarmingReachesTheClassifier() async {
        final class Counter: RouteClassifier, @unchecked Sendable {
            var prewarms = 0
            func classify(_ prompt: String, previous: String?) async throws -> RouteClassification {
                RouteClassification(complexity: "simple", task: "chat")
            }
            func prewarm() async { prewarms += 1 }
        }
        let counter = Counter()
        await Router(classifier: counter).prewarm()
        #expect(counter.prewarms == 1)
    }

    @Test func classifierFailureWithoutAppleCloudUsesTheNearestRoute() {
        let decision = Router.decide(ClassifierRun(classification: nil, latency: 0), mapping: .standard, allowed: [.onDevice], input: everything)
        #expect(decision.route == .onDevice)
    }

    @Test func unknownComplexityIsTreatedAsAFailure() {
        let odd = RouteClassification(complexity: "galactic", task: "chat")
        #expect(Router.decide(ClassifierRun(classification: odd, latency: 0), mapping: .standard, allowed: [.onDevice, .appleCloud], input: everything).route == .appleCloud)
    }

    @Test func unavailableTargetMovesUpAndSaysWhy() {
        let simple = RouteClassification(complexity: "simple", task: "chat")
        var input = everything
        input.availability[.onDevice] = .unavailable(reason: "off")
        let decision = Router.decide(ClassifierRun(classification: simple, latency: 0), mapping: .standard, allowed: [.appleCloud, .cloud], input: input)
        #expect(decision == RouteDecision(route: .appleCloud, reason: "Quick conversation (On-device unavailable)", source: .classifier))
    }

    @Test func longConversationsStillReachClaudeForComplexTurns() async {
        var input = everything
        input.estimatedTokens = 10_000
        input.contextBudgets = [.onDevice: 3_686, .appleCloud: 29_491, .cloud: 900_000]
        let complex = await Router(classifier: FakeClassifier.always("complex", task: "reason")).route("Realistic?", input: input)
        #expect(complex.decision == RouteDecision(route: .cloud, reason: "Complex reasoning", source: .classifier))
        let simple = await Router(classifier: FakeClassifier.always("simple")).route("Thanks", input: input)
        #expect(simple.decision == RouteDecision(route: .appleCloud, reason: "Quick conversation (chat too long for On-device)", source: .classifier, tooLongFor: .onDevice))
    }

    @Test func scenariosCanRemapComplexity() async {
        let mapping = ComplexityMapping(simple: .onDevice, moderate: .cloud, complex: .cloud)
        let router = Router(classifier: FakeClassifier.always("moderate"), mapping: mapping)
        #expect(await router.route("Plan", input: everything).decision?.route == .cloud)
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

struct ExactAnswerTests {
    private let everything = RoutingInput(availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available])

    @Test(arguments: [
        ("How many r's are in the word 'strawberry'?", ExactAnswerDetector.Kind.counting),
        ("Count the words in this sentence: 'The quick brown fox.'", .counting),
        ("Spell 'necessary' backwards.", .counting),
        ("A train leaves at 2:15 pm and travels 200 km at 80 km/h. When does it arrive?", .arithmetic),
        ("What if it goes 60 mph?", .arithmetic),
        ("What's the 5th word in this sentence?", .counting),
        ("What's 17 × 24?", .arithmetic),
        ("What's 18% of 350?", .arithmetic),
        ("Four friends are splitting the trip. Who owes what?", .arithmetic),
        ("If today is Tuesday, what day of the week will it be 100 days from now?", .datesAndTimes),
        ("If I leave Seattle at 9 am on a 10-hour flight, what local time will I land?", .datesAndTimes),
        ("Convert 72 degrees Fahrenheit to Celsius.", .conversions),
        ("Scale this recipe from 4 servings to 6", .conversions),
        // As speech-to-text writes them: spoken letters become words, symbols become words.
        ("How many hours are in the word strawberry?", .counting),
        ("How many ours are in the word strawberry?", .counting),
        ("What is 17 times 24?", .arithmetic),
        ("What's 1200 divided by 7?", .arithmetic),
        ("What is 17×24?", .arithmetic),
    ])
    func spotsQuestionsWithOneExactAnswer(prompt: String, kind: ExactAnswerDetector.Kind) {
        #expect(ExactAnswerDetector.kind(of: prompt) == kind)
    }

    @Test(arguments: [
        "Write a haiku about Monday mornings",
        "Convert this JavaScript to Swift: const evens = nums.filter(n => n % 2 === 0)",
        "Explain how a credit score works",
        "Plan a 3-day trip to Lisbon",
        "Summarize these meeting notes in three bullets",
        "I go running 3 times a week",
        "Prove that the square root of 2 is irrational",
    ])
    func leavesOtherPromptsAlone(prompt: String) {
        #expect(ExactAnswerDetector.kind(of: prompt) == nil)
    }

    @Test func aTimeQuestionStaysATimeQuestion() {
        // "in the word" marks letter counting; without it, "how many hours" is about time.
        #expect(ExactAnswerDetector.kind(of: "How many hours are in a week?") == .datesAndTimes)
    }

    @Test func anExactAnswerGoesToTheCloud() {
        var input = everything
        input.exactAnswer = .counting
        #expect(RoutingRules.evaluate(input) == .decided(RouteDecision(route: .cloud, reason: "Needs an exact answer (counting)", source: .rule)))
    }

    @Test func privacyAndAvailabilityStillWin() {
        var privateTurn = everything
        privateTurn.exactAnswer = .arithmetic
        privateTurn.privacyReason = "card number"
        guard case .decided(let decision) = RoutingRules.evaluate(privateTurn) else { Issue.record("expected a decision"); return }
        #expect(decision.route != .cloud)

        var noCloud = RoutingInput(availability: [.onDevice: .available, .appleCloud: .available, .cloud: .unavailable(reason: "off")])
        noCloud.exactAnswer = .arithmetic
        #expect(RoutingRules.evaluate(noCloud) == .open(allowed: [.onDevice, .appleCloud]))
    }

    @Test func theRouterChecksOnlyWhenAsked() async {
        let prompt = "What's 17 × 24?"
        let off = await Router(classifier: FakeClassifier.always("simple")).route(prompt, input: everything)
        #expect(off.decision?.route == .onDevice)
        let on = await Router(classifier: FakeClassifier.always("simple"), detectsExactAnswers: true).route(prompt, input: everything)
        #expect(on.decision == RouteDecision(route: .cloud, reason: "Needs an exact answer (arithmetic)", source: .rule))
    }

    @Test func aSingleAvailableRouteSkipsTheClassifier() async {
        // The default for a package user with no cloud key and no Private Cloud Compute entitlement.
        let router = Router(classifier: FakeClassifier.always("complex"))
        let input = RoutingInput(availability: [.onDevice: .available, .appleCloud: .unavailable(reason: "off"), .cloud: .unavailable(reason: "off")])
        let result = await router.route("Hi", input: input)
        #expect(result == .routed(RouteDecision(route: .onDevice, reason: "Only On-device is available", source: .rule), classifier: nil))
    }

    @Test func aMappingThatSendsEverythingToOneRouteSkipsTheClassifier() async {
        let router = Router(
            classifier: FakeClassifier.failing,
            mapping: ComplexityMapping(simple: .appleCloud, moderate: .appleCloud, complex: .appleCloud)
        )
        let result = await router.route("Hi", input: everything)
        #expect(result == .routed(RouteDecision(route: .appleCloud, reason: "Every request goes to Apple Cloud here", source: .rule), classifier: nil))
    }

    @Test func aMappingWithAChoiceStillClassifies() async {
        let router = Router(classifier: FakeClassifier.always("simple"))
        var input = everything
        input.availability[.appleCloud] = .unavailable(reason: "off")
        let result = await router.route("Hi", input: input)
        #expect(result.decision?.route == .onDevice)
        #expect(result.decision?.source == .classifier)
    }

    @Test func trimHistoryKeepsTheClassifiersPickWhenTheChatIsTooLong() async {
        var input = everything
        input.estimatedTokens = 5_000
        input.contextBudgets = [.onDevice: 4_000, .appleCloud: 32_000]
        input.baseTokens = 600
        let moves = await Router(classifier: FakeClassifier.always("simple")).route("thanks", input: input)
        #expect(moves.decision?.route == .appleCloud)
        #expect(moves.decision?.tooLongFor == .onDevice)
        #expect(moves.decision?.trimsHistory == false)
        let stays = await Router(classifier: FakeClassifier.always("simple"), whenTooLong: .trimHistory).route("thanks", input: input)
        #expect(stays.decision == RouteDecision(route: .onDevice, reason: "Quick conversation", source: .classifier, historyBudget: 3_400))
    }
}
