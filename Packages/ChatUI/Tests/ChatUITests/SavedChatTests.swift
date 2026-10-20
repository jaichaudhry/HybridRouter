import CoreGraphics
import Foundation
import HybridRouterKit
import HybridRouterKitTesting
import Testing
@testable import ChatUI

@MainActor
struct SavedChatTests {
    private let costTable = CostTable(updated: "", source: "", models: [:])

    private func makeSession(_ conversation: RestoredConversation = .empty, cloud: FakeProvider = FakeProvider(route: .cloud, reply: "from cloud")) -> RoutedSession {
        RoutedSession(
            instructions: "Be brief.",
            onDevice: FakeProvider(route: .onDevice, reply: "from device"),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: .unavailable(reason: "off")),
            cloud: cloud,
            costTable: costTable,
            history: conversation.history,
            privatePromptIDs: conversation.privatePromptIDs,
            lastRoute: conversation.lastRoute
        )
    }

    private var coordinator: TurnCoordinator {
        TurnCoordinator(router: Router(classifier: FakeClassifier.always("simple")),
                        policy: EscalationPolicy(retryDelay: .zero),
                        estimator: FixedTokenEstimator(100), isOnline: { true })
    }

    private func temporaryStore() -> ChatStore {
        ChatStore(directory: FileManager.default.temporaryDirectory.appending(path: "chats-\(UUID().uuidString)"))
    }

    private static func image() -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        return context.makeImage()!
    }

    @Test func aChatSurvivesSavingAndLoading() async throws {
        let model = ChatModel(session: makeSession(), coordinator: coordinator, costTable: costTable)
        await model.send("My card is 4111 1111 1111 1111")
        model.routeOverride = .cloud
        await model.send("Plan a weekend in Lisbon")
        let id = UUID()
        let store = temporaryStore()
        try await store.save(model.savedChat(id: id, scenarioID: "chat", createdAt: .now))

        let loaded = try await store.load(id)
        #expect(loaded.messages.map(\.content) == model.messages.map(\.content))
        #expect(loaded.messages.map(\.decision) == model.messages.map(\.decision))
        #expect(loaded.messages.allSatisfy { !$0.isStreaming })
        #expect(loaded.title == "My card is 4111 1111 1111 1111")
        #expect(loaded.routeOverride == .cloud)

        // Continuing it: the card number still never reaches the cloud model.
        let cloud = FakeProvider(route: .cloud, reply: "more")
        let restored = try ChatModel(restoring: loaded, makeSession: { makeSession($0, cloud: cloud) },
                                     coordinator: coordinator, costTable: costTable)
        #expect(restored.messages.count == 4)
        #expect(!restored.restoredConservatively)
        await restored.send("Add a museum")
        let seen = String(describing: try #require(cloud.requests.last))
        #expect(!seen.contains("4111"))
        #expect(seen.contains("Plan a weekend in Lisbon"))
    }

    @Test func aFailedTurnStaysOnScreenButNotInTheConversation() async throws {
        let failing = FakeProvider(route: .cloud, reply: "x", behavior: .timeout)
        let model = ChatModel(session: makeSession(cloud: failing), coordinator: coordinator, costTable: costTable)
        model.routeOverride = .cloud
        await model.send("This one fails")
        let saved = model.savedChat(id: UUID(), scenarioID: "chat", createdAt: .now)
        #expect(saved.messages.count == 2)
        #expect(saved.messages[1].errorMessage != nil)
        #expect(saved.conversation.promptCount == 0)
    }

    @Test func thumbnailsAreSavedAsFilesAndDeletedWithTheChat() async throws {
        let attachment = ChatAttachment(name: "Photo 1", kind: .image(ImageInput(Self.image(), label: "photo-1"), fromScan: false))
        let message = ChatMessage(role: .user, content: .text("What's this?"), attachmentNames: ["Photo 1"], attachments: [attachment.preview])
        let chat = SavedChat(id: UUID(), scenarioID: "chat", title: "What's this?", createdAt: .now, updatedAt: .now,
                             messages: [message], conversation: makeSession().snapshot(), routeOverride: nil)
        let store = temporaryStore()
        try await store.save(chat)
        let folder = store.directory.appending(path: chat.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "thumbnails/\(attachment.id.uuidString).jpg").path))

        let loaded = try await store.load(chat.id)
        #expect(loaded.messages[0].attachments.first?.thumbnail != nil)
        #expect(loaded.messages[0].attachments.first?.id == attachment.id)

        try await store.delete(chat.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(await store.list().isEmpty)
    }

    @Test func theListIsNewestFirstAndRebuildsWithoutAnIndex() async throws {
        let store = temporaryStore()
        let snapshot = makeSession().snapshot()
        let older = SavedChat(id: UUID(), scenarioID: "chat", title: "Older", createdAt: .now, updatedAt: .now.addingTimeInterval(-60),
                              messages: [], conversation: snapshot, routeOverride: nil)
        let newer = SavedChat(id: UUID(), scenarioID: "trip", title: "Newer", createdAt: .now, updatedAt: .now,
                              messages: [], conversation: snapshot, routeOverride: nil)
        try await store.save(older)
        try await store.save(newer)
        #expect(await store.list().map(\.title) == ["Newer", "Older"])

        try FileManager.default.removeItem(at: store.directory.appending(path: "index.json"))
        let reopened = ChatStore(directory: store.directory)
        #expect(await reopened.list().map(\.title) == ["Newer", "Older"])
    }

    @Test func deleteAllRemovesEverything() async throws {
        let store = temporaryStore()
        try await store.save(SavedChat(id: UUID(), scenarioID: "chat", title: "x", createdAt: .now, updatedAt: .now,
                                       messages: [], conversation: makeSession().snapshot(), routeOverride: nil))
        try await store.deleteAll()
        #expect(await store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test func autosaveRunsOncePerTurn() async {
        let model = ChatModel(session: makeSession(), coordinator: coordinator, costTable: costTable)
        var finished = 0
        model.onTurnFinished = { finished += 1 }
        await model.send("One")
        await model.send("Two")
        #expect(finished == 2)
    }

    @Test func titlesComeFromTheFirstMessage() {
        #expect(ChatModel.title(for: []) == "New chat")
        let long = String(repeating: "word ", count: 30)
        #expect(ChatModel.title(for: [ChatMessage(role: .user, content: .text(long))]).count == 58)
        #expect(ChatModel.title(for: [ChatMessage(role: .user, content: .text("Line one\nLine two"))]) == "Line one")
    }
}
