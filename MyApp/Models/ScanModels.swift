import Foundation
import simd

// Upload bodies and results for the sticky-note scan (docs/architecture.md, "Sticky-note scan").
// The app records poses and frames; the server does all room geometry. Units are meters in the ARKit world
// frame (y up), the same frame the ARWorldMap uses.
//
// The upload types are `nonisolated` and `Sendable` so ScanClient can JSON-encode a multi-megabyte sweep off the
// main actor (the app defaults every type to the main actor).

/// A camera pose: `ARFrame.camera.transform` split into position and rotation quaternion.
nonisolated struct CameraPose: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    var qx: Double
    var qy: Double
    var qz: Double
    var qw: Double

    init(x: Double, y: Double, z: Double, qx: Double, qy: Double, qz: Double, qw: Double) {
        self.x = x; self.y = y; self.z = z
        self.qx = qx; self.qy = qy; self.qz = qz; self.qw = qw
    }

    /// From `frame.camera.transform`.
    init(transform m: simd_float4x4) {
        let q = simd_quatf(m)
        self.init(x: Double(m.columns.3.x), y: Double(m.columns.3.y), z: Double(m.columns.3.z),
                  qx: Double(q.imag.x), qy: Double(q.imag.y), qz: Double(q.imag.z), qw: Double(q.real))
    }
}

/// One perimeter-walk sample. `t` is seconds since the walk started.
nonisolated struct PoseSample: Codable, Hashable, Sendable {
    var t: Double
    var x: Double
    var y: Double
    var z: Double
    var qx: Double
    var qy: Double
    var qz: Double
    var qw: Double

    init(t: Double, pose: CameraPose) {
        self.t = t
        x = pose.x; y = pose.y; z = pose.z
        qx = pose.qx; qy = pose.qy; qz = pose.qz; qw = pose.qw
    }
}

/// Describes the JPEG pixels exactly as sent, in ARKit's native landscape orientation. If the image is resized,
/// scale all six values by the same factor.
nonisolated struct CameraIntrinsics: Codable, Hashable, Sendable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var width: Int
    var height: Int

    /// From `frame.camera.intrinsics` and `frame.camera.imageResolution`, optionally scaled.
    init(intrinsics k: simd_float3x3, imageWidth: Double, imageHeight: Double, scale: Double = 1) {
        fx = Double(k.columns.0.x) * scale
        fy = Double(k.columns.1.y) * scale
        cx = Double(k.columns.2.x) * scale
        cy = Double(k.columns.2.y) * scale
        width = Int((imageWidth * scale).rounded())
        height = Int((imageHeight * scale).rounded())
    }

    init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.width = width; self.height = height
    }
}

nonisolated struct PerimeterUpload: Codable, Hashable, Sendable {
    static let minSamples = 100
    static let maxSamples = 3000
    var poses: [PoseSample]
    /// Which room this walk is. `z1` to `z6`; the first room is `z1`. A rescan of the same id replaces that room.
    var zone: String = "z1"
    /// What the host calls the room. Optional; the server numbers rooms otherwise.
    var name: String? = nil
}

/// One sweep frame. `jpeg` is base64 of the JPEG bytes. `t` is seconds since the sweep started.
nonisolated struct SweepFrame: Codable, Hashable, Sendable {
    static let maxJPEGBytes = 600 * 1024
    var index: Int
    var t: Double
    var pose: CameraPose
    var jpeg: String

    init(index: Int, t: Double, pose: CameraPose, jpegData: Data) {
        self.index = index
        self.t = t
        self.pose = pose
        jpeg = jpegData.base64EncodedString()
    }

    /// Decoded size of `jpeg`, for the client-side limit check.
    var jpegByteCount: Int { jpeg.utf8.count / 4 * 3 }
}

nonisolated struct SweepUpload: Codable, Hashable, Sendable {
    static let minFrames = 8
    static let maxFrames = 60
    /// The tile the host was told to stand on. A hint; the server uses the poses.
    var vantage: Tile
    var intrinsics: CameraIntrinsics
    var frames: [SweepFrame]
    /// The room this sweep belongs to; its perimeter must have been uploaded first.
    var zone: String = "z1"
}

struct PerimeterResult: Codable, Hashable {
    var ok: Bool
    var cols: Int
    var rows: Int
    var edgeTiles: Int
}

struct SweepResult: Codable, Hashable {
    var ok: Bool
    var notesFound: Int
    var stations: Int
    var warnings: [String]
}
