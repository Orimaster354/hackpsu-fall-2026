import ARKit
import RealityKit
import SwiftUI

/// Runs the drawing for the lights-out fix. In AR it reads where the phone is aimed, from the session's shared
/// view, and turns that into a cursor on an upright panel in front of the player. The panel follows the aim until
/// the phone has been held still for a moment, then it is pinned in the room. On screen it takes a finger instead.
/// Either way the points go to `GlyphTraceModel`, and this keeps what the screen shows. It never starts, pauses
/// or configures the AR session: it only reads the camera pose.
@MainActor @Observable
final class FixTraceController {
    enum Input { case aim, touch }

    private(set) var target: FixGlyph
    private(set) var plane: DrawingPlane?
    /// True once the panel is pinned in the room. Drawing starts then.
    private(set) var isPinned = false
    private(set) var cursor: TracePoint?
    private(set) var isPenDown = false
    /// False while ARKit has no good camera pose.
    private(set) var isTracking = true
    /// The stroke being drawn now, and the last finished one, which the screen fades out.
    private(set) var stroke: [TracePoint] = []
    private(set) var finished: [TracePoint] = []
    private(set) var finishedVerdict: GlyphTraceModel.Verdict?
    private(set) var finishedAt = Date.distantPast
    /// What the last stroke came to, in words, until the next one starts.
    private(set) var feedback: String?
    /// Counters, so the screen can play a haptic each time one of these happens.
    private(set) var strokesStarted = 0
    private(set) var verdicts = 0
    private(set) var pins = 0

    var input: Input
    @ObservationIgnored weak var arView: ARView?

    @ObservationIgnored private var model: GlyphTraceModel
    @ObservationIgnored private var steadiness = AimSteadiness()
    @ObservationIgnored private var lastPoint: TracePoint?
    /// Points closer than this to the last one are dropped, and the cursor is smoothed so tremor does not show.
    private static let spacing = 0.004
    private static let smoothing = 0.55

    init(input: Input, target: FixGlyph = FixGlyph.allCases.randomElement() ?? .bolt) {
        self.input = input
        self.target = target
        model = GlyphTraceModel(target: target)
    }

    /// True when the last stroke matched.
    var isAccepted: Bool { finishedVerdict?.kind == .accepted }

    // MARK: Words

    /// What to tell the player right now.
    var prompt: String {
        if isPenDown { return "Drawing. Let go when you are done." }
        if let feedback { return feedback }
        switch input {
        case .touch:
            return "Draw the symbol on the panel with your finger."
        case .aim:
            if !isTracking { return "Move the phone slowly so it can see the room." }
            if plane == nil { return "Hold the phone up and look straight ahead." }
            if !isPinned { return "Hold steady to place the panel." }
            if cursor == nil { return "Aim at the glowing panel." }
            return "Hold DRAW, then sweep your aim along the symbol."
        }
    }

    // MARK: Every frame (AR)

    /// Reads the camera and, while the pen is down, extends the stroke. Called about 60 times a second.
    func tick() {
        guard input == .aim else { return }
        guard let arView, let frame = arView.session.currentFrame else {
            lostTracking()
            return
        }
        guard frame.camera.trackingState == .normal else {
            lostTracking()
            return
        }
        isTracking = true
        let transform = frame.camera.transform
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let aim = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)

        if !isPinned {
            // The panel follows the aim until the phone is held still, then it stays where it is.
            plane = DrawingPlane(origin: origin, aim: aim)
            if plane == nil {
                steadiness.reset()
            } else if steadiness.update(aim: aim, now: frame.timestamp) {
                isPinned = true
                pins += 1
            }
        }
        guard let plane else {
            cursor = nil
            return
        }
        cursor = plane.cursor(origin: origin, aim: aim)
        if isPenDown, let cursor { extend(with: cursor, smoothed: true) }
    }

    /// Lets the panel follow the aim again, to be placed where the player is looking now.
    func recenter() {
        cancelStroke()
        isPinned = false
        plane = nil
        cursor = nil
        steadiness.reset()
    }

    // MARK: The pen

    func penDown() {
        guard !isPenDown, input == .touch || isPinned else { return }
        isPenDown = true
        feedback = nil
        lastPoint = nil
        model.begin()
        stroke = []
        strokesStarted += 1
    }

    func penUp() {
        guard isPenDown else { return }
        isPenDown = false
        let drawn = model.stroke
        let verdict = model.end()
        finished = drawn
        finishedVerdict = verdict
        finishedAt = Date()
        verdicts += 1
        clearStroke()
        switch verdict.kind {
        case .accepted:
            feedback = "That's it. Restarting the power."
        case .tooShort:
            feedback = "Too short. Draw the whole \(target.title.lowercased())."
        case .wrongShape:
            if let best = verdict.best, best != target {
                feedback = "That looked like a \(best.title.lowercased()). Draw the \(target.title.lowercased())."
            } else {
                feedback = "Not quite. Draw the \(target.title.lowercased()) again."
            }
        }
    }

    /// Lets go without a verdict, such as when the screen closes mid-stroke.
    func cancelStroke() {
        isPenDown = false
        clearStroke()
    }

    // MARK: A finger (on screen)

    func touchDown(at point: TracePoint) {
        penDown()
        extend(with: point, smoothed: false)
    }

    func touchMove(to point: TracePoint) {
        guard isPenDown else { return }
        extend(with: point, smoothed: false)
    }

    // MARK: A new try

    /// A fresh symbol for another go, such as after the clock ran out.
    func retry() {
        target = FixGlyph.allCases.filter { $0 != target }.randomElement() ?? target
        model = GlyphTraceModel(target: target)
        finished = []
        finishedVerdict = nil
        feedback = nil
        cancelStroke()
    }

    // MARK: Inside

    private func lostTracking() {
        isTracking = false
        cursor = nil
        steadiness.reset()
        cancelStroke()
    }

    private func clearStroke() {
        model.clear()
        stroke = []
        lastPoint = nil
    }

    private func extend(with point: TracePoint, smoothed: Bool) {
        var next = point
        if smoothed, let lastPoint {
            next = TracePoint(
                lastPoint.x + (point.x - lastPoint.x) * Self.smoothing,
                lastPoint.y + (point.y - lastPoint.y) * Self.smoothing
            )
        }
        if let lastPoint, hypot(next.x - lastPoint.x, next.y - lastPoint.y) < Self.spacing { return }
        lastPoint = next
        model.add(next)
        stroke = model.stroke
    }
}
