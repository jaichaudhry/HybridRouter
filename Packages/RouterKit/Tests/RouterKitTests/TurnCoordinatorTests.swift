import Foundation
import FoundationModels
import RouterKitTesting
import Testing
@testable import RouterKit

@MainActor
struct TurnCoordinatorTests {
    private let costTable = CostTable(updated: "2026-10-02", source: "test", models: [:])

    private func session(
        onDevice: FakeProvider = FakeProvider(route: .onDevice, reply: "device"),
        appleCloud: FakeProvider = FakeProvider(route: .appleCloud, reply: "cloud"),
        claude: FakeProvider = FakeProvider(route: .claude, reply: "claude")
    ) -> RoutedSession {
        RoutedSession(instructions: "Be brief.", onDevice: onDevice, appleCloud: appleCloud, claude: claude, costTable: costTable)
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
        #expect(outcome.decision == RouteDecision(route: .claude, reason: "Complex reasoning", source: .classifier))
        #expect(outcome.steps.count == 1)
        #expect(outcome.steps[0].classifierLatency != nil)
        #expect(outcome.failure == nil)
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
        let outcome = await coordinator().run(.init(prompt: "Hi"), in: session(
            onDevice: FakeProvider(route: .onDevice, reply: "x", behavior: .contextExceeded),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", behavior: .timeout)
        ))
        #expect(outcome.content == .text("claude"))
        #expect(outcome.steps.map(\.escalationCause) == [nil, "context too long", "timed out"])
    }

    @Test func emptyReplyIsDiscardedAndEscalated() async {
        let appleCloud = FakeProvider(route: .appleCloud, reply: "x", behavior: .empty)
        let claude = FakeProvider(route: .claude, reply: "claude")
        let routed = session(appleCloud: appleCloud, claude: claude)
        let outcome = await coordinator(.always("moderate")).run(.init(prompt: "Plan it"), in: routed)

        #expect(outcome.content == .text("claude"))
        #expect(outcome.steps.count == 2) // the empty attempt still cost tokens
        let claudeSaw = claude.requests.last.map { Array($0) } ?? []
        let prompts = claudeSaw.filter(\.isPrompt)
        #expect(prompts.count == 1) // the failed attempt's prompt was discarded
    }

    @Test func privateTurnFailingOnAppleCloudStopsWithoutClaude() async {
        let claude = FakeProvider(route: .claude, reply: "should not run")
        let outcome = await coordinator(tokens: 10_000).run(
            .init(prompt: "My diagnosis", privacyReason: "Health terms"),
            in: session(
                onDevice: FakeProvider(route: .onDevice, reply: "x", contextLimit: 4_096),
                appleCloud: FakeProvider(route: .appleCloud, reply: "x", contextLimit: 32_768, behavior: .timeout),
                claude: claude
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
        #expect(outcome.decision == RouteDecision(route: .appleCloud, reason: "Quick conversation (too long for On-device)", source: .classifier))
    }

    @Test func blockedTurnReportsWhy() async {
        let off = ProviderAvailability.unavailable(reason: "off")
        let outcome = await coordinator().run(.init(prompt: "Hi"), in: session(
            onDevice: FakeProvider(route: .onDevice, reply: "x", availability: off),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: off),
            claude: FakeProvider(route: .claude, reply: "x", availability: off)
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
            .init(prompt: "Plan Kyoto", structuredOutput: StructuredOutput(schema: RoutedSessionTests.Place.generationSchema, tasks: ["plan"])),
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
            .init(prompt: "5 trip ideas", structuredOutput: output),
            in: session()
        )
        #expect(outcome.content == .text("device"))
        #expect(!output.applies(to: nil))
        #expect(!output.applies(to: RouteClassification(complexity: "complex", task: "chat")))
        #expect(output.applies(to: RouteClassification(complexity: "complex", task: "plan")))
    }

    @Test func repliesThatHitTheLengthCapAreKeptAndFlagged() async {
        let claude = FakeProvider(
            route: .claude,
            reply: "a long answer that stops",
            usage: TokenUsage(input: 10, cachedInput: 0, output: 16_000, reasoning: nil),
            maximumResponseTokens: 16_000
        )
        let outcome = await coordinator(.always("complex")).run(.init(prompt: "Explain everything"), in: session(claude: claude))
        #expect(outcome.content == .text("a long answer that stops"))
        #expect(outcome.failure == "Reply was cut off at the length limit.")
    }

    @Test func appleCloudFallsBackToItsDocumentedContextSize() async {
        #expect(await AppleCloudProvider(isEnabled: false).contextSize() == nil)
        #expect(AppleCloudProvider.documentedContextSize == 32_768)
    }
}
