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
    /// A small, upright copy of an image for previews. Nil for documents.
    public let thumbnail: CGImage?

    public init(name: String, kind: Kind, thumbnail: CGImage? = nil) {
        self.name = name
        self.kind = kind
        if let thumbnail {
            self.thumbnail = thumbnail
        } else if case .image(let image, _) = kind {
            self.thumbnail = Self.downscaled(image.cgImage)
        } else {
            self.thumbnail = nil
        }
    }

    /// What a sent message keeps of this attachment for display.
    public var preview: AttachmentPreview {
        AttachmentPreview(id: id, name: name, thumbnail: thumbnail, isScan: isScan)
    }

    /// Longest side of preview thumbnails, in pixels: sharp at 3x for a ~120pt tile.
    static let thumbnailSize = 360

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
        // The thumbnail applies the EXIF orientation, so previews are upright.
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
        ] as CFDictionary)
        return ChatAttachment(
            name: name,
            kind: .image(ImageInput(cgImage, label: uniqueLabel(name), orientation: orientation), fromScan: fromScan),
            thumbnail: thumbnail
        )
    }

    /// A scanned page.
    public static func scan(_ page: CGImage, name: String) -> ChatAttachment {
        ChatAttachment(name: name, kind: .image(ImageInput(page, label: uniqueLabel(name)), fromScan: true))
    }

    /// A copy whose longest side is at most `thumbnailSize` pixels.
    static func downscaled(_ image: CGImage) -> CGImage? {
        let scale = min(1, Double(thumbnailSize) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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

/// How a sent message shows one of its attachments.
public struct AttachmentPreview: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let name: String
    /// Nil for documents. Not encoded: ``ChatStore`` keeps thumbnails as image files.
    public var thumbnail: CGImage?
    public let isScan: Bool

    public init(id: UUID = UUID(), name: String, thumbnail: CGImage?, isScan: Bool) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
        self.isScan = isScan
    }

    private enum CodingKeys: String, CodingKey { case id, name, isScan }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isScan = try container.decode(Bool.self, forKey: .isScan)
        thumbnail = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isScan, forKey: .isScan)
    }
}
