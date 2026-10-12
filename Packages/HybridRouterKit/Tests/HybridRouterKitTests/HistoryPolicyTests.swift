import Foundation
import FoundationModels
import Testing
@testable import HybridRouterKit

struct HistoryPolicyTests {
    private func prompt(_ text: String) -> Transcript.Entry {
        .prompt(Transcript.Prompt(segments: [.text(.init(content: text))]))
    }

    private func response(_ text: String) -> Transcript.Entry {
        .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: text))]))
    }

    private func reasoning(_ text: String) -> Transcript.Entry {
        .reasoning(Transcript.Reasoning(segments: [.text(.init(content: text))], signature: Data([1, 2, 3])))
    }

    @Test func earlierTurnsLoseTheirReasoning() {
        let (a, thoughts, answer, b) = (prompt("a"), reasoning("old thoughts"), response("A"), prompt("b"))
        #expect(HistoryPolicy.dropEarlierReasoning([a, thoughts, answer, b]) == [a, answer, b])
    }

    @Test func currentTurnKeepsItsReasoning() {
        let (a, old, answer, b, current) = (prompt("a"), reasoning("old"), response("A"), prompt("b"), reasoning("current"))
        #expect(HistoryPolicy.dropEarlierReasoning([a, old, answer, b, current]) == [a, answer, b, current])
    }

    @Test func historyWithoutPromptsIsUntouched() {
        let history = [reasoning("x")]
        #expect(HistoryPolicy.dropEarlierReasoning(history) == history)
    }
}
