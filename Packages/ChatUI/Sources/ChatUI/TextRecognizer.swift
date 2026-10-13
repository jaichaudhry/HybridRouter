import CoreGraphics
import Foundation
import HybridRouterKit
import Vision

/// Reads the text in an attached image on-device with Vision, so every route gets the real
/// text of a receipt or document. Leaving it to the on-device model to call an OCR tool wasn't
/// reliable: it sometimes skipped the call and invented a plausible document instead.
enum TextRecognizer {
    /// The image's text in reading order, one printed line per line, or nil if it has none.
    static func text(in image: ImageInput) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image.cgImage, orientation: image.orientation) else {
            return nil
        }
        let lines = rows(of: observations.compactMap { observation in
            observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox.cgRect) }
        })
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Groups text boxes into printed lines, top to bottom and left to right. Receipts print an
    /// item and its price far apart on one line; Vision returns them as separate boxes.
    /// Boxes are in Vision's normalized coordinates, with the origin at the bottom left.
    static func rows(of boxes: [(text: String, box: CGRect)]) -> [String] {
        var rows: [[(text: String, box: CGRect)]] = []
        for item in boxes.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.last, abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.6 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ")
        }
    }
}
