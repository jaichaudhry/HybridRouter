import Foundation
import FoundationModels
import RouterKit
import RouterKitTesting
import Testing
@testable import ChatUI

@MainActor
struct ChatModelTests {
    private let costTable = CostTable(
        updated: "2026-10-02",
        source: "test",
        models: [
            "apple-on-device": .init(input: 0, cachedInput: 0, output: 0),
            "claude-sonnet-5-5": .init(input: 2, cachedInput: 0.2, output: 10),
        ]
    )

    private func makeModel(
        onDevice: FakeProvider = FakeProvider(route: .onDevice, reply: "from device"),
        appleCloud: FakeProvider = FakeProvider(route: .appleCloud, reply: "from cloud"),
        claude: FakeProvider = FakeProvider(route: .claude, reply: "from claude"),
        classifier: FakeClassifier = .always("simple")
    ) -> ChatModel {
        let session = RoutedSession(
            instructions: "Be brief.",
            onDevice: onDevice,
            appleCloud: appleCloud,
            claude: claude,
            costTable: costTable
        )
        let coordinator = TurnCoordinator(
            router: Router(classifier: classifier),
            estimator: FixedTokenEstimator(100),
            isOnline: { true }
        )
        return ChatModel(session: session, coordinator: coordinator, costTable: costTable)
    }

    @Test func sendingAddsUserAndAssistantMessages() async {
        let model = makeModel()
        model.draft = "Hello"
        await model.send()

        #expect(model.draft.isEmpty)
        #expect(model.messages.map(\.role) == [.user, .assistant])
        #expect(model.messages[1].content == .text("from device"))
        #expect(model.messages[1].isStreaming == false)
        #expect(model.messages[1].metrics?.route == .onDevice)
        #expect(model.isSending == false)
    }

    @Test func overrideForcesTheRoute() async {
        let model = makeModel()
        model.routeOverride = .claude
        await model.send("Think hard")

        let reply = model.messages[1]
        #expect(reply.content == .text("from claude"))
        #expect(reply.decision == .forced(.claude))
    }

    @Test func autoRoutesThroughTheClassifier() async {
        let model = makeModel(classifier: .always("complex", task: "reason"))
        await model.send("Is this realistic?")
        #expect(model.messages[1].decision == RouteDecision(route: .claude, reason: "Complex reasoning", source: .classifier))
        #expect(model.messages[1].content == .text("from claude"))
    }

    @Test func escalationShowsOnTheReply() async {
        let model = makeModel(onDevice: FakeProvider(route: .onDevice, reply: "x", behavior: .timeout))
        await model.send("Hi")
        let reply = model.messages[1]
        #expect(reply.decision?.source == .escalation)
        #expect(reply.decision?.reason == "Escalated: timed out")
        #expect(reply.content == .text("from cloud"))
        #expect(reply.metrics?.escalationCause == "timed out")
    }

    @Test func structuredRepliesAreKeptStructured() async {
        let model = makeModel(
            appleCloud: FakeProvider(route: .appleCloud, reply: #"{"name": "Kyoto"}"#),
            classifier: .always("moderate", task: "plan")
        )
        model.structuredOutput = StructuredOutput(schema: Stop.generationSchema, tasks: ["plan"])
        await model.send("Plan Kyoto")
        guard case .structured(let content) = model.messages[1].content else {
            Issue.record("Expected structured content")
            return
        }
        #expect((try? Stop(content))?.name == "Kyoto")
    }

    @Test func unavailableOverrideShowsTheReason() async {
        let model = makeModel(
            claude: FakeProvider(route: .claude, reply: "x", availability: .unavailable(reason: "Claude not configured"))
        )
        model.routeOverride = .claude
        await model.send("Hi")

        #expect(model.messages[1].errorMessage == "Claude unavailable: Claude not configured")
        #expect(model.messages[1].isStreaming == false)
    }

    @Test func blankDraftsAreIgnored() async {
        let model = makeModel()
        model.draft = "   \n"
        #expect(!model.canSend)
        await model.send()
        #expect(model.messages.isEmpty)
    }

    @Test func summaryAndExportCoverEveryStep() async throws {
        let model = makeModel()
        await model.send("One")
        model.routeOverride = .claude
        await model.send("Two")

        #expect(model.summary.stepCount == 2)
        #expect(model.summary.routeShare[.onDevice] == 0.5)

        let exported = try JSONDecoder().decode([StepMetrics].self, from: model.exportMetrics())
        #expect(exported.map(\.route) == [.onDevice, .claude])
    }
}

extension ChatModelTests {
    @Test func replacingTheSessionKeepsTheConversation() async throws {
        let model = makeModel()
        await model.send("Remember me")

        let newClaude = FakeProvider(route: .claude, reply: "I remember")
        model.replaceSession { history in
            RoutedSession(
                instructions: "Be brief.",
                onDevice: FakeProvider(route: .onDevice, reply: "x"),
                appleCloud: FakeProvider(route: .appleCloud, reply: "x"),
                claude: newClaude,
                costTable: costTable,
                history: history
            )
        }
        model.routeOverride = .claude
        await model.send("Do you?")

        #expect(model.messages.last?.content == .text("I remember"))
        // The new Claude model saw both prompts, including the one sent before the swap.
        let prompts = try #require(newClaude.requests.last).filter { entry in
            if case .prompt = entry { true } else { false }
        }
        #expect(prompts.count == 2)
    }
}

extension ChatModelTests {
    @Test func replacingTheSessionMidReplyAppliesWhenTheReplyEnds() async throws {
        let model = makeModel(onDevice: FakeProvider(route: .onDevice, reply: "slow", delay: .milliseconds(200)))
        let sending = Task { await model.send("First") }
        while !model.isSending { await Task.yield() }

        let newClaude = FakeProvider(route: .claude, reply: "new key works")
        model.replaceSession { history in
            RoutedSession(
                instructions: "Be brief.",
                onDevice: FakeProvider(route: .onDevice, reply: "x"),
                appleCloud: FakeProvider(route: .appleCloud, reply: "x"),
                claude: newClaude,
                costTable: costTable,
                history: history
            )
        }
        await sending.value
        #expect(model.messages[1].content == .text("slow"))

        model.routeOverride = .claude
        await model.send("Second")
        #expect(model.messages.last?.content == .text("new key works"))
        // The swapped-in session kept the reply that was streaming during the swap.
        let responses = try #require(newClaude.requests.last).filter { entry in
            if case .response = entry { true } else { false }
        }
        #expect(responses.count == 1)
    }
}

@Generable
struct Stop {
    var name: String
}
