import Foundation
import FoundationModels
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

/// Saving and restoring a conversation, and that private turns stay private across it.
@MainActor
struct SnapshotTests {
    private let costTable = CostTable(updated: "", source: "", models: [:])

    private func session(
        cloud: FakeProvider = FakeProvider(route: .cloud, reply: "Here's a plan"),
        restoring restored: RestoredConversation? = nil
    ) -> RoutedSession {
        RoutedSession(
            instructions: "Be brief.",
            onDevice: FakeProvider(route: .onDevice, reply: "Noted"),
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"),
            cloud: cloud,
            costTable: costTable,
            history: restored?.history ?? [],
            privatePromptIDs: restored?.privatePromptIDs ?? [],
            lastRoute: restored?.lastRoute
        )
    }

    /// A chat with a private turn, a turn after it on-device (withheld too), and a cloud turn.
    private func savedChat() async throws -> (RoutedSession, Data) {
        let routed = session()
        _ = try await routed.respond(to: "My card is 4111 1111 1111 1111", decision: .forced(.onDevice), isPrivate: true)
        _ = try await routed.respond(to: "Read it back", decision: .forced(.onDevice))
        _ = try await routed.respond(to: "Plan a trip to Kyoto", decision: .forced(.cloud))
        return (routed, try JSONEncoder().encode(routed.snapshot()))
    }

    private func decoded(_ data: Data) throws -> ConversationSnapshot {
        try JSONDecoder().decode(ConversationSnapshot.self, from: data)
    }

    /// What the cloud model receives on the next turn of a restored chat.
    private func cloudSees(after restored: RestoredConversation) async throws -> String {
        let cloud = FakeProvider(route: .cloud, reply: "ok")
        _ = try await session(cloud: cloud, restoring: restored).respond(to: "And day two?", decision: .forced(.cloud))
        return String(describing: try #require(cloud.requests.last))
    }

    @Test func aRestoredChatKeepsItsPrivateTurnsFromTheCloud() async throws {
        let (original, data) = try await savedChat()
        let restored = try decoded(data).restore()
        #expect(!restored.isConservative)
        #expect(restored.privatePromptIDs == original.privatePromptIDs)
        #expect(restored.privatePromptIDs.count == 2)
        #expect(restored.lastRoute == .cloud)

        let seen = try await cloudSees(after: restored)
        #expect(!seen.contains("4111"))
        #expect(!seen.contains("Read it back"))
        #expect(seen.contains("Plan a trip to Kyoto"))
        #expect(seen.contains(HistoryPolicy.withheldPrompt))
    }

    @Test func taintCarriesOnAfterARestore() async throws {
        let (_, data) = try await savedChat()
        let restored = session(restoring: try decoded(data).restore())
        // A new on-device turn after the restore saw the private turn, so it's withheld too.
        _ = try await restored.respond(to: "What was the card's last four?", decision: .forced(.onDevice))
        #expect(restored.privatePromptIDs.count == 3)
    }

    @Test func tamperedPrivateIDsMakeTheRestoreConservative() async throws {
        let (_, data) = try await savedChat()
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["privatePromptIDs"] = ["not-a-real-id", "also-not"]
        let restored = try decoded(JSONSerialization.data(withJSONObject: json)).restore()
        #expect(restored.isConservative)
        // Every earlier turn is withheld, including ones that weren't private.
        let seen = try await cloudSees(after: restored)
        #expect(!seen.contains("4111"))
        #expect(!seen.contains("Plan a trip to Kyoto"))
    }

    @Test func aPromptCountMismatchMakesTheRestoreConservative() async throws {
        let (_, data) = try await savedChat()
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["promptCount"] = 7
        #expect(try decoded(JSONSerialization.data(withJSONObject: json)).restore().isConservative)
    }

    @Test func aMissingPrivacyFieldDoesntDecode() async throws {
        let (_, data) = try await savedChat()
        for key in ["privatePromptIDs", "privatePromptOrdinals", "promptCount"] {
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json.removeValue(forKey: key)
            #expect(throws: DecodingError.self) { try decoded(JSONSerialization.data(withJSONObject: json)) }
        }
    }

    @Test func aNewerVersionIsRefused() async throws {
        let (_, data) = try await savedChat()
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 99
        #expect(throws: ConversationSnapshot.RestoreError.unsupportedVersion(99)) {
            try decoded(JSONSerialization.data(withJSONObject: json)).restore()
        }
    }

    @Test func reasoningIsNotSaved() {
        let transcript = Transcript(entries: [
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "Hi"))])),
            .reasoning(Transcript.Reasoning(segments: [.text(.init(content: "thinking"))], signature: Data([1]))),
            .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: "Hello"))])),
        ])
        let snapshot = ConversationSnapshot(transcript: transcript, privatePromptIDs: [], lastRoute: nil)
        #expect(snapshot.transcript.count == 2)
        #expect(!snapshot.transcript.contains { if case .reasoning = $0 { true } else { false } })
    }

    @Test func aBareFollowUpStaysOnTheRestoredLastRoute() async throws {
        let (_, data) = try await savedChat()
        let restored = session(restoring: try decoded(data).restore())
        #expect(restored.lastRoute == .cloud)
    }

    @Test func hybridAssistantSavesAndRestores() async throws {
        func assistant(cloud: FakeProvider, restoring: RestoredConversation? = nil) -> HybridAssistant {
            HybridAssistant(
                instructions: "Be brief.",
                onDevice: FakeProvider(route: .onDevice, reply: "Noted"),
                appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: .unavailable(reason: "off")),
                cloud: cloud,
                router: Router(classifier: FakeClassifier.always("complex")),
                estimator: FixedTokenEstimator(100),
                restoring: restoring,
                isOnline: { true }
            )
        }
        let first = assistant(cloud: FakeProvider(route: .cloud, reply: "plan"))
        _ = await first.respond(to: "Email me at sam@example.com")
        _ = await first.respond(to: "Plan a weekend in Lisbon")
        let data = try JSONEncoder().encode(first.snapshot())

        let cloud = FakeProvider(route: .cloud, reply: "more")
        let second = assistant(cloud: cloud, restoring: try decoded(data).restore())
        #expect(!second.restoredConservatively)
        #expect(second.session.transcript.count == first.session.transcript.count)
        _ = await second.respond(to: "Add a museum")
        let seen = String(describing: try #require(cloud.requests.last))
        #expect(!seen.contains("sam@example.com"))
        #expect(seen.contains("Plan a weekend in Lisbon"))
    }

    @Test func decisionsAndRepliesAreCodable() throws {
        let decision = RouteDecision(route: .onDevice, reason: "Kept private: card number", source: .rule,
                                     historyBudget: 2_000, tooLongFor: .appleCloud, decidedByPrivacy: true)
        #expect(try JSONDecoder().decode(RouteDecision.self, from: JSONEncoder().encode(decision)) == decision)
        let text = TurnContent.text("Hello")
        #expect(try JSONDecoder().decode(TurnContent.self, from: JSONEncoder().encode(text)) == text)
        let structured = TurnContent.structured(GeneratedContent(properties: ["total": 10.81]))
        let back = try JSONDecoder().decode(TurnContent.self, from: JSONEncoder().encode(structured))
        #expect(back.text.contains("10.81"))
    }
}
