import CoreGraphics
import ImageIO

/// An image attached to a turn. The label lets on-device tools such as OCRTool find it.
public struct ImageInput: Sendable {
    public let cgImage: CGImage
    public let label: String
    public let orientation: CGImagePropertyOrientation?

    public init(_ cgImage: CGImage, label: String, orientation: CGImagePropertyOrientation? = nil) {
        self.cgImage = cgImage
        self.label = label
        self.orientation = orientation
    }
}
