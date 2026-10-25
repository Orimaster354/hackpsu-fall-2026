import Foundation

/// What the running task shows the 3D scene. The task views write it, `TaskARBackdrop` reads it
/// every frame. Plain fields on purpose: nothing observes them, so 60 Hz writes cost nothing.
final class TaskTelemetry {
    enum State { case running, success, timedOut }

    var state = State.running
    /// 0 to 1, the same value as the progress bar.
    var progress = 0.0
    /// True while the player is doing the right thing (ball in the ring, phone steady, on target).
    var good = false
    /// Counts shake jolts; the prop jumps each time it changes.
    var joltCount = 0
    /// Ball position on the tray, in the tray's unit disk. x is to the player's right, y toward them.
    var ballX = 0.0
    var ballY = 0.0
    /// Phone rotation in degrees, clockwise positive, for the dial.
    var dialAngle = 0.0

    /// Back to the start of an attempt. The 3D scene keeps this same object, so a retry resets
    /// it in place.
    func reset() {
        self.state = .running
        progress = 0
        good = false
        joltCount = 0
        ballX = 0
        ballY = 0
        dialAngle = 0
    }
}
