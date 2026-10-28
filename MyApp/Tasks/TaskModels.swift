import Foundation

/// The rules of one motion task. Feed it samples, read `progress` (0 to 1). Each task is built so
/// a phone lying idle on a table can never finish it: shake needs jolts, balance fights a drift,
/// dial needs a turn away from upright, steady needs the phone raised.
protocol MotionTaskModel {
    var progress: Double { get }
    mutating func step(_ sample: MotionSample)
}

extension MotionTaskModel {
    var isComplete: Bool { progress >= 1 }
}

// MARK: Shake

/// Shake the phone hard `needed` times.
struct ShakeModel: MotionTaskModel {
    static let needed = 10
    /// Hand acceleration, in g, that counts as one jolt. Waving the phone around stays below it.
    static let threshold = 1.3
    /// Shortest gap between two counted jolts, so one hard swing is not counted twice.
    static let gap = 0.15

    private(set) var count = 0
    private var sinceJolt = ShakeModel.gap

    var progress: Double { min(1, Double(count) / Double(Self.needed)) }

    mutating func step(_ s: MotionSample) {
        sinceJolt += s.dt
        guard s.userAcceleration > Self.threshold, sinceJolt >= Self.gap else { return }
        count += 1
        sinceJolt = 0
    }
}

// MARK: Balance (tilt)

/// Hold the phone flat and tilt a ball into a ring, then keep it there while a drift keeps
/// pushing it out. Unit disk: the wall is at radius 1.
struct BalanceModel: MotionTaskModel {
    static let holdSeconds = 4.0
    /// A little easier than before: a slightly wider ring (was 0.4), a gentler drift (was 1.2), more damping (was
    /// 1.5, so less overshoot) and a slower loss of progress (was 0.5). Cancelling the drift now takes about 0.37 g
    /// of tilt per unit of offset instead of 0.5, roughly a third less precision. The drift still pushes the ball
    /// out on its own, so an idle phone never finishes.
    static let zoneRadius = 0.45
    /// Ball acceleration per g of tilt, and the strength of the drift (both per second squared).
    private static let control = 6.0
    private static let drift = 1.0
    private static let damping = 1.8
    /// Progress drained per second while the ball is outside the ring, as a fraction of the fill rate.
    private static let lossRate = 0.4

    private(set) var x = 0.0
    private(set) var y = 0.0
    private var vx = 0.0
    private var vy = 0.0
    private var time = 0.0
    private var held = 0.0
    private let phase: Double

    init(phase: Double = .random(in: 0 ..< 2 * .pi)) {
        self.phase = phase
    }

    var inZone: Bool { hypot(x, y) < Self.zoneRadius }
    var progress: Double { min(1, held / Self.holdSeconds) }

    mutating func step(_ s: MotionSample) {
        let dt = min(s.dt, 0.05)
        time += dt
        let driftAngle = phase + 0.8 * time
        // Tilting the top edge up (gravity.y < 0) rolls the ball toward the bottom of the screen.
        let ax = Self.control * s.gravityX + Self.drift * cos(driftAngle) - Self.damping * vx
        let ay = -Self.control * s.gravityY + Self.drift * sin(driftAngle) - Self.damping * vy
        vx += ax * dt
        vy += ay * dt
        x += vx * dt
        y += vy * dt

        let r = hypot(x, y)
        if r > 1 {
            let nx = x / r, ny = y / r
            x = nx
            y = ny
            let outward = vx * nx + vy * ny
            if outward > 0 {
                vx -= outward * nx
                vy -= outward * ny
            }
        }
        held = inZone ? min(Self.holdSeconds, held + dt) : max(0, held - dt * Self.lossRate)
    }
}

// MARK: Dial (rotate)

/// Hold the phone upright and turn it like a dial to each target angle in turn.
struct DialModel: MotionTaskModel {
    static let tolerance = 12.0
    static let dwell = 0.7

    /// Target phone rotations in degrees, clockwise positive, as seen by the player.
    let targets: [Double]
    private(set) var index = 0
    private(set) var dwellTime = 0.0
    /// Current phone rotation in degrees, nil while the phone is not upright enough to read.
    private(set) var angle: Double?

    init(targets: [Double] = DialModel.randomTargets()) {
        self.targets = targets
    }

    static func randomTargets() -> [Double] {
        let side: Double = Bool.random() ? 1 : -1
        return [
            side * .random(in: 50 ... 100),
            -side * .random(in: 50 ... 100),
            side * .random(in: 60 ... 110),
        ]
    }

    var progress: Double {
        guard !targets.isEmpty else { return 1 }
        return min(1, (Double(index) + dwellTime / Self.dwell) / Double(targets.count))
    }

    mutating func step(_ s: MotionSample) {
        guard index < targets.count, abs(s.gravityZ) < 0.75 else {
            angle = nil
            dwellTime = 0
            return
        }
        // Gravity in the phone frame is (sin a, -cos a, 0) after turning the phone clockwise by a.
        let current = atan2(s.gravityX, -s.gravityY) * 180 / .pi
        angle = current
        var off = abs(current - targets[index])
        if off > 180 { off = 360 - off }
        guard off < Self.tolerance else {
            dwellTime = 0
            return
        }
        dwellTime += s.dt
        if dwellTime >= Self.dwell {
            index += 1
            dwellTime = 0
        }
    }
}

// MARK: Steady (hold)

/// Raise the phone upright and keep it still. A jolt or wobble drains the progress; lowering
/// the phone flat resets it.
struct SteadyModel: MotionTaskModel {
    static let holdSeconds = 5.0
    /// Hand tremor is well under both limits, a wave or a bump is well over.
    static let maxRotation = 0.45
    static let maxAcceleration = 0.07

    private(set) var upright = false
    private(set) var steady = false
    private var held = 0.0

    var progress: Double { min(1, held / Self.holdSeconds) }

    mutating func step(_ s: MotionSample) {
        upright = abs(s.gravityZ) < 0.6
        steady = s.rotationRate < Self.maxRotation && s.userAcceleration < Self.maxAcceleration
        if !upright {
            held = 0
        } else if steady {
            held = min(Self.holdSeconds, held + s.dt)
        } else {
            held = max(0, held - s.dt * 2)
        }
    }
}

// MARK: Hammer

/// Swing the phone down like a hammer to drive a nail. Each hard downward stroke is one hit; lifting the phone back
/// up does not count, so the player has to wind up and strike. A phone lying idle never hits.
struct HammerModel: MotionTaskModel {
    static let needed = 6
    /// Hand acceleration toward the ground, in g, that counts as a strike. A gentle wave stays well below it,
    /// a real downward swing of the wrist is well above.
    static let strikeThreshold = 1.0
    /// Shortest gap between two strikes, so one swing is not counted twice and the back-swing has to happen.
    static let gap = 0.4

    private(set) var hits = 0
    private var sinceHit = HammerModel.gap

    var progress: Double { min(1, Double(hits) / Double(Self.needed)) }

    mutating func step(_ s: MotionSample) {
        sinceHit += s.dt
        guard s.accelerationAlongGravity > Self.strikeThreshold, sinceHit >= Self.gap else { return }
        hits += 1
        sinceHit = 0
    }
}

// MARK: Pattern (gesture)

/// Hold the phone flat and tilt it to each shown direction in turn, back to level in between.
/// "Tilt toward an arrow" always means lowering the edge it points to, as if rolling a ball that way: arrow left
/// lowers the left edge, arrow right the right edge, arrow up the top edge, arrow down the bottom edge.
/// Tilting the wrong way is ignored, so the tolerance is generous.
struct PatternModel: MotionTaskModel {
    enum Direction: CaseIterable {
        case left, right, away, toward
    }

    /// Tilt past this (in g, about 24 degrees) to count, and come back under `level` to re-arm.
    static let tilt = 0.4
    static let level = 0.15
    static let length = 4

    let sequence: [Direction]
    private(set) var index = 0
    private(set) var flat = false
    private var armed = true

    init(sequence: [Direction] = PatternModel.randomSequence()) {
        self.sequence = sequence
    }

    /// No direction twice in a row.
    static func randomSequence() -> [Direction] {
        var result: [Direction] = []
        while result.count < length {
            let next = Direction.allCases.randomElement()!
            if next != result.last { result.append(next) }
        }
        return result
    }

    var progress: Double { min(1, Double(index) / Double(sequence.count)) }

    mutating func step(_ s: MotionSample) {
        flat = s.gravityZ < -0.6
        guard flat, index < sequence.count else { return }
        if abs(s.gravityX) < Self.level, abs(s.gravityY) < Self.level {
            armed = true
            return
        }
        guard armed, let direction = Self.direction(s) else { return }
        if direction == sequence[index] {
            index += 1
            armed = false
        }
    }

    /// The edge that is lower than the rest has more of gravity pointing along its axis: right edge down is
    /// gravity.x > 0, top edge down is gravity.y > 0. Both axes follow the same rule, so up and down match
    /// left and right. (Up and down used to be swapped: the top edge had to be raised for the up arrow.)
    static func direction(_ s: MotionSample) -> Direction? {
        if s.gravityX > tilt { return .right }
        if s.gravityX < -tilt { return .left }
        if s.gravityY > tilt { return .away }
        if s.gravityY < -tilt { return .toward }
        return nil
    }
}

extension PatternModel.Direction {
    var symbol: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .away: "arrow.up"
        case .toward: "arrow.down"
        }
    }
}

// MARK: Hunts (orbs, signal)

/// A direction relative to where the player was facing when the task began. Yaw is counter-clockwise seen from above
/// (turning left makes it grow), pitch is up positive, both in radians. Pitch is measured from the horizon.
struct HuntBearing: Equatable {
    var yaw: Double
    var pitch: Double

    static let ahead = HuntBearing(yaw: 0, pitch: 0)

    /// The angle in radians between two directions, 0 to pi.
    func angle(to other: HuntBearing) -> Double {
        let a = unit, b = other.unit
        let dot = a.x * b.x + a.y * b.y + a.z * b.z
        return acos(max(-1, min(1, dot)))
    }

    private var unit: (x: Double, y: Double, z: Double) {
        (cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }

    /// An angle brought into -pi to pi.
    static func wrapped(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }

    /// Targets in order. Each one is `minTurn` to `maxTurn` of yaw away from the one before (the first from straight
    /// ahead), on a random side, so the player has to turn for every one and a phone lying idle never reaches any.
    static func randomTargets(count: Int, minTurn: Double, maxTurn: Double) -> [HuntBearing] {
        var result: [HuntBearing] = []
        var yaw = 0.0
        for _ in 0 ..< count {
            let side: Double = Bool.random() ? 1 : -1
            yaw = wrapped(yaw + side * .random(in: minTurn ... maxTurn))
            result.append(HuntBearing(yaw: yaw, pitch: .random(in: -0.25 ... 0.45)))
        }
        return result
    }
}

/// Turns the phone's absolute look direction into a bearing relative to where the attempt started.
private struct HuntFacing {
    private var origin: Double?

    mutating func bearing(of s: MotionSample) -> HuntBearing {
        let start = origin ?? s.lookYaw
        origin = start
        return HuntBearing(yaw: HuntBearing.wrapped(s.lookYaw - start), pitch: s.lookPitch)
    }
}

/// Orb Hunt: glowing orbs appear around the room one at a time. Turn to each one, put the crosshair on it and hold.
/// Every orb is at least 70 degrees from the last, so it takes real turning, and an idle phone never finishes.
struct OrbHuntModel: MotionTaskModel {
    static let count = 3
    /// How close the crosshair has to be, in radians (about 10 degrees), and how long it has to stay there.
    static let tolerance = 0.18
    static let dwell = 0.6
    static let minTurn = 70.0 * .pi / 180
    static let maxTurn = 140.0 * .pi / 180

    let targets: [HuntBearing]
    private(set) var index = 0
    private(set) var dwellTime = 0.0
    private(set) var aim = HuntBearing.ahead
    private var facing = HuntFacing()

    init(targets: [HuntBearing] = HuntBearing.randomTargets(count: OrbHuntModel.count, minTurn: OrbHuntModel.minTurn, maxTurn: OrbHuntModel.maxTurn)) {
        self.targets = targets
    }

    /// The orb to find now, nil once all are found.
    var current: HuntBearing? { index < targets.count ? targets[index] : nil }
    var onTarget: Bool { current.map { aim.angle(to: $0) < Self.tolerance } ?? false }

    var progress: Double {
        guard !targets.isEmpty else { return 1 }
        return min(1, (Double(index) + dwellTime / Self.dwell) / Double(targets.count))
    }

    mutating func step(_ s: MotionSample) {
        aim = facing.bearing(of: s)
        guard index < targets.count else { return }
        guard onTarget else {
            dwellTime = 0
            return
        }
        dwellTime += min(s.dt, 0.1)
        if dwellTime >= Self.dwell {
            index += 1
            dwellTime = 0
        }
    }
}

/// Signal Hunt: a hidden signal sits somewhere in the room. The signal gets stronger the closer the phone points to
/// it, so sweep around, find the strongest spot and hold the phone there until it locks. Two signals, far apart.
struct SignalModel: MotionTaskModel {
    static let count = 2
    /// Lock window in radians (about 12 degrees) and the time to hold it. The signal is felt within 90 degrees.
    static let lockRadius = 0.21
    static let dwell = 1.0
    static let reach = Double.pi / 2
    static let minTurn = 80.0 * .pi / 180
    static let maxTurn = 150.0 * .pi / 180

    let targets: [HuntBearing]
    private(set) var index = 0
    private(set) var dwellTime = 0.0
    private(set) var aim = HuntBearing.ahead
    private var facing = HuntFacing()

    init(targets: [HuntBearing] = HuntBearing.randomTargets(count: SignalModel.count, minTurn: SignalModel.minTurn, maxTurn: SignalModel.maxTurn)) {
        self.targets = targets
    }

    var current: HuntBearing? { index < targets.count ? targets[index] : nil }
    var locked: Bool { current.map { aim.angle(to: $0) < Self.lockRadius } ?? false }

    /// 0 (not heard) to 1 (dead on).
    var strength: Double {
        guard let current else { return 1 }
        return max(0, 1 - aim.angle(to: current) / Self.reach)
    }

    var progress: Double {
        guard !targets.isEmpty else { return 1 }
        return min(1, (Double(index) + dwellTime / Self.dwell) / Double(targets.count))
    }

    mutating func step(_ s: MotionSample) {
        aim = facing.bearing(of: s)
        guard index < targets.count else { return }
        guard locked else {
            dwellTime = 0
            return
        }
        dwellTime += min(s.dt, 0.1)
        if dwellTime >= Self.dwell {
            index += 1
            dwellTime = 0
        }
    }
}
