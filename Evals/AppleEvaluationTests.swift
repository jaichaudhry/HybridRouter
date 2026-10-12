import Foundation
import FoundationModels
import HybridRouterKit
import Testing
#if canImport(Evaluations)
import Evaluations

/// The classifier benchmark run with Apple's Evaluations framework: the reviewed prompts are
/// the dataset, the router's chosen route is the subject, and a pass/fail metric compares it
/// with the label. Bare follow-ups ("Why?") need a previous route, which ModelSample can't
/// carry, so they're left to ClassifierBenchmarkTests.
struct RoutingEvaluation: Evaluation {
    static let routeMatch = Metric("routeMatch")

    let cases: [RoutingBenchmark.Case]

    var dataset: ArrayLoader<ModelSample<String>> {
        ArrayLoader(samples: cases.compactMap { routingCase in
            guard routingCase.previousRoute == nil, let expected = routingCase.expectedRoute() else { return nil }
            return ModelSample(prompt: routingCase.prompt, expected: expected.rawValue)
        })
    }

    func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
        let routingCase = cases.first { $0.prompt == sample.promptDescription }
        let input = RoutingInput(
            availability: [.onDevice: .available, .appleCloud: .available, .claude: .available],
            previousPrompt: routingCase?.previousPrompt
        )
        let result = await Router(classifier: OnDeviceClassifier()).route(sample.promptDescription, input: input)
        return ModelSubject(value: result.decision?.route.rawValue ?? "blocked")
    }

    var evaluators: Evaluators {
        Evaluator<ModelSample<String>> { sample, subject in
            subject.value == sample.expected
                ? Self.routeMatch.passing()
                : Self.routeMatch.failing(rationale: "Routed to \(subject.value), labeled \(sample.expected ?? "-")")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: Self.routeMatch)
    }
}

struct AppleEvaluationTests {
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Needs the on-device model"))
    func routingEvaluationMeetsTheBar() async throws {
        let evaluation = RoutingEvaluation(cases: ClassifierBenchmarkTests.cases)
        let result = try await evaluation.run(info: ["model": "on-device classifier"])
        let mean = result.aggregateValue(.mean(of: RoutingEvaluation.routeMatch))
        print("EVALUATIONS routeMatch mean \(String(format: "%.2f", mean))")
        let saved = try result.saveJSON(to: FileManager.default.temporaryDirectory)
        print("EVALUATIONS result saved to \(saved.path)")
        // Failing metrics don't fail a test by themselves, so assert the bar.
        #expect(mean >= ClassifierBenchmarkTests.minimumAccuracy)
    }
}
#endif
