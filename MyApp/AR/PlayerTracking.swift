import Foundation
import simd

nonisolated struct TrackedPose: Equatable {
    var position: SIMD3<Float>
    var quality: TrackingQuality
    /// Same monotonic timebase as ARFrame.timestamp.
    var timestamp: TimeInterval
}

protocol PlayerTracking: AnyObject {
    var pose: TrackedPose? { get }
    var quality: TrackingQuality { get }
}

extension PlayerTracking {
    static var maxPoseAge: TimeInterval { 0.5 }
    var reliablePosition: SIMD3<Float>? {
        reliablePosition(at: ProcessInfo.processInfo.systemUptime)
    }
    func reliablePosition(at uptime: TimeInterval) -> SIMD3<Float>? {
        guard quality.isReliable, let pose, pose.quality.isReliable,
              (0...Self.maxPoseAge).contains(uptime - pose.timestamp),
              pose.position.x.isFinite, pose.position.y.isFinite, pose.position.z.isFinite else { return nil }
        return pose.position
    }
}

nonisolated enum ARCaptureError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// No rasterization or placement: this adapter only converts a server-provided Grid
/// into tile coordinates. D can pass Grid fields here without importing ARKit into Net.
nonisolated struct ServerGridTracking: Equatable {
    let cols, rows: Int
    let tileSize, originX, originZ: Double
    let playable: Set<SIMD2<Int>>

    init(cols: Int, rows: Int, tileSize: Double, originX: Double, originZ: Double, playable: [SIMD2<Int>]) throws {
        guard cols > 0, rows > 0, tileSize == 1, originX.isFinite, originZ.isFinite,
              playable.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x < cols && $0.y < rows }) else {
            throw ARCaptureError.invalid("Invalid grid received from the server.")
        }
        self.cols = cols; self.rows = rows; self.tileSize = tileSize
        self.originX = originX; self.originZ = originZ; self.playable = Set(playable)
    }

    func tile(at position: SIMD3<Float>) -> SIMD2<Int>? {
        let x = floor((Double(position.x) - originX) / tileSize)
        let y = floor((Double(position.z) - originZ) / tileSize)
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(cols), y < Double(rows),
              x < Double(Int.max), y < Double(Int.max) else { return nil }
        let tile = SIMD2(Int(x), Int(y))
        return playable.contains(tile) ? tile : nil
    }

    func worldCenter(x: Int, y: Int, elevation: Float) -> SIMD3<Float>? {
        guard playable.contains(SIMD2(x, y)), elevation.isFinite else { return nil }
        let center = SIMD3(Float(originX + (Double(x) + 0.5) * tileSize), elevation,
                           Float(originZ + (Double(y) + 0.5) * tileSize))
        return center.x.isFinite && center.z.isFinite ? center : nil
    }
}
