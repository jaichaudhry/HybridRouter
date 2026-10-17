import Foundation

/// Measures how well a classifier routes a labeled set of prompts. Shared by the Mac evals
/// and the app's on-device debug screen, so both report the same numbers.
public enum RoutingBenchmark {
    /// A labeled prompt. The labels were reviewed by hand (see Evals/classifier_benchmark.json).
    public struct Case: Codable, Sendable, Identifiable {
        public var id: Int
        public var group: String
        public var prompt: String
        public var complexity: String
        public var task: String
        /// The user message before this one, for follow-ups.
        public var previousPrompt: String?
        /// The previous reply's route, for bare follow-ups like "Why?".
        public var previousRoute: Route?

        public func expectedRoute(mapping: ComplexityMapping = .standard) -> Route? {
            if let previousRoute, FollowUp.isBare(prompt) { return previousRoute }
            return mapping.route(for: complexity)
        }

        var input: RoutingInput {
            RoutingInput(
                availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available],
                followsUpOn: FollowUp.isBare(prompt) ? previousRoute : nil,
                previousPrompt: previousPrompt
            )
        }
    }

    public struct Result: Sendable, Identifiable {
        public let `case`: Case
        public let expected: Route?
        public let decision: RouteDecision?
        public let classification: RouteClassification?
        /// Classifier time, or nil if a rule decided.
        public let latency: TimeInterval?

        public var id: Int { `case`.id }
        public var isMatch: Bool { decision?.route == expected }
    }

    public struct Report: Sendable {
        public let results: [Result]

        /// Also used to summarize a run in progress.
        public init(results: [Result]) {
            self.results = results
        }

        public var matches: Int { results.filter(\.isMatch).count }
        public var accuracy: Double { results.isEmpty ? 0 : Double(matches) / Double(results.count) }
        public var misses: [Result] { results.filter { !$0.isMatch } }

        public var medianLatency: TimeInterval? {
            let sorted = results.compactMap(\.latency).sorted()
            guard !sorted.isEmpty else { return nil }
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }

        /// Accuracy per group, e.g. "trip" or "follow-up".
        public var accuracyByGroup: [(group: String, matches: Int, total: Int)] {
            let groups = results.reduce(into: [String]()) { if !$0.contains($1.case.group) { $0.append($1.case.group) } }
            return groups.map { group in
                let inGroup = results.filter { $0.case.group == group }
                return (group, inGroup.filter(\.isMatch).count, inGroup.count)
            }
        }
    }

    public static func load(_ data: Data) throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: data)
    }

    /// Routes each case in order (one at a time, so latency isn't skewed by contention).
    public static func run(
        _ cases: [Case],
        classifier: any RouteClassifier,
        mapping: ComplexityMapping = .standard,
        onResult: @Sendable (Result) async -> Void = { _ in }
    ) async -> Report {
        let router = Router(classifier: classifier, mapping: mapping, classifierTimeout: nil)
        var results: [Result] = []
        for routingCase in cases {
            let routed = await router.route(routingCase.prompt, input: routingCase.input)
            let result: Result
            switch routed {
            case .routed(let decision, let run):
                result = Result(case: routingCase, expected: routingCase.expectedRoute(mapping: mapping),
                                decision: decision, classification: run?.classification, latency: run?.latency)
            case .blocked:
                result = Result(case: routingCase, expected: routingCase.expectedRoute(mapping: mapping),
                                decision: nil, classification: nil, latency: nil)
            }
            results.append(result)
            await onResult(result)
        }
        return Report(results: results)
    }
}
