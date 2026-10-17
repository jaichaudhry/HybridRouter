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

    // MARK: Windows

    private func turns(_ count: Int) -> [Transcript.Entry] {
        (1...count).flatMap { [prompt("q\($0)"), response("a\($0)")] }
    }

    private func texts(_ entries: [Transcript.Entry]) -> [String] {
        entries.map(\.textForCounting)
    }

    @Test func fullHistoryIsUntouched() {
        let history = turns(5) + [prompt("now")]
        #expect(HistoryPolicy.full.prepare(history, for: .onDevice, privatePromptIDs: []) == history)
    }

    @Test func aWindowKeepsTheCurrentTurnAndTheLastEarlierOnes() {
        let policy = HistoryPolicy.recentTurns(2)
        let history = turns(5) + [prompt("now")]
        #expect(texts(policy.prepare(history, for: .onDevice, privatePromptIDs: [])) == ["q4", "a4", "q5", "a5", "now"])
        // Other routes still see everything.
        #expect(policy.prepare(history, for: .cloud, privatePromptIDs: []) == history)
    }

    @Test func aZeroWindowKeepsOnlyTheCurrentTurn() {
        let history = turns(3) + [prompt("now")]
        #expect(texts(HistoryPolicy.recentTurns(0).prepare(history, for: .onDevice, privatePromptIDs: [])) == ["now"])
    }

    @Test func instructionsBeforeTheFirstTurnAreKept() {
        let instructions = Transcript.Entry.instructions(Transcript.Instructions(segments: [.text(.init(content: "Be brief."))], toolDefinitions: []))
        let history = [instructions] + turns(3) + [prompt("now")]
        #expect(texts(HistoryPolicy.recentTurns(1).prepare(history, for: .onDevice, privatePromptIDs: [])) == ["Be brief.", "q3", "a3", "now"])
    }

    @Test func visibleHistoryExcludesTheNewMessage() {
        #expect(texts(HistoryPolicy.recentTurns(1).visibleHistory(turns(3), for: .onDevice)) == ["q3", "a3"])
        #expect(texts(HistoryPolicy.recentTurns(1).visibleHistory(turns(3), for: .appleCloud)) == ["q1", "a1", "q2", "a2", "q3", "a3"])
    }

    @Test func aTokenLimitKeepsTheRecentTurnsThatFit() {
        // Each turn below is 600 characters, about 200 tokens.
        let long = String(repeating: "x", count: 300)
        let history = (1...5).flatMap { [prompt("q\($0)" + long.dropFirst(2)), response(long)] }
        #expect(HistoryPolicy.turnsToKeep(.tokens(450), of: history) == 2)
        #expect(HistoryPolicy.turnsToKeep(.tokens(199), of: history) == 0)
        #expect(HistoryPolicy.turnsToKeep(.tokens(10_000), of: history) == 5)
        let seen = HistoryPolicy.recentTokens(450).prepare(history + [prompt("now")], for: .onDevice, privatePromptIDs: [])
        #expect(texts(seen).map { String($0.prefix(2)) } == ["q4", "xx", "q5", "xx", "no"])
    }

    @Test func aTokenLimitAdaptsToTurnLength() {
        // The same budget keeps many short turns, or one long one.
        let short = turns(20)
        #expect(HistoryPolicy.turnsToKeep(.tokens(40), of: short) == 20)
        let long = [prompt("plan"), response(String(repeating: "y", count: 3_000)), prompt("thanks"), response("ok")]
        #expect(HistoryPolicy.turnsToKeep(.tokens(40), of: long) == 1)
    }
}
