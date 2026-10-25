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
        samples.send(MotionSample(
            gravityX: motion.gravity.x,
            gravityY: motion.gravity.y,
            gravityZ: motion.gravity.z,
            userAcceleration: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot(),
            rotationRate: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot(),
            dt: dt,
            // CoreMotion's gravity vector points toward the ground in the phone's frame, so this dot product is how hard
            // the hand is accelerating toward the ground.
            accelerationAlongGravity: a.x * motion.gravity.x + a.y * motion.gravity.y + a.z * motion.gravity.z
        ))
    }
}
