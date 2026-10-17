import FoundationModels

/// What each route sees of the conversation. The transcript itself is never trimmed: a route's
/// view of it is, before each request.
///
/// By default every route sees everything. A limit for the on-device model keeps a long
/// conversation within its 4K-token context, so short turns late in a long chat can still stay
/// on the phone, at the cost of the on-device model not seeing older turns:
///
/// ```swift
/// .recentTokens(2_000)          // the most recent turns that fit in about 2,000 tokens
/// .recentTurns(6)               // the last 6 turns, however long
/// ```
///
/// A token limit suits most apps: turns range from about 100 tokens (a short on-device reply)
/// to over 1,000 (an itinerary), so a fixed turn count either forgets too much or doesn't fit.
/// Leave the cloud model's history whole: trimming it shifts the prompt every turn and defeats
/// its prompt cache.
///
/// Whatever the limit, earlier reasoning is always dropped, and the cloud model gets
/// placeholders instead of private turns.
public struct HistoryPolicy: Equatable, Sendable {
    /// How much of the earlier conversation a route sees. A turn is a message and its replies.
    public enum Limit: Equatable, Sendable {
        /// At most this many earlier turns.
        case turns(Int)
        /// The most recent earlier turns that fit in about this many tokens, counted at three
        /// characters a token (on the generous side, like ``CharacterTokenEstimator``). Whole turns
        /// only: a turn that doesn't fit is left out, along with everything before it.
        case tokens(Int)
    }

    /// Each route's limit. A route that isn't listed sees the whole conversation.
    public var limits: [Route: Limit]

    public init(limits: [Route: Limit] = [:]) {
        self.limits = limits
    }

    /// Every route sees the whole conversation.
    public static let full = HistoryPolicy()

    /// The given routes see only the last `turns` earlier turns.
    public static func recentTurns(_ turns: Int, on routes: Set<Route> = [.onDevice]) -> HistoryPolicy {
        HistoryPolicy(limits: Dictionary(uniqueKeysWithValues: routes.map { ($0, .turns(turns)) }))
    }

    /// The given routes see the most recent earlier turns that fit in about `tokens` tokens.
    public static func recentTokens(_ tokens: Int, on routes: Set<Route> = [.onDevice]) -> HistoryPolicy {
        HistoryPolicy(limits: Dictionary(uniqueKeysWithValues: routes.map { ($0, .tokens(tokens)) }))
    }

    static let withheldPrompt = "[Private message withheld]"
    static let withheldReply = "[Reply withheld]"

    /// What the next request's model may see. `entries` ends with the current turn.
    /// - Parameters:
    ///   - turnLimit: a limit for this turn, tighter than the route's own, e.g. when the chat
    ///     is too long for the route.
    ///   - seen: called with how many earlier turns are kept, out of how many, when any are left out.
    func prepare(
        _ entries: [Transcript.Entry],
        for route: Route,
        privatePromptIDs: Set<String>,
        turnLimit: Limit? = nil,
        seen: (_ kept: Int, _ total: Int) -> Void = { _, _ in }
    ) -> [Transcript.Entry] {
        var history = Self.dropEarlierReasoning(entries)
        if let current = history.lastIndex(where: \.isPrompt) {
            let earlierTurns = Array(history[..<current])
            let total = earlierTurns.count(where: \.isPrompt)
            let kept = [limits[route], turnLimit].compactMap { $0 }
                .map { Self.turnsToKeep($0, of: earlierTurns) }
                .min() ?? total
            if kept < total {
                history = Self.keepingLastTurns(kept + 1, of: history)
                seen(kept, total)
            }
        }
        guard route == .cloud, !privatePromptIDs.isEmpty else { return history }
        return Self.withholdPrivateTurns(history, privatePromptIDs: privatePromptIDs)
    }

    /// The earlier conversation `route` will see, for estimating whether the next turn fits.
    /// `history` doesn't include the new message yet.
    public func visibleHistory(_ history: [Transcript.Entry], for route: Route) -> [Transcript.Entry] {
        guard let limit = limits[route] else { return history }
        return Self.keepingLastTurns(Self.turnsToKeep(limit, of: history), of: history)
    }

    /// How many of the most recent turns in `history` the limit allows.
    static func turnsToKeep(_ limit: Limit, of history: [Transcript.Entry]) -> Int {
        switch limit {
        case .turns(let count):
            return max(count, 0)
        case .tokens(let budget):
            let prompts = history.indices.filter { history[$0].isPrompt }
            var used = 0
            var kept = 0
            // Walk back from the most recent turn, keeping whole turns while they fit.
            for (index, start) in prompts.enumerated().reversed() {
                let end = index + 1 < prompts.count ? prompts[index + 1] : history.endIndex
                used += history[start..<end].reduce(0) { $0 + $1.textForCounting.count } / 3
                guard used <= budget else { break }
                kept += 1
            }
            return kept
        }
    }

    /// The last `count` turns, plus anything before the first prompt (such as instructions).
    static func keepingLastTurns(_ count: Int, of entries: [Transcript.Entry]) -> [Transcript.Entry] {
        let prompts = entries.indices.filter { entries[$0].isPrompt }
        guard prompts.count > count, let first = prompts.first else { return entries }
        let preamble = entries[..<first]
        guard count > 0 else { return Array(preamble) }
        return Array(preamble) + entries[prompts[prompts.count - count]...]
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
