import CoreGraphics
import Foundation
import FoundationModels
import RouterKitTesting
import Testing
@testable import RouterKit

@MainActor
struct AttachmentsAndToolsTests {
    struct ScanTool: Tool {
        let name = "scan"
        let description = "Reads an attached image."
        @Generable struct Arguments { var label: String }
        func call(arguments: Arguments) async throws -> String { "text" }
    }

    struct SharedTool: Tool {
        let name = "shared"
        let description = "Available everywhere."
        @Generable struct Arguments { var query: String }
        func call(arguments: Arguments) async throws -> String { "ok" }
    }

    @Generable struct Receipt { var total: String }
    @Generable struct Summary { var points: [String] }

    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func session(onDevice: FakeProvider, claude: FakeProvider = FakeProvider(route: .claude, reply: "claude")) -> RoutedSession {
        RoutedSession(
            instructions: "Be brief.",
            tools: [SharedTool()],
            appleOnlyTools: [ScanTool()],
            onDevice: onDevice,
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"),
            claude: claude,
            costTable: CostTable(updated: "", source: "", models: [:])
        )
    }

    @Test func imagesAreAttachedWithTheirLabelNamedInTheText() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "Total $42")
        let routed = session(onDevice: onDevice)
        _ = try await routed.respond(to: "Extract the total", images: [ImageInput(Self.image(), label: "receipt-1")],
                                     decision: .forced(.onDevice))

        let saw = try #require(onDevice.requests.last)
        guard case .prompt(let prompt) = saw.last(where: \.isPrompt) else {
            Issue.record("No prompt")
            return
        }
        let attachments = prompt.segments.compactMap { segment -> Transcript.AttachmentSegment? in
            if case .attachment(let attachment) = segment { attachment } else { nil }
        }
        #expect(attachments.count == 1)
        #expect(attachments.first?.label == "receipt-1")
        let text = prompt.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
        #expect(text.contains("(Attached image: receipt-1)"))
    }

    @Test func appleOnlyToolsAreLeftOutOfClaudeTurns() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "a")
        let claude = FakeProvider(route: .claude, reply: "b")
        let routed = session(onDevice: onDevice, claude: claude)
        _ = try await routed.respond(to: "Hi", decision: .forced(.onDevice))
        _ = try await routed.respond(to: "Again", decision: .forced(.claude))
        #expect(Set(onDevice.offeredTools) == ["shared", "scan"])
        #expect(claude.offeredTools == ["shared"])
    }

    @Test func imageTurnsRouteOnDevice() async {
        let routed = session(onDevice: FakeProvider(route: .onDevice, reply: "Total $42"))
        let coordinator = TurnCoordinator(router: Router(classifier: FakeClassifier.always("complex")),
                                          estimator: FixedTokenEstimator(100), isOnline: { true })
        let outcome = await coordinator.run(
            .init(prompt: "What's the total?", images: [ImageInput(Self.image(), label: "receipt-1")]),
            in: routed
        )
        #expect(outcome.decision == RouteDecision(route: .onDevice, reason: "Image attached", source: .rule))
    }

    @Test func theFirstMatchingStructuredOutputWins() async {
        let receipt = StructuredOutput(schema: Receipt.generationSchema, tasks: ["extract"], complexities: ["simple", "moderate", "complex"])
        let summary = StructuredOutput(schema: Summary.generationSchema, tasks: ["summarize"])
        let routed = session(onDevice: FakeProvider(route: .onDevice, reply: #"{"total": "$42"}"#))
        let coordinator = TurnCoordinator(router: Router(classifier: FakeClassifier.always("simple", task: "extract")),
                                          estimator: FixedTokenEstimator(100), isOnline: { true })
        let outcome = await coordinator.run(.init(prompt: "Total?", structuredOutputs: [summary, receipt]), in: routed)
        guard case .structured(let content) = outcome.content else {
            Issue.record("Expected structured content")
            return
        }
        #expect((try? Receipt(content))?.total == "$42")
    }

    @Test func scannedImagesGetTheirSchemaEvenWhenARuleRoutes() async {
        let receipt = StructuredOutput(schema: Receipt.generationSchema, tasks: ["extract"],
                                       complexities: ["simple", "moderate"], requiresImage: true)
        let routed = session(onDevice: FakeProvider(route: .onDevice, reply: #"{"total": "$42"}"#))
        let coordinator = TurnCoordinator(router: Router(classifier: FakeClassifier.always("simple", task: "extract")),
                                          estimator: FixedTokenEstimator(100), isOnline: { true })
        let outcome = await coordinator.run(
            .init(prompt: "Extract the total", images: [ImageInput(Self.image(), label: "scan-1")],
                  privacyReason: "scanned document", structuredOutputs: [receipt]),
            in: routed
        )
        #expect(outcome.decision?.source == .rule)
        guard case .structured(let content) = outcome.content else {
            Issue.record("Expected a structured receipt")
            return
        }
        #expect((try? Receipt(content))?.total == "$42")
    }

    @Test func imageOnlySchemasSkipTextTurns() {
        let receipt = StructuredOutput(schema: Receipt.generationSchema, tasks: ["extract"], requiresImage: true)
        let label = RouteClassification(complexity: "moderate", task: "extract")
        #expect(!receipt.applies(to: label, hasImage: false))
        #expect(receipt.applies(to: label, hasImage: true))
    }

    @Test func classifierSeesOnlyTheOpeningOfALongMessage() {
        let long = String(repeating: "clause ", count: 2_000)
        #expect(OnDeviceClassifier.classifierPrompt(long, previous: nil).count == OnDeviceClassifier.promptCharacterLimit)
    }
}
