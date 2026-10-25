import Foundation
import simd

// Pure capture logic for the host's room scan (docs/ar-capture.md). No ARKit here so it runs in
// MyApp/AR/Tests/run_scan_checks.sh on a Mac. ARKit camera space: +x right, +y up, the camera looks
// along its own -z axis, and that frame is fixed to the sensor's native landscape orientation, which
// is also the orientation of `ARFrame.capturedImage`.

/// What the scan needs from one ARFrame, copied out so no ARFrame is retained.
struct FrameSample {
    var timestamp: TimeInterval
    var transform: simd_float4x4
    /// `frame.camera.intrinsics`, in pixels of `imageWidth` x `imageHeight`.
    var intrinsics: simd_float3x3
    /// `frame.camera.imageResolution`.
    var imageWidth: Double
    var imageHeight: Double
    /// `trackingState == .normal`. Poses from any other state are not trusted.
    var isTracking: Bool

    var position: SIMD3<Float> { SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) }
    var isFinite: Bool {
        (0..<4).allSatisfy { column in
            let c = transform[column]
            return c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite
        } && timestamp.isFinite
    }
}

enum CameraMath {
    /// World-space direction the camera looks along (camera space -z).
    static func forward(_ transform: simd_float4x4) -> SIMD3<Float> {
        let c = transform.columns.2
        return -SIMD3(c.x, c.y, c.z)
    }

    /// Heading on the floor plane in radians: 0 looking along world -z, growing toward +x. Nil when the
    /// camera looks mostly up or down, where a heading is not defined.
    static func heading(_ transform: simd_float4x4) -> Double? {
        let f = forward(transform)
        let length = simd_length(f)
        let horizontal = (f.x * f.x + f.z * f.z).squareRoot()
        guard length.isFinite, length > 0, horizontal / length > 0.3 else { return nil }
        return Double(atan2(f.x, -f.z))
    }

    /// Degrees above (+) or below (-) the horizon.
    static func pitchDegrees(_ transform: simd_float4x4) -> Double {
        let f = forward(transform)
        let length = simd_length(f)
        guard length > 0 else { return 0 }
        return Double(asin(max(-1, min(1, f.y / length)))) * 180 / .pi
    }

    /// Distance on the floor plane (x, z), the metric the server uses to close the perimeter loop.
    static func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
        Double(hypot(a.x - b.x, a.z - b.z))
    }
}

/// Net rotation about the vertical axis, unwrapped across the +-180 degree seam.
struct YawAccumulator {
    private(set) var total = 0.0
    private var last: Double?

    mutating func add(_ heading: Double) {
        if let last {
            var delta = heading - last
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            total += delta
        }
        last = heading
    }

    /// Forget the last heading so the next one starts a new baseline. Rotation that happened while the pose
    /// could not be trusted is not counted: no frames were taken for it, so it must not complete the circle.
    mutating func rebaseline() { last = nil }

    /// Net degrees turned in either direction. Jitter back and forth does not add up.
    var degrees: Double { abs(total) * 180 / .pi }
}

/// Turn speed over a short window, so a brief fast flick shows up as motion blur risk.
struct TurnRateMeter {
    private var points: [(time: Double, total: Double)] = []
    private let window = 0.4

    mutating func add(time: Double, total: Double) {
        points.append((time, total))
        points.removeAll { time - $0.time > window }
    }

    mutating func reset() { points.removeAll() }

    var degreesPerSecond: Double? {
        guard let first = points.first, let last = points.last, last.time - first.time >= 0.15 else { return nil }
        return abs(last.total - first.total) * 180 / .pi / (last.time - first.time)
    }
}

/// Step 1: camera poses at about 10 Hz while the host walks the room edge. No video.
struct PerimeterRecorder {
    static let sampleInterval = 0.1
    /// The server closes the loop when the first and last poses are within this horizontal distance.
    static let closeGap = 0.75
    /// A horizontal jump this large between two samples (10 m/s) means tracking relocalized or lost the floor.
    static let jumpDistance = 1.0

    private(set) var samples: [PoseSample] = []
    private(set) var pathLength = 0.0
    private(set) var jumps = 0
    private var startTimestamp: TimeInterval?
    private var firstPosition: SIMD3<Float>?
    private var lastPosition: SIMD3<Float>?

    var count: Int { samples.count }
    var elapsed: TimeInterval { samples.last?.t ?? 0 }
    var isFull: Bool { samples.count >= PerimeterUpload.maxSamples }

    /// Records the frame if tracking is healthy and 0.1 s has passed. Returns whether it was kept.
    @discardableResult
    mutating func add(_ frame: FrameSample, force: Bool = false) -> Bool {
        guard frame.isTracking, frame.isFinite, !isFull else { return false }
        let start = startTimestamp ?? frame.timestamp
        let t = frame.timestamp - start
        if let last = samples.last {
            let minimum = force ? 0.02 : Self.sampleInterval - 0.004
            guard t - last.t >= minimum else { return false }
        }
        startTimestamp = start
        let position = frame.position
        if let lastPosition {
            let step = CameraMath.horizontalDistance(position, lastPosition)
            pathLength += step
            if step > Self.jumpDistance { jumps += 1 }
        } else {
            firstPosition = position
        }
        lastPosition = position
        samples.append(PoseSample(t: t, pose: CameraPose(transform: frame.transform)))
        return true
    }

    /// Horizontal distance from where the walk started to `position`.
    func gapToStart(from position: SIMD3<Float>) -> Double? {
        firstPosition.map { CameraMath.horizontalDistance($0, position) }
    }

    /// What the server will check: first against last recorded pose.
    var endGap: Double? {
        guard let firstPosition, let lastPosition else { return nil }
        return CameraMath.horizontalDistance(firstPosition, lastPosition)
    }

    enum Problem: Equatable {
        case tooShort(samples: Int)
        case openLoop(gap: Double)
    }

    var problem: Problem? {
        if samples.count < PerimeterUpload.minSamples { return .tooShort(samples: samples.count) }
        if let gap = endGap, gap > Self.closeGap { return .openLoop(gap: gap) }
        return nil
    }
}

/// Step 3: decides which frames of the 360 degree turn to keep.
struct SweepSampler {
    /// About 2 frames per second.
    static let sampleInterval = 0.5
    static let maxFrames = SweepUpload.maxFrames
    static let minGoodFrames = 24
    /// Above this the image is likely motion blurred. Measured over the last 0.4 s.
    static let maxTurnRate = 30.0
    static let completeDegrees = 340.0
    static let timeLimit = 45.0

    enum Verdict: Equatable { case wait, take, skipTracking, skipTooFast }

    private(set) var elapsed: TimeInterval = 0
    private(set) var turnRate: Double?
    private var startTimestamp: TimeInterval?
    private var yaw = YawAccumulator()
    private var meter = TurnRateMeter()
    /// Starts at 0, so the first frame is taken one interval in, after the tap that started the sweep has settled.
    private var lastTaken = 0.0
    private(set) var taken = 0

    var yawDegrees: Double { yaw.degrees }
    var isComplete: Bool { yaw.degrees >= Self.completeDegrees || elapsed >= Self.timeLimit }
    var isFull: Bool { taken >= Self.maxFrames }
    /// Progress for the ring, 0...1.
    var progress: Double { min(1, yaw.degrees / 360) }

    /// Call for every frame. Heading only advances while tracking is healthy.
    mutating func observe(_ frame: FrameSample) {
        guard frame.isFinite else { return }
        let start = startTimestamp ?? frame.timestamp
        startTimestamp = start
        elapsed = frame.timestamp - start
        guard frame.isTracking, let heading = CameraMath.heading(frame.transform) else {
            yaw.rebaseline()
            meter.reset()
            turnRate = nil
            return
        }
        yaw.add(heading)
        meter.add(time: elapsed, total: yaw.total)
        turnRate = meter.degreesPerSecond
    }

    func verdict(for frame: FrameSample) -> Verdict {
        guard !isFull, elapsed - lastTaken >= Self.sampleInterval - 0.01 else { return .wait }
        guard frame.isTracking else { return .skipTracking }
        if let turnRate, turnRate > Self.maxTurnRate { return .skipTooFast }
        return .take
    }

    mutating func markTaken() {
        lastTaken = elapsed
        taken += 1
    }
}

enum Vantage {
    /// The playable tile closest to the grid center, ties broken by row then column.
    static func suggested(in grid: MapGrid) -> MapTile? {
        let cx = Double(grid.cols - 1) / 2
        let cy = Double(grid.rows - 1) / 2
        return grid.playable.min { a, b in
            let da = (Double(a.x) - cx) * (Double(a.x) - cx) + (Double(a.y) - cy) * (Double(a.y) - cy)
            let db = (Double(b.x) - cx) * (Double(b.x) - cx) + (Double(b.y) - cy) * (Double(b.y) - cy)
            return da != db ? da < db : a < b
        }
    }
}
