import Foundation
import FoundationModels
import Synchronization
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

@MainActor
struct TurnCoordinatorTests {
    private let costTable = CostTable(updated: "2026-10-02", source: "test", models: [:])

    private func session(
        onDevice: FakeProvider = FakeProvider(route: .onDevice, reply: "device"),
        appleCloud: FakeProvider = FakeProvider(route: .appleCloud, reply: "cloud"),
        cloud: FakeProvider = FakeProvider(route: .cloud, reply: "claude")
    ) -> RoutedSession {
        RoutedSession(instructions: "Be brief.", onDevice: onDevice, appleCloud: appleCloud, cloud: cloud, costTable: costTable)
    }

    private func coordinator(
        _ classifier: FakeClassifier = .always("simple"),
        tokens: Int = 100,
        online: Bool = true,
        policy: EscalationPolicy = EscalationPolicy()
    ) -> TurnCoordinator {
        TurnCoordinator(
            router: Router(classifier: classifier),
            policy: policy,
            estimator: FixedTokenEstimator(tokens),
            isOnline: { online }
        )
    }

    @Test func classifiedTurnRunsOnItsRoute() async {
        let outcome = await coordinator(.always("complex", task: "reason")).run(.init(prompt: "Hard"), in: session())
        #expect(outcome.content == .text("claude"))
        #expect(outcome.decision == RouteDecision(route: .cloud, reason: "Complex reasoning", source: .classifier))
        #expect(outcome.steps.count == 1)
        #expect(outcome.steps[0].classifierLatency != nil)
        #expect(outcome.failure == nil)
    }

    @Test func askingForClaudeByNameGoesToClaude() async {
        // The classifier would keep this short turn on-device.
        let outcome = await coordinator(.always("simple")).run(.init(prompt: "hmm but claude can?"), in: session())
        #expect(outcome.content == .text("claude"))
        #expect(outcome.decision == RouteDecision(route: .cloud, reason: "You asked for Claude", source: .rule))
    }

    @Test func eventsReportTheRouteThenPartials() async {
        var events: [String] = []
        _ = await coordinator().run(.init(prompt: "Hi"), in: session()) { event in
            switch event {
            case .routed(let decision): events.append("routed:\(decision.route.rawValue)")
            case .partial: if events.last != "partial" { events.append("partial") }
            }
        }
        #expect(events == ["routed:onDevice", "partial"])
    }

    @Test func failureEscalatesOneRouteAndRecordsTheCause() async {
        let onDevice = FakeProvider(route: .onDevice, reply: "x", behavior: .timeout)
        var routes: [Route] = []
        let outcome = await coordinator().run(.init(prompt: "Hi"), in: session(onDevice: onDevice)) { event in
            if case .routed(let decision) = event { routes.append(decision.route) }
        }
        #expect(routes == [.onDevice, .appleCloud])
        #expect(outcome.content == .text("cloud"))
        #expect(outcome.decision == RouteDecision(route: .appleCloud, reason: "Escalated: timed out", source: .escalation))
        #expect(outcome.steps.last?.escalationCause == "timed out")
        #expect(outcome.steps.map(\.route) == [.onDevice, .appleCloud])
        #expect(outcome.steps.map(\.failure) == ["timed out", nil])
        #expect(outcome.steps[0].classifierLatency != nil)
        #expect(outcome.steps[1].classifierLatency == nil)
    }

    @Test func escalationCanClimbTwice() async {
        let outcome = await coordinator(policy: quickRetries).run(.init(prompt: "Hi"), in: session(
            onDevice: FakeProvider(route: .onDevice, reply: "x", behavior: .contextExceeded),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", behavior: .timeout)
        ))
        #expect(outcome.content == .text("claude"))
        // Apple Cloud's timeout gets one retry before the turn moves up.
        #expect(outcome.steps.map(\.route) == [.onDevice, .appleCloud, .appleCloud, .cloud])
        #expect(outcome.steps.map(\.escalationCause) == [nil, "context too long", "timed out", "timed out"])
    }

    @Test func emptyReplyIsDiscardedAndEscalated() async {
        let appleCloud = FakeProvider(route: .appleCloud, reply: "x", behavior: .empty)
        let claude = FakeProvider(route: .cloud, reply: "claude")
        let routed = session(appleCloud: appleCloud, cloud: claude)
        let outcome = await coordinator(.always("moderate")).run(.init(prompt: "Plan it"), in: routed)

        #expect(outcome.content == .text("claude"))
        #expect(outcome.steps.count == 2) // the empty attempt still cost tokens
        let claudeSaw = claude.requests.last.map { Array($0) } ?? []
        let prompts = claudeSaw.filter(\.isPrompt)
        #expect(prompts.count == 1) // the failed attempt's prompt was discarded
    }

    @Test func privateTurnFailingOnAppleCloudStopsWithoutClaude() async {
        let claude = FakeProvider(route: .cloud, reply: "should not run")
        let outcome = await coordinator(tokens: 10_000).run(
            .init(prompt: "My diagnosis", privacyReason: "Health terms"),
            in: session(
                onDevice: FakeProvider(route: .onDevice, reply: "x", contextLimit: 4_096),
                appleCloud: FakeProvider(route: .appleCloud, reply: "x", contextLimit: 32_768, behavior: .timeout),
                cloud: claude
            )
        )
        #expect(outcome.content == nil)
        #expect(outcome.failure == "Kept private, so this wasn't sent to Claude (timed out).")
        #expect(claude.requests.isEmpty)
    }

    @Test func contextFitUsesProviderSizesWithAMargin() async {
        // 4,000 tokens: fits a 4,096 window, but not 90% of it.
        let outcome = await coordinator(tokens: 4_000).run(.init(prompt: "Long"), in: session(
            onDevice: FakeProvider(route: .onDevice, reply: "device", contextLimit: 4_096),
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud", contextLimit: 32_768)
        ))
        #expect(outcome.decision == RouteDecision(route: .appleCloud, reason: "Quick conversation (chat too long for On-device)", source: .classifier, tooLongFor: .onDevice))
    }

    @Test func blockedTurnReportsWhy() async {
        let off = ProviderAvailability.unavailable(reason: "off")
        let outcome = await coordinator().run(.init(prompt: "Hi"), in: session(
            onDevice: FakeProvider(route: .onDevice, reply: "x", availability: off),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: off),
            cloud: FakeProvider(route: .cloud, reply: "x", availability: off)
        ))
        #expect(outcome.failure == "No model is available right now.")
        #expect(outcome.steps.isEmpty)
    }

    @Test func offlineTurnsStayOnDevice() async {
        let outcome = await coordinator(.always("complex"), online: false).run(.init(prompt: "Hi"), in: session())
        #expect(outcome.decision == RouteDecision(route: .onDevice, reason: "Offline", source: .rule))
    }

    @Test func overrideIsNotEscalated() async {
        let outcome = await coordinator().run(
            .init(prompt: "Hi", override: .onDevice),
            in: session(onDevice: FakeProvider(route: .onDevice, reply: "x", behavior: .timeout))
        )
        #expect(outcome.content == nil)
        #expect(outcome.failure == "On-device couldn't answer (timed out). Try another route.")
        #expect(outcome.steps.count == 1) // the failed attempt is still recorded
    }

    @Test func structuredRequestsPassTheSchemaThrough() async throws {
        let appleCloud = FakeProvider(route: .appleCloud, reply: #"{"name": "Kyoto", "days": 3}"#)
        let outcome = await coordinator(.always("moderate", task: "plan")).run(
            .init(prompt: "Plan Kyoto", structuredOutputs: [StructuredOutput(schema: RoutedSessionTests.Place.generationSchema, tasks: ["plan"])]),
            in: session(appleCloud: appleCloud)
        )
        guard case .structured(let content) = outcome.content else {
            Issue.record("Expected structured content")
            return
        }
        #expect(try RoutedSessionTests.Place(content).name == "Kyoto")
    }

    @Test func structuredOutputSkipsTurnsItDoesntApplyTo() async {
        let output = StructuredOutput(schema: RoutedSessionTests.Place.generationSchema, tasks: ["plan"])
        let outcome = await coordinator(.always("simple", task: "plan")).run(
            .init(prompt: "5 trip ideas", structuredOutputs: [output]),
            in: session()
        )
        #expect(outcome.content == .text("device"))
        #expect(!output.applies(to: nil))
        #expect(!output.applies(to: RouteClassification(complexity: "complex", task: "chat")))
        #expect(output.applies(to: RouteClassification(complexity: "complex", task: "plan")))
    }

    @Test func repliesThatHitTheLengthCapAreKeptAndFlagged() async {
        let claude = FakeProvider(
            route: .cloud,
            reply: "a long answer that stops",
            usage: TokenUsage(input: 10, cachedInput: 0, output: 16_000, reasoning: nil),
            maximumResponseTokens: 16_000
        )
        let outcome = await coordinator(.always("complex")).run(.init(prompt: "Explain everything"), in: session(cloud: claude))
        #expect(outcome.content == .text("a long answer that stops"))
        #expect(outcome.failure == "Reply was cut off at the length limit.")
    }

    @Test func appleCloudFallsBackToItsDocumentedContextSize() async {
        #expect(await AppleCloudProvider(isEnabled: false).contextSize() == nil)
        #expect(AppleCloudProvider.documentedContextSize == 32_768)
    }

    // MARK: Retries and fallback

    private let quickRetries = EscalationPolicy(retryDelay: .zero)

    @Test func aRateLimitedCloudTurnIsRetriedAndAnswers() async {
        let cloud = FakeProvider(route: .cloud, reply: "second try", behavior: .rateLimitedFirst(1))
        let outcome = await coordinator(.always("complex"), policy: quickRetries).run(.init(prompt: "Hard"), in: session(cloud: cloud))
        #expect(outcome.content == .text("second try"))
        #expect(outcome.decision?.route == .cloud)
        #expect(outcome.decision?.reason == "Retried: rate limited")
        #expect(outcome.steps.map(\.failure) == ["rate limited", nil])
        #expect(cloud.requests.count == 2)
    }

    @Test func aCloudModelThatStaysRateLimitedFallsBack() async {
        let cloud = FakeProvider(route: .cloud, reply: "x", behavior: .rateLimited)
        let outcome = await coordinator(.always("complex"), policy: quickRetries).run(.init(prompt: "Hard"), in: session(cloud: cloud))
        #expect(outcome.content == .text("cloud"))
        #expect(outcome.decision == RouteDecision(route: .appleCloud, reason: "Fell back: rate limited", source: .escalation))
        #expect(outcome.steps.map(\.route) == [.cloud, .cloud, .appleCloud])
    }

    @Test func aDroppedConnectionFallsBackWithACleanTranscript() async {
        let cloud = FakeProvider(route: .cloud, reply: "partial answer here", behavior: .dropsMidReply)
        let off = ProviderAvailability.unavailable(reason: "off")
        let routed = session(appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: off), cloud: cloud)
        let outcome = await coordinator(.always("complex"), policy: quickRetries).run(.init(prompt: "Hard"), in: routed)
        #expect(outcome.content == .text("device"))
        #expect(outcome.decision?.reason == "Fell back: connection lost")
        // The failed attempts left nothing behind: one prompt, one reply.
        #expect(routed.transcript.filter(\.isPrompt).count == 1)
        #expect(routed.transcript.filter { if case .response = $0 { true } else { false } }.count == 1)
    }

    @Test func goingOfflineMidTurnAnswersOnDevice() async {
        // Online when the turn is routed, offline by the time the cloud request fails.
        let checks = Mutex(0)
        let coordinator = TurnCoordinator(
            router: Router(classifier: FakeClassifier.always("complex")),
            policy: quickRetries,
            estimator: FixedTokenEstimator(100),
            isOnline: { checks.withLock { $0 += 1; return $0 == 1 } }
        )
        let cloud = FakeProvider(route: .cloud, reply: "x", behavior: .offline)
        let outcome = await coordinator.run(.init(prompt: "Hard"), in: session(cloud: cloud))
        #expect(outcome.content == .text("device"))
        #expect(outcome.decision == RouteDecision(route: .onDevice, reason: "Fell back: connection lost", source: .escalation))
        // No retry on the cloud route: it needs the network.
        #expect(cloud.requests.count == 1)
    }

    @Test func aPrivateTurnNeverFallsUpToTheCloud() async {
        let appleCloud = FakeProvider(route: .appleCloud, reply: "x", behavior: .rateLimited)
        let cloud = FakeProvider(route: .cloud, reply: "leaked")
        let outcome = await coordinator(.always("moderate"), policy: quickRetries)
            .run(.init(prompt: "My diagnosis", privacyReason: "health information"), in: session(onDevice: FakeProvider(route: .onDevice, reply: "x", behavior: .timeout), appleCloud: appleCloud, cloud: cloud))
        #expect(outcome.content == nil)
        #expect(cloud.requests.isEmpty)
    }

    @Test func aBusySessionStopsWithoutEscalating() async {
        let slow = FakeProvider(route: .onDevice, reply: "slow", delay: .milliseconds(300))
        let cloud = FakeProvider(route: .cloud, reply: "claude")
        let routed = session(onDevice: slow, cloud: cloud)
        let coordinator = coordinator()
        async let first = coordinator.run(.init(prompt: "One"), in: routed)
        try? await Task.sleep(for: .milliseconds(50))
        let second = await coordinator.run(.init(prompt: "Two"), in: routed)
        #expect(second.failure == "Another reply is still in progress.")
        #expect(second.steps.isEmpty)
        #expect(cloud.requests.isEmpty)
        _ = await first
    }

    @Test func aProviderInTheWrongSlotMakesItsRouteUnavailable() async {
        let routed = RoutedSession(
            instructions: "Be brief.",
            onDevice: FakeProvider(route: .cloud, reply: "wrong"),
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"),
            cloud: FakeProvider(route: .cloud, reply: "claude"),
            costTable: costTable
        )
        guard case .unavailable(let reason) = routed.availability(of: .onDevice) else {
            Issue.record("on-device should be unavailable"); return
        }
        #expect(reason == "Misconfigured: a Cloud model provider was passed for On-device")
        let outcome = await coordinator().run(.init(prompt: "Hi"), in: routed)
        #expect(outcome.content == .text("cloud"))
    }

    // MARK: History windows

    @Test func aWindowedOnDeviceModelFitsALongConversation() async {
        // Each prompt and reply counts as 100 characters, so the whole chat soon outgrows a
        // 300-token on-device window, but its last turn doesn't.
        let onDevice = FakeProvider(route: .onDevice, reply: String(repeating: "x", count: 99), contextLimit: 340)
        func run(_ policy: HistoryPolicy) async -> RouteDecision? {
            let routed = RoutedSession(
                instructions: "", onDevice: onDevice,
                appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: .unavailable(reason: "off")),
                cloud: FakeProvider(route: .cloud, reply: "cloud"), costTable: costTable, historyPolicy: policy
            )
            let coordinator = TurnCoordinator(
                router: Router(classifier: FakeClassifier.always("simple")),
                estimator: CharacterTokenEstimator(reservedOutput: 0),
                contextMargin: 1,
                isOnline: { true }
            )
            var last: RouteDecision?
            for _ in 0..<4 {
                last = await coordinator.run(.init(prompt: String(repeating: "y", count: 100), override: nil), in: routed).decision
            }
            return last
        }
        #expect(await run(.full)?.route == .cloud)
        #expect(await run(.recentTurns(1))?.route == .onDevice)
        #expect(await run(.recentTokens(80))?.route == .onDevice)
    }

    // MARK: Chats too long for the chosen route

    /// Four 200-character turns, then a forced on-device turn with room for about two of them.
    private func longOnDeviceChat(_ coordinator: TurnCoordinator, override: Route?) async -> (TurnCoordinator.Outcome, FakeProvider) {
        let onDevice = FakeProvider(route: .onDevice, reply: String(repeating: "r", count: 100), contextLimit: 260)
        let cloud = FakeProvider(route: .cloud, reply: "cloud")
        let routed = RoutedSession(
            instructions: "", onDevice: onDevice,
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: .unavailable(reason: "off")),
            cloud: cloud, costTable: costTable
        )
        for index in 1...4 {
            _ = await coordinator.run(.init(prompt: "q\(index)" + String(repeating: "p", count: 98), override: .onDevice), in: routed)
        }
        return (await coordinator.run(.init(prompt: "and now?", override: override), in: routed), onDevice)
    }

    private var characterCounting: TurnCoordinator {
        TurnCoordinator(
            router: Router(classifier: FakeClassifier.always("simple")),
            policy: quickRetries,
            estimator: CharacterTokenEstimator(reservedOutput: 0),
            contextMargin: 1,
            isOnline: { true }
        )
    }

    @Test func aForcedRouteAnswersFromRecentTurnsAndSaysSo() async {
        let (outcome, onDevice) = await longOnDeviceChat(characterCounting, override: .onDevice)
        #expect(outcome.content == .text(String(repeating: "r", count: 100)))
        #expect(outcome.decision?.route == .onDevice)
        #expect(outcome.decision?.trimsHistory == true)
        let step = outcome.steps.last
        #expect(step?.earlierTurns == 4)
        #expect((step?.earlierTurnsSeen ?? 99) < 4)
        #expect(step?.leftOutEarlierTurns == true)
        // The model really didn't get the oldest turn.
        let lastRequest = onDevice.requests.last.map { $0.map(\.textForCounting) } ?? []
        #expect(!lastRequest.contains { $0.hasPrefix("q1") })
        #expect(lastRequest.contains { $0.hasPrefix("q4") })
    }

    @Test func autoMovesUpByDefaultWithTheWholeChat() async {
        let (outcome, _) = await longOnDeviceChat(characterCounting, override: nil)
        #expect(outcome.content == .text("cloud"))
        #expect(outcome.decision?.tooLongFor == .onDevice)
        #expect(outcome.steps.last?.leftOutEarlierTurns == false)
    }

    @Test func autoCanBeToldToStayAndTrim() async {
        var coordinator = characterCounting
        coordinator.router.whenTooLong = .trimHistory
        let (outcome, _) = await longOnDeviceChat(coordinator, override: nil)
        #expect(outcome.decision?.route == .onDevice)
        #expect(outcome.steps.last?.leftOutEarlierTurns == true)
    }

    @Test func aWholeChatThatFitsLeavesNothingOut() async {
        let outcome = await coordinator().run(.init(prompt: "Hi"), in: session())
        #expect(outcome.decision?.trimsHistory == false)
        #expect(outcome.steps.last?.earlierTurnsSeen == nil)
    }
}
