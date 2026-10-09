import FoundationModels

/// Transcript rewrites applied before each request.
enum HistoryPolicy {
    static let withheldPrompt = "[Private message withheld]"
    static let withheldReply = "[Reply withheld]"

    /// What the next request's model may see: earlier reasoning is always dropped, and Claude
    /// gets placeholders instead of private turns (SPEC §8).
    static func prepare(_ entries: [Transcript.Entry], for route: Route, privatePromptIDs: Set<String>) -> [Transcript.Entry] {
        let history = dropEarlierReasoning(entries)
        guard route == .claude, !privatePromptIDs.isEmpty else { return history }
        return withholdPrivateTurns(history, privatePromptIDs: privatePromptIDs)
    }

    /// Replaces each private prompt and its replies with placeholders, and drops the turn's
    /// tool calls and outputs, which can carry the same private details.
    static func withholdPrivateTurns(_ entries: [Transcript.Entry], privatePromptIDs: Set<String>) -> [Transcript.Entry] {
        var inPrivateTurn = false
        return entries.compactMap { entry in
            switch entry {
            case .prompt(let prompt):
                inPrivateTurn = privatePromptIDs.contains(prompt.id)
                return inPrivateTurn
                    ? .prompt(Transcript.Prompt(id: prompt.id, segments: [.text(.init(content: withheldPrompt))]))
                    : entry
            case .response(let response) where inPrivateTurn:
                return .response(Transcript.Response(id: response.id, assetIDs: [], segments: [.text(.init(content: withheldReply))]))
            case .toolCalls, .toolOutput, .reasoning:
                return inPrivateTurn ? nil : entry
            default:
                return entry
            }
        }
    }

    /// Drops reasoning entries from earlier turns.
    ///
    /// Reasoning is model-specific and can carry a signature from the model that produced it.
    /// Claude replays signed reasoning as thinking blocks, so another model's reasoning must not
    /// reach it. Reasoning from the current turn (after the last prompt, e.g. in a tool loop) is kept.
    static func dropEarlierReasoning(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        guard let lastPrompt = entries.lastIndex(where: \.isPrompt) else { return entries }
        return entries.enumerated()
            .filter { index, entry in index > lastPrompt || !entry.isReasoning }
            .map(\.element)
    }
}

extension Transcript.Entry {
    var isPrompt: Bool {
        if case .prompt = self { true } else { false }
    }

    var isReasoning: Bool {
        if case .reasoning = self { true } else { false }
    }
}
