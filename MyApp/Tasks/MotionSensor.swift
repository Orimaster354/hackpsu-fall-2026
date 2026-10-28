import Combine
import CoreMotion

/// One reading of the phone's motion, reduced to what the task rules need.
struct MotionSample {
    /// Gravity in the phone's frame, in g. Flat and face up is (0, 0, -1), upright is (0, -1, 0).
    var gravityX: Double
    var gravityY: Double
    var gravityZ: Double
    /// Acceleration from the player's hand with gravity removed, magnitude in g.
    var userAcceleration: Double
    /// How fast the phone is turning, magnitude in rad/s.
    var rotationRate: Double
    /// Seconds since the previous sample.
    var dt: Double
    /// The hand's acceleration along gravity, in g. Positive while the phone is being pushed or swung DOWN, negative
    /// while it is lifted. A hammer stroke is a strong positive spike. Defaults to 0 for samples that do not set it.
    var accelerationAlongGravity: Double = 0
    /// Which way the back camera faces, in radians, from the gravity-aligned reference frame. Yaw is counter-clockwise
    /// seen from above and its zero is arbitrary (the hunt tasks only use changes in it). Pitch is up positive from the
    /// horizon. Both default to 0 for samples that do not set them.
    var lookYaw: Double = 0
    var lookPitch: Double = 0
}

/// Publishes `MotionSample`s at 60 Hz while started. The task rules live in `TaskModels.swift`
/// and take plain samples, so they run (and are tested) without a device.
final class MotionSensor {
    let samples = PassthroughSubject<MotionSample, Never>()
    private let manager = CMMotionManager()
    private var lastTimestamp: TimeInterval?

    /// False on the simulator and on devices without a gyroscope.
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        lastTimestamp = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.publish(motion) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    deinit { manager.stopDeviceMotionUpdates() }

    private func publish(_ motion: CMDeviceMotion) {
        let dt = lastTimestamp.map { motion.timestamp - $0 } ?? 1.0 / 60
        lastTimestamp = motion.timestamp
        let a = motion.userAcceleration
        let r = motion.rotationRate
        let look = Self.lookDirection(of: motion)
        samples.send(MotionSample(
            gravityX: motion.gravity.x,
            gravityY: motion.gravity.y,
            gravityZ: motion.gravity.z,
            userAcceleration: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot(),
            rotationRate: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot(),
            dt: dt,
            // CoreMotion's gravity vector points toward the ground in the phone's frame, so this dot product is how hard
            // the hand is accelerating toward the ground.
            accelerationAlongGravity: a.x * motion.gravity.x + a.y * motion.gravity.y + a.z * motion.gravity.z,
            lookYaw: look.yaw,
            lookPitch: look.pitch
        ))
    }

    /// The back camera looks along the phone's -z axis. Core Motion's matrix relates the phone frame to the
    /// gravity-aligned reference frame (z up); which way round is checked against the measured gravity, so the answer
    /// does not depend on remembering the convention. Whichever reading makes "up" match gravity is the right one.
    static func lookDirection(of motion: CMDeviceMotion) -> (yaw: Double, pitch: Double) {
        let m = motion.attitude.rotationMatrix
        let up = (x: -motion.gravity.x, y: -motion.gravity.y, z: -motion.gravity.z)
        let byColumns = m.m13 * up.x + m.m23 * up.y + m.m33 * up.z
        let byRows = m.m31 * up.x + m.m32 * up.y + m.m33 * up.z
        let look = byColumns >= byRows ? (x: -m.m31, y: -m.m32, z: -m.m33) : (x: -m.m13, y: -m.m23, z: -m.m33)
        return (atan2(look.y, look.x), asin(max(-1, min(1, look.z))))
    }
}
