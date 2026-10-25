import Foundation

// Checks for the pure motion-task rules (MyApp/Tasks/TaskModels.swift): the tilt-pattern directions, how forgiving
// the ball (tilt) task is, the steady (hold) task's original limits, and the hammer. They prove the rules, not how
// a hand feels. The feel needs a phone.

var checks = 0
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok() { return }
    failures += 1
    print("FAIL: \(name) \(detail())")
}

/// A reading. Flat and face up is gravity (0, 0, -1); upright is (0, -1, 0).
func sample(gx: Double = 0, gy: Double = 0, gz: Double = -1, rot: Double = 0, acc: Double = 0,
            down: Double = 0, dt: Double = 1.0 / 60) -> MotionSample {
    MotionSample(gravityX: gx, gravityY: gy, gravityZ: gz, userAcceleration: acc, rotationRate: rot, dt: dt,
                 accelerationAlongGravity: down)
}

// MARK: Tilt pattern: the arrow points to the edge that goes DOWN, on both axes

do {
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

    var model = PatternModel(sequence: [.away, .toward])
    model.step(sample(gy: 0.5, gz: -0.8))
    check(model.index == 1, "first move counted")
    model.step(sample(gy: -0.5, gz: -0.8))
    check(model.index == 1, "the next move needs the phone leveled first")
    model.step(sample(gz: -1))
    model.step(sample(gy: -0.5, gz: -0.8))
    check(model.index == 2 && model.isComplete, "after leveling, the next move counts and the task completes")
}

// MARK: Steady (hold): slightly longer and stricter

func run(_ model: inout SteadyModel, seconds: Double, rot: Double, acc: Double, gz: Double = 0) {
    for _ in 0 ..< Int(seconds * 60) { model.step(sample(gy: -1, gz: gz, rot: rot, acc: acc)) }
}

do {
    var short = SteadyModel()
    run(&short, seconds: 4.1, rot: 0.05, acc: 0.01)
    check(!short.isComplete, "four seconds no longer completes the hold")
    var rotation = SteadyModel()
    run(&rotation, seconds: 6, rot: 0.47, acc: 0.01)
    check(!rotation.isComplete, "rotation near the old limit now interrupts the hold")
    var acceleration = SteadyModel()
    run(&acceleration, seconds: 6, rot: 0.05, acc: 0.075)
    check(!acceleration.isComplete, "acceleration near the old limit now interrupts the hold")
    var still = SteadyModel()
    run(&still, seconds: SteadyModel.holdSeconds + 0.2, rot: 0.05, acc: 0.01)
    check(still.isComplete && still.steady, "a still phone completes the hold")
    var shaky = SteadyModel()
    run(&shaky, seconds: 10, rot: 0.6, acc: 0.10)
    check(!shaky.isComplete, "a moderate wobble does not complete the hold")
    var wave = SteadyModel()
    run(&wave, seconds: 10, rot: 1.5, acc: 0.05)
    check(!wave.isComplete && wave.progress == 0, "waving the phone never completes it")
    var flat = SteadyModel()
    run(&flat, seconds: 10, rot: 0, acc: 0, gz: -1)
    check(!flat.upright && flat.progress == 0, "a phone lying flat never completes it")
}

// MARK: Balance (the ball task): easier, still not free

/// Plays the ball task with a simple player: tilt toward the ring's center, in proportion to how far off it is.
/// Returns whether the task was completed at any point, which is what the real task counts (it ends on completion).
func balanceRun(drift phase: Double, seconds: Double, skill: Double) -> Bool {
    var model = BalanceModel(phase: phase)
    for _ in 0 ..< Int(seconds * 60) {
        // To move the ball toward the center, lower the edge on the center's side. The ball rolls toward the lowered
        // edge: +x for gravityX > 0, and up the screen (negative y) for gravityY > 0.
        let gx = max(-0.5, min(0.5, -model.x * skill))
        let gy = max(-0.5, min(0.5, model.y * skill))
        model.step(sample(gx: gx, gy: gy, gz: -0.9))
        if model.isComplete { return true }
    }
    return false
}

do {
    check(BalanceModel.zoneRadius > 0.4 && BalanceModel.zoneRadius <= 0.5, "the ring is a little wider than the old 0.4", "\(BalanceModel.zoneRadius)")

    // The ball rolls toward the lowered edge (unchanged).
    var up = BalanceModel(phase: 0)
    for _ in 0 ..< 12 { up.step(sample(gy: 0.4, gz: -0.9)) }
    check(up.y < 0, "top edge down rolls the ball up the screen", "\(up.y)")
    var down = BalanceModel(phase: 0)
    for _ in 0 ..< 12 { down.step(sample(gy: -0.4, gz: -0.9)) }
    check(down.y > 0, "top edge up rolls the ball down the screen", "\(down.y)")
    var right = BalanceModel(phase: .pi / 2)
    for _ in 0 ..< 12 { right.step(sample(gx: 0.4, gz: -0.9)) }
    check(right.x > 0, "right edge down rolls the ball right", "\(right.x)")

    // An attentive player can finish it, over many different drift directions.
    var finished = 0
    let phases = stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 4).map { $0 }
    for phase in phases where balanceRun(drift: phase, seconds: 10, skill: 3.0) { finished += 1 }
    check(finished == phases.count, "a player correcting toward the center finishes from every drift direction", "\(finished) of \(phases.count)")

    // An idle phone never finishes: the drift pushes the ball out of the ring and the lost progress is never regained.
    var idleFinished = 0
    for phase in phases {
        var model = BalanceModel(phase: phase)
        for _ in 0 ..< 60 * 30 { model.step(sample(gz: -1)) }
        if model.isComplete { idleFinished += 1 }
    }
    check(idleFinished == 0, "an idle phone never finishes the ball task", "\(idleFinished) of \(phases.count) finished")

    // Easier, not free: barely correcting never finishes (checked offline: the correction needed to hold the ring
    // is about 0.37 now, 0.5 before, so 0.2 is well short), while a middling effort now does, which the old
    // settings did not allow.
    var lazyFinished = 0
    for phase in phases where balanceRun(drift: phase, seconds: 10, skill: 0.2) { lazyFinished += 1 }
    check(lazyFinished == 0, "barely correcting never finishes", "\(lazyFinished) of \(phases.count) finished")
    var middlingFinished = 0
    for phase in phases where balanceRun(drift: phase, seconds: 10, skill: 0.45) { middlingFinished += 1 }
    check(middlingFinished >= phases.count - 1, "a middling effort finishes", "\(middlingFinished) of \(phases.count) finished")
}

// MARK: Hammer: downward strokes count, nothing else does

func swing(_ model: inout HammerModel, down: Double, frames: Int = 6) {
    for _ in 0 ..< frames { model.step(sample(gy: -1, gz: 0, down: down)) }
}
func rest(_ model: inout HammerModel, seconds: Double) {
    for _ in 0 ..< Int(seconds * 60) { model.step(sample(gy: -1, gz: 0)) }
}

do {
    var model = HammerModel()
    swing(&model, down: 1.8)
    check(model.hits == 1, "a hard downward stroke is one hit", "\(model.hits)")
    swing(&model, down: 1.8)
    check(model.hits == 1, "the same swing is not counted twice", "\(model.hits)")
    rest(&model, seconds: 0.5)
    swing(&model, down: 1.8)
    check(model.hits == 2, "after the gap, the next stroke counts", "\(model.hits)")

    var lift = HammerModel()
    swing(&lift, down: -2.0)
    check(lift.hits == 0, "lifting the phone (upward acceleration) is not a hit")

    var gentle = HammerModel()
    swing(&gentle, down: 0.5)
    check(gentle.hits == 0, "a gentle wave is not a hit")

    var idle = HammerModel()
    rest(&idle, seconds: 30)
    check(idle.hits == 0 && idle.progress == 0, "an idle phone never hits")

    var full = HammerModel()
    for _ in 0 ..< HammerModel.needed {
        swing(&full, down: 1.8)
        rest(&full, seconds: 0.5)
    }
    check(full.isComplete && full.hits == HammerModel.needed, "\(HammerModel.needed) strokes finish the task", "\(full.hits)")
    check(HammerModel.needed >= 4 && HammerModel.needed <= 8, "the nail takes a handful of hits, not one")
}

print(failures == 0 ? "OK: \(checks) task checks passed" : "FAILED: \(failures) of \(checks) task checks")
exit(failures == 0 ? 0 : 1)
