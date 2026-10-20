import Foundation
import FoundationModels

/// A conversation saved for later: the transcript and which turns were private.
///
/// ```swift
/// let data = try JSONEncoder().encode(assistant.snapshot())
/// // …later, after a relaunch…
/// let restored = try JSONDecoder().decode(ConversationSnapshot.self, from: data).restore()
/// let assistant = HybridAssistant(instructions: "…", cloud: .claude(apiKey: key), restoring: restored)
/// ```
///
/// Private turns are withheld from the cloud model by their prompt's ID, so losing track of them
/// would send private content to it. Restoring therefore fails closed: if the saved private turns
/// don't line up with the transcript, every earlier turn is treated as private.
///
/// Images in the transcript are kept (as JPEG), so follow-ups that re-read them still work.
/// Earlier reasoning is dropped: it's never sent again anyway. Store snapshots with file
/// protection: they contain everything the user said, private turns included.
public struct ConversationSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let transcript: Transcript
    /// The private turns, by position among the transcript's prompts. Positions don't depend on
    /// IDs surviving the round trip.
    public let privatePromptOrdinals: [Int]
    /// The same turns by prompt ID, as a cross-check.
    public let privatePromptIDs: [String]
    /// How many prompts the transcript held when saved, as a cross-check.
    public let promptCount: Int
    /// The route of the last reply, for keeping bare follow-ups ("Why?") on it.
    public let lastRoute: Route?

    public init(transcript: Transcript, privatePromptIDs: Set<String>, lastRoute: Route?) {
        let entries = HistoryPolicy.droppingReasoning(Array(transcript))
        let prompts = Self.promptIDs(entries)
        version = Self.currentVersion
        self.transcript = Transcript(entries: entries)
        privatePromptOrdinals = prompts.indices.filter { privatePromptIDs.contains(prompts[$0]) }
        self.privatePromptIDs = privatePromptOrdinals.map { prompts[$0] }
        promptCount = prompts.count
        self.lastRoute = lastRoute
    }

    public enum RestoreError: Error, Equatable {
        /// Saved by a newer version of HybridRouterKit.
        case unsupportedVersion(Int)
    }

    /// The conversation ready for a new session or assistant.
    /// - Throws: ``RestoreError/unsupportedVersion(_:)`` for a snapshot from a newer version.
    public func restore() throws -> RestoredConversation {
        guard version == Self.currentVersion else { throw RestoreError.unsupportedVersion(version) }
        let history = Array(transcript)
        let prompts = Self.promptIDs(history)
        let byPosition = privatePromptOrdinals.compactMap { prompts.indices.contains($0) ? prompts[$0] : nil }
        let consistent = prompts.count == promptCount
            && byPosition.count == privatePromptOrdinals.count
            && byPosition == privatePromptIDs
        return RestoredConversation(
            history: history,
            // If anything doesn't line up, keep every earlier turn from the cloud model.
            privatePromptIDs: consistent ? Set(byPosition) : Set(prompts),
            lastRoute: lastRoute,
            isConservative: !consistent
        )
    }

    static func promptIDs(_ entries: [Transcript.Entry]) -> [String] {
        entries.compactMap { if case .prompt(let prompt) = $0 { prompt.id } else { nil } }
    }
}

/// A conversation read back from a ``ConversationSnapshot``, for a new ``RoutedSession`` or
/// ``HybridAssistant``.
public struct RestoredConversation: Sendable {
    public let history: [Transcript.Entry]
    public let privatePromptIDs: Set<String>
    public let lastRoute: Route?
    /// The saved private turns didn't line up with the transcript, so every earlier turn is
    /// treated as private: the cloud model sees none of them. Worth telling the user.
    public let isConservative: Bool

    public init(history: [Transcript.Entry], privatePromptIDs: Set<String>, lastRoute: Route?, isConservative: Bool = false) {
        self.history = history
        self.privatePromptIDs = privatePromptIDs
        self.lastRoute = lastRoute
        self.isConservative = isConservative
    }

    /// No earlier conversation.
    public static let empty = RestoredConversation(history: [], privatePromptIDs: [], lastRoute: nil)
}

extension RoutedSession {
    /// The conversation so far, to save and restore later.
    public func snapshot() -> ConversationSnapshot {
        ConversationSnapshot(transcript: transcript, privatePromptIDs: privatePromptIDs, lastRoute: lastRoute)
    }
}

extension HistoryPolicy {
    /// The entries without any reasoning. Reasoning carries model-specific signatures and is
    /// never sent again for earlier turns.
    static func droppingReasoning(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        entries.filter { !$0.isReasoning }
    }
}
