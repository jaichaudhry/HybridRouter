import HybridRouterKit
import HybridRouterKitTesting
import Testing
@testable import ChatUI

@MainActor
struct CompareModelTests {
    private func model(claude: FakeProvider = FakeProvider(route: .claude, reply: "from claude"),
                       appleCloud: FakeProvider = FakeProvider(route: .appleCloud, reply: "from cloud")) -> CompareModel {
        CompareModel {
            RoutedSession(
                instructions: "Be brief.",
                onDevice: FakeProvider(route: .onDevice, reply: "from device"),
                appleCloud: appleCloud,
                claude: claude,
                costTable: CostTable(updated: "", source: "", models: [:])
            )
        }
    }

    @Test func everyRouteAnswers() async {
        let compare = model()
        compare.prompt = "Explain refrigerators"
        await compare.run()
        #expect(compare.columns.map(\.content) == [.text("from device"), .text("from cloud"), .text("from claude")])
        #expect(compare.columns.allSatisfy { $0.metrics != nil && !$0.isRunning })
        #expect(!compare.isRunning)
    }

    @Test func privatePromptsSkipClaude() async {
        let claude = FakeProvider(route: .claude, reply: "should not run")
        let compare = model(claude: claude)
        compare.prompt = "My number is (206) 555-0143, summarize my week"
        await compare.run()
        #expect(compare.columns[2].note == "Kept private: phone number")
        #expect(claude.requests.isEmpty)
        #expect(compare.columns[0].content == .text("from device"))
    }

    @Test func unavailableRoutesSayWhy() async {
        let compare = model(appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: .unavailable(reason: "Apple Cloud isn't enabled in this build")))
        compare.prompt = "Hi"
        await compare.run()
        #expect(compare.columns[1].note == "Apple Cloud isn't enabled in this build")
    }

    @Test func failuresAreShownPerColumn() async {
        let compare = model(claude: FakeProvider(route: .claude, reply: "x", behavior: .timeout))
        compare.prompt = "Hi"
        await compare.run()
        #expect(compare.columns[2].note == "Couldn't answer (timed out)")
        #expect(compare.columns[0].content == .text("from device"))
    }
}
