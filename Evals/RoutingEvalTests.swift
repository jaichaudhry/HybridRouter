import Foundation
import FoundationModels
import HybridRouterKit
import HybridRouterKitTesting
import Testing

/// One row of routing_cases.json.
struct RoutingCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Label: Decodable, Sendable {
        var complexity: String
        var task: String
    }

    struct Context: Decodable, Sendable {
        var tokens: Int?
        var `private`: String?
        var image: Bool?
        var offline: Bool?
    }

    var scenario: String
    var prompt: String
    var label: Label
    var expectedRoute: Route
    var context: Context?
    var reason: String

    var testDescription: String { "\(expectedRoute.rawValue): \(prompt)" }

    static let all: [RoutingCase] = {
        struct File: Decodable { var cases: [RoutingCase] }
        guard let url = Bundle.module.url(forResource: "routing_cases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.cases
    }()

    /// Cases the classifier decides (no rule settles them).
    static let classified = all.filter { $0.context == nil }

    /// Routing input with every route available and real-world context sizes.
    var input: RoutingInput {
        RoutingInput(
            privacyReason: context?.private,
            isOnline: !(context?.offline ?? false),
            availability: [.onDevice: .available, .appleCloud: .available, .claude: .available],
            estimatedTokens: context?.tokens ?? 500,
            // 90% of 4,096 on-device, 32,768 Apple Cloud and 1M Claude tokens.
            contextBudgets: [.onDevice: 3_686, .appleCloud: 29_491, .claude: 900_000],
            hasImage: context?.image ?? false,
            visionRoutes: [.onDevice, .appleCloud, .claude]
        )
    }
}

struct RoutingEvalTests {
    @Test func casesLoad() {
        #expect(RoutingCase.all.count >= 12)
        #expect(!RoutingCase.classified.isEmpty)
    }

    /// Runs everywhere, including CI: rules and the routing map with the labeled classification.
    @Test(arguments: RoutingCase.all)
    func routesAsExpected(_ routingCase: RoutingCase) async {
        let label = RouteClassification(complexity: routingCase.label.complexity, task: routingCase.label.task)
        let router = Router(classifier: FakeClassifier([routingCase.prompt: label]))
        let result = await router.route(routingCase.prompt, input: routingCase.input)
        #expect(result.decision?.route == routingCase.expectedRoute, "\(routingCase.reason)")
    }

    /// Runs where Apple Intelligence is available: the real on-device classifier on each prompt.
    @Test(
        .enabled(if: SystemLanguageModel.default.isAvailable, "Needs the on-device model"),
        arguments: RoutingCase.classified
    )
    func liveClassifierRoutesAsExpected(_ routingCase: RoutingCase) async {
        let router = Router(classifier: OnDeviceClassifier(), classifierTimeout: nil)
        let result = await router.route(routingCase.prompt, input: routingCase.input)
        guard case .routed(let decision, let run) = result else {
            Issue.record("Blocked: \(result)")
            return
        }
        #expect(run?.classification != nil, "Classifier failed")
        #expect(decision.route == routingCase.expectedRoute,
                "Classified \(run?.classification?.complexity ?? "-")/\(run?.classification?.task ?? "-") in \(Int((run?.latency ?? 0) * 1000)) ms")
    }
}

/// The 50 hand-reviewed prompts in classifier_benchmark.json, run through the real on-device
/// classifier. The app's debug screen runs the same benchmark on a device.
struct ClassifierBenchmarkTests {
    /// 48/50 when tuned (M1 Max, macOS 27.0). The margin absorbs small model updates.
    static let minimumAccuracy = 0.9

    static let cases: [RoutingBenchmark.Case] = {
        guard let url = Bundle.module.url(forResource: "classifier_benchmark", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? RoutingBenchmark.load(data)) ?? []
    }()

    @Test func benchmarkLoads() {
        #expect(Self.cases.count == 50)
    }

    @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Needs the on-device model"))
    func classifierMeetsTheBenchmark() async {
        let report = await RoutingBenchmark.run(Self.cases, classifier: OnDeviceClassifier())
        let median = Int((report.medianLatency ?? 0) * 1000)
        print("BENCHMARK \(report.matches)/\(report.results.count), median \(median) ms")
        for group in report.accuracyByGroup {
            print("BENCHMARK   \(group.group): \(group.matches)/\(group.total)")
        }
        for miss in report.misses {
            let got = miss.classification.map { "\($0.complexity)/\($0.task)" } ?? "rule"
            print("BENCHMARK   miss #\(miss.case.id) want \(miss.expected?.rawValue ?? "-") got \(miss.decision?.route.rawValue ?? "-") [\(got)]: \(miss.case.prompt)")
        }
        #expect(report.accuracy >= Self.minimumAccuracy)
    }
}
