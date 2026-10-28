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
    /// Counts hammer strikes; the 3D hammer swings each time it changes.
    var strikeCount = 0
    /// True while the camera is pointed at the 3D prop. The AR scene writes it every frame.
    var aimed = true
    /// Whether progress needs `aimed`. Set by the task screen when the task is played on the AR prop.
    var requiresAim = false
    /// The task screen sets this to ask the AR scene to put the prop back in front of the player once.
    var recenterRequested = false
    /// Whether the task should advance right now: always in manual mode, only while aimed in AR.
    var canAdvance: Bool { !requiresAim || aimed }
    /// Ball position on the tray, in the tray's unit disk. x is to the player's right, y toward them.
    var ballX = 0.0
    var ballY = 0.0
    /// Phone rotation in degrees, clockwise positive, for the dial.
    var dialAngle = 0.0
    /// The hunt tasks: the current target relative to where the attempt started (radians, yaw counter-clockwise from
    /// above, pitch up positive), which target it is, how far the hold has got (0 to 1), and for the signal how strong
    /// it is (0 to 1).
    var targetYaw = 0.0
    var targetPitch = 0.0
    var huntIndex = 0
    var huntDwell = 0.0
    var signalStrength = 0.0
    /// Counts attempts. A hunt measures targets from where the attempt began, so the scene re-anchors on a new one.
    var attempt = 0

    /// Back to the start of an attempt. The 3D scene keeps this same object, so a retry resets
    /// it in place.
    func reset() {
        self.state = .running
        progress = 0
        good = false
        joltCount = 0
        strikeCount = 0
        aimed = true
        recenterRequested = false
        ballX = 0
        ballY = 0
        dialAngle = 0
        targetYaw = 0
        targetPitch = 0
        huntIndex = 0
        huntDwell = 0
        signalStrength = 0
        attempt += 1
    }
}
