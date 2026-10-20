import CoreGraphics
import Foundation
import FoundationModels
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

/// What survives saving a conversation's `Transcript` as JSON and reading it back. Saved chats
/// depend on these: private turns are withheld from the cloud model by prompt ID.
@MainActor
struct TranscriptPersistenceTests {
    private let costTable = CostTable(updated: "", source: "", models: [:])

    private func session(
        onDevice: FakeProvider = FakeProvider(route: .onDevice, reply: "Noted"),
        cloud: FakeProvider = FakeProvider(route: .cloud, reply: "Here's a plan"),
        history: [Transcript.Entry] = [],
        privatePromptIDs: Set<String> = []
    ) -> RoutedSession {
        RoutedSession(
            instructions: "Be brief.",
            onDevice: onDevice,
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"),
            cloud: cloud,
            costTable: costTable,
            history: history,
            privatePromptIDs: privatePromptIDs
        )
    }

    private static func image() -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    private func roundTrip(_ transcript: Transcript) throws -> (Transcript, Data) {
        let data = try JSONEncoder().encode(transcript)
        return (try JSONDecoder().decode(Transcript.self, from: data), data)
    }

    private func promptIDs(_ entries: some Sequence<Transcript.Entry>) -> [String] {
        entries.compactMap { if case .prompt(let prompt) = $0 { prompt.id } else { nil } }
    }

    @Test func entriesAndPromptIDsSurviveARoundTrip() async throws {
        let routed = session()
        _ = try await routed.respond(to: "My number is 206-555-0143", decision: .forced(.onDevice), isPrivate: true)
        _ = try await routed.respond(to: "Plan a trip to Kyoto", decision: .forced(.cloud))

        let (decoded, _) = try roundTrip(routed.transcript)
        #expect(decoded.count == routed.transcript.count)
        #expect(promptIDs(decoded) == promptIDs(routed.transcript))
        #expect(decoded == routed.transcript)
    }

    @Test func aDecodedHistoryKeepsPrivateTurnsFromTheCloud() async throws {
        let first = session()
        _ = try await first.respond(to: "My number is 206-555-0143", decision: .forced(.onDevice), isPrivate: true)
        _ = try await first.respond(to: "Thanks", decision: .forced(.onDevice))
        let (decoded, _) = try roundTrip(first.transcript)

        let cloud = FakeProvider(route: .cloud, reply: "advice")
        let restored = session(cloud: cloud, history: Array(decoded), privatePromptIDs: first.privatePromptIDs)
        // The second turn ran on-device after a private one, so it's withheld too.
        _ = try await restored.respond(to: "Now plan Kyoto", decision: .forced(.cloud))

        let request = try #require(cloud.requests.last)
        let seen = String(describing: request)
        #expect(request.count(where: { if case .instructions = $0 { true } else { false } }) == 1)
        #expect(!seen.contains("555"))
        #expect(seen.contains(HistoryPolicy.withheldPrompt))
    }

    /// Images are kept: the encoder embeds them as JPEG data, so follow-ups such as "read the
    /// receipt again" still work after a restore.
    @Test func imageAttachmentsAreEmbeddedAndComeBack() async throws {
        let routed = session()
        _ = try await routed.respond(to: "What's in this?", images: [ImageInput(Self.image(), label: "photo-1")],
                                     decision: .forced(.onDevice))
        let encoded = try JSONEncoder().encode(routed.transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: encoded)
        let attachments = decoded.flatMap { entry -> [Transcript.AttachmentSegment] in
            guard case .prompt(let prompt) = entry else { return [] }
            return prompt.segments.compactMap { if case .attachment(let attachment) = $0 { attachment } else { nil } }
        }
        #expect(attachments.count == 1)
        #expect(attachments.first?.label == "photo-1")
        #expect(String(decoding: encoded, as: UTF8.self).contains("jpeg;base64,"))
    }

    @Test func reasoningWithASignatureEncodes() throws {
        let transcript = Transcript(entries: [
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "Hi"))])),
            .reasoning(Transcript.Reasoning(segments: [.text(.init(content: "thinking"))], signature: Data([1, 2, 3]))),
            .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: "Hello"))])),
        ])
        let (decoded, _) = try roundTrip(transcript)
        #expect(decoded == transcript)
    }

    @Test func structuredRepliesRoundTripThroughJSON() throws {
        let content = GeneratedContent(properties: ["merchant": "Blue Bottle", "total": 10.81])
        let restored = try GeneratedContent(json: content.jsonString)
        // Key order isn't stable, so compare the parsed values.
        func parsed(_ content: GeneratedContent) throws -> NSDictionary {
            try #require(JSONSerialization.jsonObject(with: Data(content.jsonString.utf8)) as? NSDictionary)
        }
        #expect(try parsed(restored) == parsed(content))
    }
}
