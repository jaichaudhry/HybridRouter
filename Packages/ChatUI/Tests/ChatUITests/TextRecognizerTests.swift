import CoreGraphics
import CoreText
import Foundation
import HybridRouterKit
import HybridRouterKitTesting
import Testing
import Vision
@testable import ChatUI

@MainActor
struct TextRecognizerTests {
    /// A small receipt: item names on the left, prices on the right of the same line.
    nonisolated static func receipt() -> CGImage {
        let width = 800, height = 400
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 36, nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat) {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        draw("WHOLE FOODS MARKET", x: 40, y: 320)
        draw("KOPP ICE POP", x: 40, y: 220)
        draw("$3.39", x: 600, y: 220)
        draw("TOTAL", x: 40, y: 120)
        draw("$10.81", x: 600, y: 120)
        return context.makeImage()!
    }

    /// Whether Vision can read text on this machine. On GitHub's macOS runners (virtual
    /// machines) it returns nothing, so the tests that need real OCR skip there.
    nonisolated static let canRecognizeText: Bool = {
        let request = VNRecognizeTextRequest()
        try? VNImageRequestHandler(cgImage: receipt()).perform([request])
        return !(request.results ?? []).isEmpty
    }()

    @Test(.enabled(if: canRecognizeText, "Needs Vision text recognition"))
    func readsAReceiptLineByLine() async throws {
        let text = try #require(await TextRecognizer.text(in: ImageInput(Self.receipt(), label: "photo-1")))
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].localizedCaseInsensitiveContains("whole foods"))
        // The item and its price, printed far apart, stay on one line.
        #expect(lines[1].contains("ICE POP") && lines[1].contains("3.39"))
        #expect(lines[2].contains("TOTAL") && lines[2].contains("10.81"))
    }

    @Test func blankImagesHaveNoText() async {
        #expect(await TextRecognizer.text(in: ImageInput(ChatModelTests.image(width: 200, height: 200), label: "blank")) == nil)
    }

    @Test(.enabled(if: canRecognizeText, "Needs Vision text recognition"))
    func theModelGetsTheTextOfAnAttachedPhoto() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "ok")
        let session = RoutedSession(
            instructions: "Be brief.",
            onDevice: onDevice,
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"),
            cloud: FakeProvider(route: .cloud, reply: "claude"),
            costTable: CostTable(updated: "", source: "", models: [:])
        )
        let model = ChatModel(
            session: session,
            coordinator: TurnCoordinator(router: Router(classifier: FakeClassifier.always("simple")), estimator: FixedTokenEstimator(100), isOnline: { true }),
            costTable: CostTable(updated: "", source: "", models: [:])
        )
        model.imagesArePrivate = true
        let photo = ChatAttachment(name: "Photo 1", kind: .image(ImageInput(Self.receipt(), label: "photo-1"), fromScan: false))
        model.attachments = [photo]
        await model.send("Extract the total and merchant")

        let request = String(describing: try #require(onDevice.requests.last))
        #expect(request.contains("Text read on-device from \"Photo 1\""))
        #expect(request.contains("10.81"))
        // What the user sees stays their own words.
        #expect(model.messages[0].content == .text("Extract the total and merchant"))
    }
}
