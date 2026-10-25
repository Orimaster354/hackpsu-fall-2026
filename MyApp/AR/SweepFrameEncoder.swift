import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// A sweep image ready to upload, plus exactly how it relates to the camera image it came from.
nonisolated struct EncodedSweepImage: Sendable {
    let jpeg: Data
    /// Pixels of the JPEG.
    let width: Int
    let height: Int
    /// JPEG pixels per `capturedImage` pixel along each axis. The intrinsics must be multiplied by these.
    let scaleX: Double
    let scaleY: Double
    let quality: Double
}

nonisolated enum SweepImageError: LocalizedError, Sendable {
    case unreadableBuffer
    case tooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableBuffer: "The camera image could not be read."
        case let .tooLarge(bytes): "A sweep frame stayed over 600 KiB even at the lowest allowed quality (\(bytes / 1024) KiB)."
        }
    }
}

/// Turns `ARFrame.capturedImage` into the JPEG the server expects (docs/ar-capture.md, "Sweep").
///
/// The image is NOT rotated or mirrored: ARKit's captured image is in the sensor's native landscape
/// orientation, and the pose and intrinsics describe that exact pixel grid. Rotating it would silently break
/// every ray the server casts. The quality drops before the size does, and the long edge never goes under 1280 px.
nonisolated enum SweepFrameEncoder {
    /// Same as `SweepFrame.maxJPEGBytes`; duplicated because that one is main-actor isolated.
    static let maxBytes = 600 * 1024
    static let minLongEdge = 1280
    static let qualities: [Double] = [0.7, 0.6, 0.5, 0.4]
    /// Tried only after every quality fails, at the lowest quality.
    static let downscales: [Double] = [0.85, 0.72, 0.6]

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func encode(_ buffer: CVPixelBuffer, maxBytes: Int = maxBytes,
                       minLongEdge: Int = minLongEdge) throws -> EncodedSweepImage {
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth > 0, sourceHeight > 0 else { throw SweepImageError.unreadableBuffer }

        // CIImage(cvPixelBuffer:) applies no orientation, so what is encoded is the sensor image as is.
        let source = CIImage(cvPixelBuffer: buffer)
        let attempts = qualities.map { (scale: 1.0, quality: $0) } + downscales.map { (scale: $0, quality: qualities.last ?? 0.4) }
        var smallest = Int.max

        for attempt in attempts {
            let width = Int((Double(sourceWidth) * attempt.scale).rounded())
            let height = Int((Double(sourceHeight) * attempt.scale).rounded())
            guard max(width, height) >= minLongEdge else { continue }

            var image = source
            if attempt.scale != 1 {
                // Separate factors keep the output exactly width x height; the caller scales intrinsics per axis.
                image = source
                    .transformed(by: CGAffineTransform(scaleX: Double(width) / Double(sourceWidth),
                                                        y: Double(height) / Double(sourceHeight)))
                    .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let option = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            guard let data = context.jpegRepresentation(of: image, colorSpace: sRGB, options: [option: attempt.quality])
            else { continue }
            smallest = min(smallest, data.count)
            if data.count <= maxBytes {
                return EncodedSweepImage(jpeg: data, width: width, height: height,
                                         scaleX: Double(width) / Double(sourceWidth),
                                         scaleY: Double(height) / Double(sourceHeight),
                                         quality: attempt.quality)
            }
        }
        throw SweepImageError.tooLarge(bytes: smallest == .max ? 0 : smallest)
    }

    /// What a decoder will see in these bytes. Used to prove the JPEG matches the intrinsics we send.
    struct Inspection: Equatable, Sendable {
        let width: Int
        let height: Int
        /// EXIF orientation tag, nil when absent. Anything other than nil or 1 would rotate the image on decode.
        let orientation: Int?

        var isUpright: Bool { orientation == nil || orientation == 1 }
    }

    static func inspect(_ jpeg: Data) -> Inspection? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        return Inspection(width: width, height: height, orientation: orientation)
    }
}
