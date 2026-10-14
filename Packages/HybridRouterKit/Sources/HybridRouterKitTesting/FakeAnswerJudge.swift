import HybridRouterKit

/// A judge that passes or fails answers by rule, for testing the quality benchmark offline.
@MainActor
public final class FakeAnswerJudge: AnswerJudge {
    private let passes: (String, QualityBenchmark.Case) -> Bool
    private let cost: Double?
    /// Every answer it was asked to grade, in order.
    public private(set) var judged: [String] = []

    /// - Parameters:
    ///   - cost: reported per judgment, in USD.
    ///   - passes: decides each grade from the answer and the case.
    public init(cost: Double? = nil, passes: @escaping (String, QualityBenchmark.Case) -> Bool) {
        self.cost = cost
        self.passes = passes
    }

    /// Passes answers whose text contains `substring`.
    public static func passing(containing substring: String, cost: Double? = nil) -> FakeAnswerJudge {
        FakeAnswerJudge(cost: cost) { answer, _ in answer.contains(substring) }
    }

    public func judge(_ answer: String, to benchmarkCase: QualityBenchmark.Case) async throws -> JudgeVerdict {
        judged.append(answer)
        let passed = passes(answer, benchmarkCase)
        return JudgeVerdict(passes: passed, score: passed ? 5 : 2, rationale: passed ? "fake pass" : "fake fail", cost: cost)
    }
}
