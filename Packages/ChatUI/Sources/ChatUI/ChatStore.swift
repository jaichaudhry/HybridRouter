import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saved chats on disk, one folder per chat:
///
///     Application Support/Chats/
///         index.json                  the chat list
///         <id>/chat.json              a SavedChat
///         <id>/thumbnails/<id>.jpg    attachment previews
///
/// Chats hold everything the user said, private turns included, so files are written with
/// complete file protection (unreadable while the device is locked) and the folder is
/// excluded from backups. A save attempted while the device is locked is kept and retried
/// with ``retryPendingSaves()`` once it's unlocked.
public actor ChatStore {
    /// One row of the chat list.
    public struct Summary: Codable, Sendable, Identifiable, Equatable {
        public var id: UUID
        public var scenarioID: String
        public var title: String
        public var updatedAt: Date
        public var messageCount: Int
    }

    public enum StoreError: Error, Equatable {
        case notFound(UUID)
    }

    public nonisolated let directory: URL
    private var index: [Summary]?
    private var pending: [UUID: SavedChat] = [:]

    /// - Parameter directory: where chats are kept; Application Support/Chats by default.
    public init(directory: URL = ChatStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Chats", directoryHint: .isDirectory)
    }

    // MARK: Reading

    /// Saved chats, most recently updated first.
    public func list() -> [Summary] {
        loadIndex().sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A saved chat with its attachment thumbnails.
    public func load(_ id: UUID) throws -> SavedChat {
        let file = folder(id).appending(path: "chat.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw StoreError.notFound(id) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var chat = try decoder.decode(SavedChat.self, from: Data(contentsOf: file))
        for messageIndex in chat.messages.indices {
            for attachmentIndex in chat.messages[messageIndex].attachments.indices {
                let attachment = chat.messages[messageIndex].attachments[attachmentIndex]
                chat.messages[messageIndex].attachments[attachmentIndex].thumbnail = Self.readImage(thumbnailURL(chat.id, attachment.id))
            }
        }
        return chat
    }

    // MARK: Writing

    /// Saves a chat, replacing any earlier save of it. If the device is locked, the save is kept
    /// for ``retryPendingSaves()``.
    public func save(_ chat: SavedChat) throws {
        do {
            try write(chat)
            pending[chat.id] = nil
        } catch {
            pending[chat.id] = chat
            throw error
        }
    }

    /// Writes saves that failed earlier, e.g. while the device was locked.
    public func retryPendingSaves() {
        for chat in pending.values {
            try? save(chat)
        }
    }

    /// Deletes a chat and its thumbnails.
    public func delete(_ id: UUID) throws {
        pending[id] = nil
        if FileManager.default.fileExists(atPath: folder(id).path) {
            try FileManager.default.removeItem(at: folder(id))
        }
        var index = loadIndex()
        index.removeAll { $0.id == id }
        try writeIndex(index)
    }

    /// Deletes every saved chat.
    public func deleteAll() throws {
        pending = [:]
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        index = []
    }

    private func write(_ chat: SavedChat) throws {
        try prepareDirectory(folder(chat.id).appending(path: "thumbnails", directoryHint: .isDirectory))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try Self.writeProtected(encoder.encode(chat), to: folder(chat.id).appending(path: "chat.json"))
        for attachment in chat.messages.flatMap(\.attachments) {
            let url = thumbnailURL(chat.id, attachment.id)
            guard let thumbnail = attachment.thumbnail, !FileManager.default.fileExists(atPath: url.path),
                  let data = Self.jpeg(thumbnail) else { continue }
            try Self.writeProtected(data, to: url)
        }
        var index = loadIndex()
        index.removeAll { $0.id == chat.id }
        index.append(Summary(id: chat.id, scenarioID: chat.scenarioID, title: chat.title,
                             updatedAt: chat.updatedAt, messageCount: chat.messages.count))
        try writeIndex(index)
    }

    // MARK: Index

    private var indexURL: URL { directory.appending(path: "index.json") }

    /// The chat list, rebuilt from the chat folders if the index is missing or unreadable.
    private func loadIndex() -> [Summary] {
        if let index { return index }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: indexURL)).flatMap { try? decoder.decode([Summary].self, from: $0) }
            ?? rebuiltIndex()
        index = loaded
        return loaded
    }

    private func rebuiltIndex() -> [Summary] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "chat.json")),
                  let chat = try? decoder.decode(SavedChat.self, from: data) else { return nil }
            return Summary(id: chat.id, scenarioID: chat.scenarioID, title: chat.title,
                           updatedAt: chat.updatedAt, messageCount: chat.messages.count)
        }
    }

    private func writeIndex(_ summaries: [Summary]) throws {
        index = summaries
        try prepareDirectory(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try Self.writeProtected(encoder.encode(summaries), to: indexURL)
    }

    // MARK: Files

    private func folder(_ id: UUID) -> URL {
        directory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func thumbnailURL(_ chatID: UUID, _ attachmentID: UUID) -> URL {
        folder(chatID).appending(path: "thumbnails/\(attachmentID.uuidString).jpg")
    }

    /// Creates `url` and its parents, and keeps the whole store out of backups.
    private func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: Self.protection)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private static var protection: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.complete]
        #else
        nil
        #endif
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func readImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
