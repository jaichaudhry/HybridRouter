import FoundationModels
import Testing
@testable import RouterKit

struct RoutingSupportTests {
    @Test func everyRouteHasANameAndIcon() {
        #expect(Route.allCases.map(\.displayName) == ["On-device", "Apple Cloud", "Claude"])
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
}
