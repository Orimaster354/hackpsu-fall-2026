import Foundation
import simd

/// One camera pose sample in ARKit world space: meters, y up, gravity-aligned.
/// The origin and x/z axes are fixed by where and how the phone was facing when the session started.
nonisolated struct TrackedPose: Equatable {
    var position: SIMD3<Float>
    var quality: TrackingQuality
    /// `ProcessInfo.systemUptime` timebase (same as `ARFrame.timestamp`).
    var timestamp: TimeInterval
}

/// What the rest of the app may know about this phone's tracking.
/// Game code should depend on this protocol, not on ARKit.
protocol PlayerTracking: AnyObject {
    /// Latest raw sample, whatever its quality. For debug display only.
    var pose: TrackedPose? { get }
}

extension PlayerTracking {
    /// A pose older than this is treated as lost (e.g. session interrupted or paused).
    static var maxPoseAge: TimeInterval { 0.5 }

    /// Position in meters, or nil unless tracking is `.normal` and the sample is fresh.
    /// Use this, not `pose`, for any game decision.
    var reliablePosition: SIMD3<Float>? {
        guard let pose, pose.quality.isReliable,
              ProcessInfo.processInfo.systemUptime - pose.timestamp <= Self.maxPoseAge
        else { return nil }
        return pose.position
    }
}
