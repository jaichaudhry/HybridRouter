import Foundation
import HybridRouterKit

/// A chat as saved by ``ChatStore``: what's on screen and the conversation behind it.
///
/// Both are kept because they differ: a failed turn stays on screen but isn't in the
/// conversation, and the conversation's prompts include document and on-device OCR text the
/// messages don't show.
public struct SavedChat: Codable, Sendable, Identifiable {
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public var id: UUID
    /// Which of the app's scenarios the chat belongs to.
    public var scenarioID: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    /// The conversation, with its private turns; see ``ConversationSnapshot``.
    public var conversation: ConversationSnapshot
    public var routeOverride: Route?

    public init(
        id: UUID,
        scenarioID: String,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        messages: [ChatMessage],
        conversation: ConversationSnapshot,
        routeOverride: Route?
    ) {
        self.id = id
        self.scenarioID = scenarioID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.conversation = conversation
        self.routeOverride = routeOverride
    }
}
