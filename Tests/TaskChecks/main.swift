import Foundation

// Checks for the pure motion-task rules (MyApp/Tasks/TaskModels.swift): tilt-pattern directions and how forgiving
// the steady (hold) task is. They prove the rules, not how a hand feels. The feel needs a phone.

var checks = 0
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok() { return }
    failures += 1
    print("FAIL: \(name) \(detail())")
}

/// A reading. Flat and face up is gravity (0, 0, -1); upright is (0, -1, 0).
func sample(gx: Double = 0, gy: Double = 0, gz: Double = -1, rot: Double = 0, acc: Double = 0, dt: Double = 1.0 / 60) -> MotionSample {
    MotionSample(gravityX: gx, gravityY: gy, gravityZ: gz, userAcceleration: acc, rotationRate: rot, dt: dt)
}

// MARK: Tilt pattern: the arrow points to the edge that goes DOWN, on both axes

do {
    // Lowering an edge puts gravity along that edge's axis: right edge down is +x, top edge down is +y.
    check(PatternModel.direction(sample(gx: 0.5, gz: -0.8)) == .right, "right edge down is the right arrow")
    check(PatternModel.direction(sample(gx: -0.5, gz: -0.8)) == .left, "left edge down is the left arrow")
    check(PatternModel.direction(sample(gy: 0.5, gz: -0.8)) == .away, "top edge down is the up arrow")
    check(PatternModel.direction(sample(gy: -0.5, gz: -0.8)) == .toward, "bottom edge down is the down arrow")
    check(PatternModel.Direction.away.symbol == "arrow.up" && PatternModel.Direction.toward.symbol == "arrow.down", "up arrow is away, down arrow is toward")

    func tilted(_ direction: PatternModel.Direction, with s: MotionSample) -> Bool {
        var model = PatternModel(sequence: [direction])
        model.step(s)
        return model.index == 1
    }
    check(tilted(.away, with: sample(gy: 0.5, gz: -0.8)), "the up arrow counts when the top edge goes down")
    check(!tilted(.away, with: sample(gy: -0.5, gz: -0.8)), "the up arrow ignores the old direction (top edge up)")
    check(tilted(.toward, with: sample(gy: -0.5, gz: -0.8)), "the down arrow counts when the bottom edge goes down")
    check(!tilted(.toward, with: sample(gy: 0.5, gz: -0.8)), "the down arrow ignores the old direction (top edge down)")
    check(tilted(.right, with: sample(gx: 0.5, gz: -0.8)) && tilted(.left, with: sample(gx: -0.5, gz: -0.8)), "left and right are unchanged")
    check(!tilted(.away, with: sample(gy: 0.5, gz: 0.0)), "nothing counts unless the phone is flat")

    // Level between moves: a second tilt only counts after coming back to level.
    var model = PatternModel(sequence: [.away, .toward])
    model.step(sample(gy: 0.5, gz: -0.8))
    check(model.index == 1, "first move counted")
    model.step(sample(gy: -0.5, gz: -0.8))
    check(model.index == 1, "the next move needs the phone leveled first")
    model.step(sample(gz: -1))
    model.step(sample(gy: -0.5, gz: -0.8))
    check(model.index == 2 && model.isComplete, "after leveling, the next move counts and the task completes")
}

// MARK: Steady (hold): a little more forgiving, still not easy

func run(_ model: inout SteadyModel, seconds: Double, rot: Double, acc: Double, gz: Double = 0) {
    for _ in 0 ..< Int(seconds * 60) { model.step(sample(gy: -1, gz: gz, rot: rot, acc: acc)) }
}

do {
    check(SteadyModel.maxRotation > 0.5 && SteadyModel.maxRotation <= 0.8, "rotation limit is a little above the old 0.5 rad/s", "\(SteadyModel.maxRotation)")
    check(SteadyModel.maxAcceleration > 0.08 && SteadyModel.maxAcceleration <= 0.13, "acceleration limit is a little above the old 0.08 g", "\(SteadyModel.maxAcceleration)")

    var easy = SteadyModel()
    run(&easy, seconds: SteadyModel.holdSeconds + 0.2, rot: 0.6, acc: 0.10)   // too shaky for the old limits, fine now
    check(easy.isComplete, "a moderately steady hand now completes the hold")

    var still = SteadyModel()
    run(&still, seconds: SteadyModel.holdSeconds + 0.2, rot: 0.05, acc: 0.01)
    check(still.isComplete && still.steady, "a still phone completes the hold")

    var wave = SteadyModel()
    run(&wave, seconds: 10, rot: 1.5, acc: 0.05)
    check(!wave.isComplete && wave.progress == 0, "waving the phone never completes it")

    var bump = SteadyModel()
    run(&bump, seconds: 10, rot: 0.1, acc: 0.4)
    check(!bump.isComplete && bump.progress == 0, "bumping the phone never completes it")

    var edge = SteadyModel()
    run(&edge, seconds: 10, rot: 0.8, acc: 0.12)   // just over both new limits
    check(!edge.isComplete, "a shake just over the limits does not complete it")

    var flat = SteadyModel()
    run(&flat, seconds: 10, rot: 0, acc: 0, gz: -1)
    check(!flat.upright && flat.progress == 0, "a phone lying flat never completes it")

    var drain = SteadyModel()
    run(&drain, seconds: 2, rot: 0.05, acc: 0.01)
    let full = drain.progress
    run(&drain, seconds: 0.5, rot: 1.5, acc: 0.3)
    let expected = (2.0 - 0.5 * SteadyModel.drainFactor) / SteadyModel.holdSeconds
    check(abs(drain.progress - expected) < 0.02 && drain.progress < full, "a wobble drains progress at the documented rate", "\(drain.progress) vs \(expected)")
    check(SteadyModel.drainFactor < 2 && SteadyModel.drainFactor >= 1, "draining is gentler than before (was 2) but still real")
}

// MARK: Balance (tilt): unchanged, documented. The ball rolls toward the edge that is lowered.

do {
    // y is screen-down positive: top edge down (+gravity.y) rolls the ball up the screen (negative y).
    var up = BalanceModel(phase: 0)
    for _ in 0 ..< 12 { up.step(sample(gy: 0.4, gz: -0.9)) }
    check(up.y < 0, "top edge down rolls the ball up the screen", "\(up.y)")
    var down = BalanceModel(phase: 0)
    for _ in 0 ..< 12 { down.step(sample(gy: -0.4, gz: -0.9)) }
    check(down.y > 0, "top edge up rolls the ball down the screen", "\(down.y)")
    var right = BalanceModel(phase: .pi / 2)
    for _ in 0 ..< 12 { right.step(sample(gx: 0.4, gz: -0.9)) }
    check(right.x > 0, "right edge down rolls the ball right", "\(right.x)")
}

print(failures == 0 ? "OK: \(checks) task checks passed" : "FAILED: \(failures) of \(checks) task checks")
exit(failures == 0 ? 0 : 1)
