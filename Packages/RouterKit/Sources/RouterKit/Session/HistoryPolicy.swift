import FoundationModels

/// Transcript rewrites applied before each request.
enum HistoryPolicy {
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
