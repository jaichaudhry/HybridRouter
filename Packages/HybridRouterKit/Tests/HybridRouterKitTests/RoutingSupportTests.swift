import FoundationModels
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

struct RoutingSupportTests {
    @Test func everyRouteHasANameAndIcon() {
        #expect(Route.allCases.map(\.displayName) == ["On-device", "Apple Cloud", "Cloud model"])
        #expect(Set(Route.allCases.map(\.symbolName)).count == Route.allCases.count)
    }

    @Test func characterEstimateGrowsWithTextAndReservesOutput() async {
        let estimator = CharacterTokenEstimator(reservedOutput: 100)
        let short = await estimator.estimate(history: [], prompt: "hi")
        let long = await estimator.estimate(history: [], prompt: String(repeating: "word ", count: 300))
        #expect(short == 100)
        #expect(long == 100 + 1_500 / 3)
    }

    @Test func onDeviceEstimateReservesOutputWithOrWithoutTheModel() async {
        // Uses the real tokenizer where Apple Intelligence is available, the character estimate elsewhere.
        let estimate = await OnDeviceTokenEstimator(reservedOutput: 500).estimate(history: [], prompt: "Plan a trip to Kyoto")
        #expect(estimate > 500)
        #expect(estimate < 600)
    }

    @Test func networkMonitorStartsAndReports() {
        let monitor = NetworkMonitor()
        _ = monitor.isOnline
    }

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Needs the on-device model"))
    func liveClassifierReturnsAllowedLabels() async throws {
        let classification = try await OnDeviceClassifier().classify("Thanks!")
        #expect(["simple", "moderate", "complex"].contains(classification.complexity))
        #expect(ComplexityMapping.standard.route(for: classification.complexity) != nil)
    }

    @MainActor @Test func theEstimateCountsInstructionsNotesAndTools() {
        let session = RoutedSession(
            instructions: "You are a travel assistant.",
            tools: [EchoTool()],
            onDevice: FakeProvider(route: .onDevice, reply: "x"),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x"),
            cloud: FakeProvider(route: .cloud, reply: "x"),
            costTable: CostTable(updated: "", source: "", models: [:])
        )
        #expect(session.fixedPromptText.contains("You are a travel assistant."))
        #expect(session.fixedPromptText.contains("This conversation is shared by 3 models"))
        #expect(session.fixedPromptText.contains("echo: Repeats its input"))
    }

    @Test func characterEstimateCountsTextNotDebugDescriptions() async {
        let entry = Transcript.Entry.prompt(Transcript.Prompt(segments: [.text(.init(content: String(repeating: "a", count: 300)))]))
        let estimate = await CharacterTokenEstimator(reservedOutput: 0).estimate(history: [entry], prompt: "")
        #expect(estimate == 100)
    }
}

private struct EchoTool: Tool {
    let name = "echo"
    let description = "Repeats its input"
    @Generable struct Arguments { var text: String }
    func call(arguments: Arguments) async throws -> String { arguments.text }
}
