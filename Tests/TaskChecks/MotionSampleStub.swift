import Foundation

// Same shape as MotionSample in MyApp/Tasks/MotionSensor.swift. That file imports CoreMotion and drives the real
// sensor, so these checks use this stub and compile only the pure rules in MyApp/Tasks/TaskModels.swift.
struct MotionSample {
    var gravityX: Double
    var gravityY: Double
    var gravityZ: Double
    var userAcceleration: Double
    var rotationRate: Double
    var dt: Double
    var accelerationAlongGravity: Double = 0
}
