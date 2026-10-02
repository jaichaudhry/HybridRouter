import Foundation
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
        claude: FakeProvider = FakeProvider(route: .claude, reply: "from claude")
    ) -> ChatModel {
        let session = RoutedSession(
            instructions: "Be brief.",
            onDevice: onDevice,
            appleCloud: appleCloud,
            claude: claude,
            costTable: costTable
        )
        return ChatModel(session: session, costTable: costTable)
    }

    @Test func sendingAddsUserAndAssistantMessages() async {
        let model = makeModel()
        model.draft = "Hello"
        await model.send()

        #expect(model.draft.isEmpty)
        #expect(model.messages.map(\.role) == [.user, .assistant])
        #expect(model.messages[1].text == "from device")
        #expect(model.messages[1].isStreaming == false)
        #expect(model.messages[1].metrics?.route == .onDevice)
        #expect(model.isSending == false)
    }

    @Test func overrideForcesTheRoute() async {
        let model = makeModel()
        model.routeOverride = .claude
        await model.send("Think hard")

        let reply = model.messages[1]
        #expect(reply.text == "from claude")
        #expect(reply.decision == .forced(.claude))
    }

    @Test func autoSkipsUnavailableRoutes() async {
        let model = makeModel(
            onDevice: FakeProvider(route: .onDevice, reply: "x", availability: .unavailable(reason: "off")),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: .unavailable(reason: "off"))
        )
        await model.send("Hi")
        #expect(model.messages[1].decision?.route == .claude)
        #expect(model.messages[1].text == "from claude")
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
