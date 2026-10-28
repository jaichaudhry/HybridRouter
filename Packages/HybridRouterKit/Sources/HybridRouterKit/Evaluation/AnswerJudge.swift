import Foundation
import FoundationModels

/// Grades one answer to one prompt. It's told nothing about which model wrote the answer.
@MainActor
public protocol AnswerJudge {
    func judge(_ answer: String, to benchmarkCase: QualityBenchmark.Case) async throws -> JudgeVerdict
}

/// A judge's grade, before it's attached to a column.
public struct JudgeVerdict: Sendable, Equatable {
    public var passes: Bool
    public var score: Int
    public var rationale: String
    public var cost: Double?

    public init(passes: Bool, score: Int, rationale: String, cost: Double? = nil) {
        self.passes = passes
        self.score = score
        self.rationale = rationale
        self.cost = cost
    }
}

/// What the judge model generates. The rationale comes first so the verdict follows from it.
@Generable
struct GeneratedVerdict {
    @Guide(description: "Two or three sentences on correctness and whether the request was fully answered.")
    var rationale: String

    @Guide(description: "1 = wrong or unusable, 2 = major problems, 3 = acceptable, 4 = good, 5 = excellent.", .range(1...5))
    var score: Int

    @Guide(description: "True if a careful person would accept this answer for the request: correct, on task, complete enough, nothing invented.")
    var passes: Bool
}

/// Grades with a language model through a `RoutedSession`, so the judge's own cost is measured
/// like any other step. Each answer gets a fresh session, so earlier grades can't influence it.
@MainActor
public struct ModelAnswerJudge: AnswerJudge {
    /// A fresh session whose `route` slot serves the judge model.
    private let makeSession: @MainActor () -> RoutedSession
    private let route: Route

    public init(route: Route = .cloud, makeSession: @escaping @MainActor () -> RoutedSession) {
        self.route = route
        self.makeSession = makeSession
    }

    /// Instructions for the judge's session.
    public static let instructionsForSession = instructions

    static let instructions = """
        You grade answers from an AI assistant. You see a user's request and one answer to it. \
        Decide whether a careful person would accept the answer.

        An answer passes only if it is correct, does what was asked (including any format, length \
        or constraint in the request), is complete enough to be useful, and doesn't invent facts. \
        If an answer key is given, the answer must agree with it; equivalent wording is fine. \
        For questions about current events or policies, hedging and pointing to official sources \
        is correct, not a flaw.

        Don't reward length: a short correct answer beats a long one with an error. Don't penalize \
        style or tone unless the request asked for them. Judge only this answer, on its own merits.
        """

    static func prompt(for benchmarkCase: QualityBenchmark.Case, answer: String) -> String {
        var parts: [String] = []
        if let conversation = benchmarkCase.conversation {
            parts.append("The conversation so far (judge only the final answer, in its context):\n\(conversation)")
        }
        if let previous = benchmarkCase.previousPrompt {
            parts.append("Earlier in the conversation the user asked:\n\(previous)")
        }
        parts.append("Request:\n\(benchmarkCase.prompt)")
        if let criteria = benchmarkCase.criteria {
            parts.append("Answer key:\n\(criteria)")
        }
        parts.append("Answer to grade:\n\(answer)")
        return parts.joined(separator: "\n\n")
    }

    public func judge(_ answer: String, to benchmarkCase: QualityBenchmark.Case) async throws -> JudgeVerdict {
        let result = try await makeSession().respond(
            to: Self.prompt(for: benchmarkCase, answer: answer),
            decision: .forced(route),
            schema: GeneratedVerdict.generationSchema
        )
        guard case .structured(let content) = result.content else {
            throw JudgeError.unstructuredReply
        }
        let verdict = try GeneratedVerdict(content)
        return JudgeVerdict(
            passes: verdict.passes,
            score: min(max(verdict.score, 1), 5),
            rationale: verdict.rationale,
            cost: result.metrics.estimatedCost
        )
    }
}

enum JudgeError: Error {
    case unstructuredReply
}
