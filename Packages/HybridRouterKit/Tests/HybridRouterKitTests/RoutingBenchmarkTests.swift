import Foundation
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

struct RoutingBenchmarkTests {
    private let cases: [RoutingBenchmark.Case] = [
        .init(id: 1, group: "a", prompt: "Hi", complexity: "simple", task: "chat"),
        .init(id: 2, group: "a", prompt: "Plan Rome", complexity: "moderate", task: "plan"),
        .init(id: 3, group: "b", prompt: "Why?", complexity: "complex", task: "reason", previousRoute: .claude),
    ]

    @Test func reportsAccuracyMissesAndGroups() async {
        // Answers "simple" for everything: right for 1, wrong for 2; 3 is a follow-up rule.
        let report = await RoutingBenchmark.run(cases, classifier: FakeClassifier.always("simple"))
        #expect(report.matches == 2)
        #expect(abs(report.accuracy - 2.0 / 3.0) < 0.0001)
        #expect(report.misses.map(\.id) == [2])
        #expect(report.accuracyByGroup.map(\.group) == ["a", "b"])
        #expect(report.results[2].latency == nil) // decided by the follow-up rule
        #expect(report.medianLatency != nil)
    }

    @Test func casesDecodeFromJSON() throws {
        let json = #"[{"id": 1, "group": "g", "prompt": "Why?", "complexity": "complex", "task": "reason", "previousRoute": "claude"}]"#
        let decoded = try RoutingBenchmark.load(Data(json.utf8))
        #expect(decoded.first?.expectedRoute() == .claude)
    }
}
