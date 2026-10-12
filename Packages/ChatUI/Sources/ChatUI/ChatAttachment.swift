import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import HybridRouterKit

/// Something attached to the next message.
public struct ChatAttachment: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// An image; scans from the document camera are always private.
        case image(ImageInput, fromScan: Bool)
        /// Text imported from a file, added to the prompt.
        case document(text: String)
    }

    public let id = UUID()
    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public var image: ImageInput? {
        if case .image(let image, _) = kind { image } else { nil }
    }

    public var isScan: Bool {
        if case .image(_, let fromScan) = kind { fromScan } else { false }
    }

    public var documentText: String? {
        if case .document(let text) = kind { text } else { nil }
    }

    /// Decodes image data (e.g. from the photo picker), keeping its EXIF orientation.
    public static func image(data: Data, name: String, fromScan: Bool = false) -> ChatAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init)
        return ChatAttachment(name: name, kind: .image(ImageInput(cgImage, label: uniqueLabel(name), orientation: orientation), fromScan: fromScan))
    }

    /// A scanned page.
    public static func scan(_ page: CGImage, name: String) -> ChatAttachment {
        ChatAttachment(name: name, kind: .image(ImageInput(page, label: uniqueLabel(name)), fromScan: true))
    }

    /// Image tools find attachments by label across the whole conversation, so labels must
    /// not repeat between messages: "Scan 1" becomes e.g. "scan-1-3fa2".
    static func uniqueLabel(_ name: String) -> String {
        let base = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return "\(base)-\(UUID().uuidString.prefix(4).lowercased())"
    }

    public enum DocumentError: LocalizedError {
        case noText

        public var errorDescription: String? {
            "This file has no selectable text. Scan it with the camera instead."
        }
    }

    /// Reads a plain-text or PDF file. A scanned PDF has no text layer and is rejected.
    public static func document(url: URL) throws -> ChatAttachment {
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), let string = pdf.string else {
                throw CocoaError(.fileReadCorruptFile)
            }
            text = string
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentError.noText }
        return ChatAttachment(name: url.lastPathComponent, kind: .document(text: text))
    }
}
