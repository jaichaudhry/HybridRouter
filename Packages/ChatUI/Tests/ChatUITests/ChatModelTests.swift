import Foundation
import FoundationModels
import ImageIO
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
        #expect(reply.steps.map(\.route) == [.onDevice, .appleCloud])
    }

    @Test func failedTurnsClearPartialText() async {
        let model = makeModel(claude: FakeProvider(route: .claude, reply: "x", behavior: .timeout))
        model.routeOverride = .claude
        await model.send("Hi")
        #expect(model.messages[1].content == .text(""))
        #expect(model.messages[1].errorMessage == "Claude couldn't answer (timed out). Try another route.")
        #expect(model.messages[1].steps.map(\.failure) == ["timed out"])
    }

    @Test func structuredRepliesAreKeptStructured() async {
        let model = makeModel(
            appleCloud: FakeProvider(route: .appleCloud, reply: #"{"name": "Kyoto"}"#),
            classifier: .always("moderate", task: "plan")
        )
        model.structuredOutputs = [StructuredOutput(schema: Stop.generationSchema, tasks: ["plan"])]
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
        model.replaceSession { history, privatePromptIDs in
            RoutedSession(
                instructions: "Be brief.",
                onDevice: FakeProvider(route: .onDevice, reply: "x"),
                appleCloud: FakeProvider(route: .appleCloud, reply: "x"),
                claude: newClaude,
                costTable: costTable,
                history: history,
                privatePromptIDs: privatePromptIDs
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
        model.replaceSession { history, privatePromptIDs in
            RoutedSession(
                instructions: "Be brief.",
                onDevice: FakeProvider(route: .onDevice, reply: "x"),
                appleCloud: FakeProvider(route: .appleCloud, reply: "x"),
                claude: newClaude,
                costTable: costTable,
                history: history,
                privatePromptIDs: privatePromptIDs
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

import CoreGraphics

extension ChatModelTests {
    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func detectedPrivacyKeepsTheTurnOffClaude() async {
        let claude = FakeProvider(route: .claude, reply: "should not run")
        let model = makeModel(claude: claude, classifier: .always("complex"))
        await model.send("My card is 4111 1111 1111 1111, which plan should I pick?")
        #expect(model.messages[0].privacyReason == "card number")
        #expect(model.messages[1].decision?.route == .onDevice)
        #expect(model.messages[1].decision?.reason == "Kept private: card number")
        #expect(claude.requests.isEmpty)
    }

    @Test func privateToggleAppliesToOneMessage() async {
        let model = makeModel(classifier: .always("complex"))
        model.isPrivate = true
        await model.send("Which offer should I take?")
        #expect(model.messages[1].decision?.route == .onDevice)
        #expect(model.isPrivate == false)
        await model.send("Which offer should I take?")
        #expect(model.messages[3].decision?.route == .claude)
    }

    @Test func forcingClaudeOnAPrivateMessageIsBlocked() async {
        let model = makeModel()
        model.isPrivate = true
        model.routeOverride = .claude
        await model.send("Hello")
        #expect(model.messages[1].errorMessage == "Kept private (marked private), so this can't go to Claude.")
    }

    @Test func scansArePrivateAndAttachmentsClearAfterSending() async {
        let model = makeModel()
        model.attachments = [.scan(Self.image(), name: "Scan 1")]
        #expect(model.canSend)
        await model.send()
        #expect(model.messages[0].privacyReason == "scanned document")
        #expect(model.messages[0].attachmentNames == ["Scan 1"])
        #expect(model.attachments.isEmpty)
    }

    @Test func scenariosCanMakeEveryImagePrivate() async throws {
        let model = makeModel()
        model.imagesArePrivate = true
        let photo = try #require(ChatAttachment.image(data: Self.pngData(), name: "Photo 1"))
        model.attachments = [photo]
        await model.send("What is this?")
        #expect(model.messages[0].privacyReason == "scanned document")
    }

    @Test func documentsAreAddedToThePrompt() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "ok")
        let model = makeModel(onDevice: onDevice)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try "Meeting at noon".write(to: url, atomically: true, encoding: .utf8)
        model.attachments = [try ChatAttachment.document(url: url)]
        await model.send("Summarize")
        let lastRequest = try #require(onDevice.requests.last)
        let saw = String(describing: lastRequest)
        #expect(saw.contains("Meeting at noon"))
        #expect(model.messages[0].content == .text("Summarize"))
    }

    @Test func imageLabelsDontRepeat() {
        #expect(ChatAttachment.uniqueLabel("Scan 1") != ChatAttachment.uniqueLabel("Scan 1"))
        #expect(ChatAttachment.uniqueLabel("Scan 1").hasPrefix("scan-1-"))
    }

    static func pngData() -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image(), nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

extension ChatModelTests {
    /// The leak the M3 review reproduced: a private turn, a key change, then a Claude turn.
    @Test func privateTurnsStayWithheldAfterTheSessionIsRebuilt() async throws {
        let model = makeModel()
        model.isPrivate = true
        await model.send("My SSN is 123-45-6789")

        let newClaude = FakeProvider(route: .claude, reply: "ok")
        model.replaceSession { history, privatePromptIDs in
            RoutedSession(
                instructions: "Be brief.",
                onDevice: FakeProvider(route: .onDevice, reply: "x"),
                appleCloud: FakeProvider(route: .appleCloud, reply: "x"),
                claude: newClaude,
                costTable: costTable,
                history: history,
                privatePromptIDs: privatePromptIDs
            )
        }
        model.routeOverride = .claude
        await model.send("Plan Kyoto")

        let claudeSaw = String(describing: try #require(newClaude.requests.last))
        #expect(!claudeSaw.contains("123-45-6789"))
        #expect(claudeSaw.contains("[Private message withheld]"))
    }
}

extension ChatModelTests {
    @Test func blockedTurnsGiveBackTheDraftAndAttachments() async {
        let model = makeModel()
        model.routeOverride = .claude
        model.draft = "Extract the total"
        model.attachments = [.scan(Self.image(), name: "Scan 1")]
        await model.send()
        #expect(model.messages[1].errorMessage?.hasPrefix("Kept private") == true)
        #expect(model.draft == "Extract the total")
        #expect(model.attachments.count == 1)
    }

    @Test func emptyDocumentsAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).txt")
        try "  \n".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ChatAttachment.DocumentError.self) { try ChatAttachment.document(url: url) }
    }
}

extension ChatModelTests {
    @Test func throttleLetsTheFirstUpdateThroughThenWaits() {
        var throttle = StreamThrottle()
        let first = throttle.shouldUpdate()
        let immediatelyAfter = throttle.shouldUpdate()
        #expect(first)
        #expect(!immediatelyAfter)
    }
}
