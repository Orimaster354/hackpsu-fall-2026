import Foundation
import simd

// Checks for MyApp/Tasks/GlyphTrace.swift. The recognizer is judged on strokes that look hand-drawn
// (wobble, jitter, tilt, any size and position, ends clipped or overshot) and on scribbles that must not
// count. Everything is seeded, so the numbers are the same on every run.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1 }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

var rng = SplitMix(state: 20261025)

func uniform(_ low: Double, _ high: Double) -> Double { Double.random(in: low ... high, using: &rng) }
func gaussian() -> Double {
    let u1 = max(1e-12, uniform(0, 1)), u2 = uniform(0, 1)
    return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}

func densified(_ guide: [TracePoint], count: Int = 240) -> [TracePoint] {
    GlyphRecognizer.resample(guide, count: count)
}

/// A hand-drawn version of a polyline given in a unit square, in meters.
func handDrawn(_ guide: [TracePoint], size: Double? = nil, sloppy: Double = 1) -> [TracePoint] {
    var points = densified(guide)
    let n = points.count
    // Slow wobble of the whole hand, and a little rounding at the corners.
    let (a1, a2) = (gaussian() * 0.04 * sloppy, gaussian() * 0.04 * sloppy)
    let (p1, p2) = (uniform(0, 1), uniform(0, 1))
    for index in 0 ..< n {
        let f = Double(index) / Double(n - 1)
        points[index].x += a1 * sin(2 * .pi * (f * 1.3 + p1))
        points[index].y += a2 * sin(2 * .pi * (f * 1.7 + p2))
    }
    let window = 4
    points = points.indices.map { index in
        let low = max(0, index - window), high = min(n - 1, index + window)
        let slice = points[low ... high]
        return TracePoint(slice.reduce(0) { $0 + $1.x } / Double(slice.count), slice.reduce(0) { $0 + $1.y } / Double(slice.count))
    }
    // The ends: clipped a little, or overshot.
    let clipHead = Int(uniform(0, 0.04) * Double(n)), clipTail = Int(uniform(0, 0.04) * Double(n))
    points = Array(points[clipHead ..< (n - clipTail)])
    if uniform(0, 1) < 0.3, points.count > 2 {
        let last = points[points.count - 1], before = points[points.count - 2]
        points.append(TracePoint(last.x + (last.x - before.x) * 6, last.y + (last.y - before.y) * 6))
    }
    // Tremor.
    points = points.map { TracePoint($0.x + gaussian() * 0.011 * sloppy, $0.y + gaussian() * 0.011 * sloppy) }
    // Size, proportions, tilt, and where in front of the player it is drawn.
    let scale = size ?? uniform(0.18, 0.5)
    let aspect = uniform(0.75, 1.3)
    let tilt = uniform(-9, 9) * .pi / 180
    let (dx, dy) = (uniform(-0.2, 0.2), uniform(-0.15, 0.15))
    return points.map { point in
        let x = (point.x - 0.5) * scale * aspect, y = (point.y - 0.5) * scale
        return TracePoint(x * cos(tilt) - y * sin(tilt) + dx, x * sin(tilt) + y * cos(tilt) + dy)
    }
}

/// What the phone would hand over: points no closer than 4 mm.
func thinned(_ points: [TracePoint]) -> [TracePoint] {
    var result: [TracePoint] = []
    for point in points {
        if let last = result.last, hypot(point.x - last.x, point.y - last.y) < 0.004 { continue }
        result.append(point)
    }
    return result
}

func circleGuide() -> [TracePoint] {
    let start = uniform(0, 2 * .pi), turns = uniform(0.92, 1.12)
    let direction: Double = Bool.random(using: &rng) ? 1 : -1
    return (0 ... 64).map { index in
        let angle = start + direction * Double(index) / 64 * 2 * .pi * turns
        return TracePoint(0.5 + 0.5 * sin(angle), 0.5 + 0.5 * cos(angle))
    }
}

func guide(for glyph: FixGlyph) -> [TracePoint] { glyph == .circle ? circleGuide() : glyph.guide }

func verdict(_ stroke: [TracePoint], target: FixGlyph) -> GlyphTraceModel.Verdict {
    var model = GlyphTraceModel(target: target)
    model.begin()
    for point in thinned(stroke) { model.add(point) }
    return model.end()
}

let trials = 600

// MARK: Accepting real drawings

print("-- hand-drawn symbols, \(trials) each")
for glyph in FixGlyph.allCases {
    var accepted = 0
    for _ in 0 ..< trials where verdict(handDrawn(guide(for: glyph)), target: glyph).kind == .accepted { accepted += 1 }
    let rate = Double(accepted) / Double(trials)
    print(String(format: "   %@ accepted %.1f%%", glyph.rawValue, rate * 100))
    check(rate >= 0.9, "\(glyph.rawValue): at least 90% of hand-drawn strokes are accepted")
}

print("-- a very sloppy hand (twice the wobble and tremor)")
for glyph in FixGlyph.allCases {
    var accepted = 0
    for _ in 0 ..< trials where verdict(handDrawn(guide(for: glyph), sloppy: 2), target: glyph).kind == .accepted { accepted += 1 }
    let rate = Double(accepted) / Double(trials)
    print(String(format: "   %@ accepted %.1f%%", glyph.rawValue, rate * 100))
    check(rate >= 0.6, "\(glyph.rawValue): a very sloppy hand still gets through at least 60% of the time")
}

// MARK: Rejecting everything else

func scribble(_ kind: Int) -> [TracePoint] {
    switch kind {
    case 0: // a straight line at any angle
        let angle = uniform(0, 2 * .pi)
        return handDrawn([TracePoint(0.5, 0.5), TracePoint(0.5 + cos(angle) * 0.5, 0.5 + sin(angle) * 0.5)])
    case 1: // part of a circle
        let start = uniform(0, 2 * .pi), span = uniform(0.2, 0.6) * 2 * .pi
        return handDrawn((0 ... 30).map { i in
            let a = start + Double(i) / 30 * span
            return TracePoint(0.5 + 0.5 * sin(a), 0.5 + 0.5 * cos(a))
        })
    case 2: // a sine wave
        let periods = uniform(1, 3)
        return handDrawn((0 ... 60).map { i in
            let x = Double(i) / 60
            return TracePoint(x, 0.5 + 0.3 * sin(2 * .pi * periods * x))
        })
    case 3: // a random walk
        var heading = uniform(0, 2 * .pi), point = TracePoint(0.5, 0.5)
        var points = [point]
        for _ in 0 ..< 60 {
            heading += gaussian() * 0.45
            point = TracePoint(point.x + cos(heading) * 0.03, point.y + sin(heading) * 0.03)
            points.append(point)
        }
        return handDrawn(points)
    default: // a zigzag of random corners
        let count = Int(uniform(7, 14))
        return handDrawn((0 ..< count).map { _ in TracePoint(uniform(0, 1), uniform(0, 1)) })
    }
}
let kinds = ["line", "arc", "wave", "walk", "scribble"]

print("-- strokes that are not any symbol, \(trials) each, against every target")
for (index, name) in kinds.enumerated() {
    var worst = 0.0
    for glyph in FixGlyph.allCases {
        var accepted = 0
        for _ in 0 ..< trials where verdict(scribble(index), target: glyph).kind == .accepted { accepted += 1 }
        worst = max(worst, Double(accepted) / Double(trials))
    }
    print(String(format: "   %@ worst accepted %.2f%%", name, worst * 100))
    check(worst <= 0.04, "\(name): at most 4% of these strokes are accepted by any target")
}

print("-- one symbol drawn when another is asked for, \(trials) each")
for target in FixGlyph.allCases {
    for drawn in FixGlyph.allCases where drawn != target {
        var accepted = 0
        for _ in 0 ..< trials where verdict(handDrawn(guide(for: drawn)), target: target).kind == .accepted { accepted += 1 }
        let rate = Double(accepted) / Double(trials)
        print(String(format: "   drew %@ for %@: accepted %.2f%%", drawn.rawValue, target.rawValue, rate * 100))
        check(rate <= 0.03, "drawing \(drawn.rawValue) when \(target.rawValue) is asked for is almost never accepted")
    }
}

// MARK: Edge cases

print("-- edge cases")
var empty = GlyphTraceModel(target: .bolt)
empty.begin()
check(empty.end().kind == .tooShort, "an empty stroke is too short")
check(empty.attempts == 0, "a stroke that is too short does not count as an attempt")

var tap = GlyphTraceModel(target: .circle)
tap.begin()
for index in 0 ..< 30 { tap.add(TracePoint(Double(index) * 0.0001, 0)) }
check(tap.end().kind == .tooShort, "a tiny stroke is too short even with many points")

var shaking = GlyphTraceModel(target: .bolt)
shaking.begin()
for _ in 0 ..< 300 { shaking.add(TracePoint(gaussian() * 0.004, gaussian() * 0.004)) }
check(shaking.end().kind != .accepted, "a hand held still, with only tremor, never counts")

var late = GlyphTraceModel(target: .check)
late.add(TracePoint(0, 0))
check(late.stroke.isEmpty, "points added with the pen up are ignored")

var perfect = GlyphTraceModel(target: .bolt)
perfect.begin()
for point in densified(FixGlyph.bolt.guide) { perfect.add(TracePoint(point.x * 0.4, point.y * 0.4)) }
let perfectVerdict = perfect.end()
check(perfectVerdict.kind == .accepted && perfectVerdict.score > 0.95, "a perfect bolt scores above 95%")

var wrong = GlyphTraceModel(target: .bolt)
wrong.begin()
for point in densified(FixGlyph.check.guide) { wrong.add(TracePoint(point.x * 0.4, point.y * 0.4)) }
let wrongVerdict = wrong.end()
check(wrongVerdict.kind == .wrongShape && wrongVerdict.best == .check, "a check mark asked as a bolt is wrong, and is recognized as a check mark")

print("-- position and size do not matter")
for glyph in FixGlyph.allCases {
    var accepted = 0
    for _ in 0 ..< 200 {
        let scale = uniform(0.15, 0.6)
        let (ox, oy) = (uniform(-3, 3), uniform(-3, 3))
        let points = densified(glyph.guide).map { TracePoint($0.x * scale + ox, $0.y * scale + oy) }
        if verdict(points, target: glyph).kind == .accepted { accepted += 1 }
    }
    check(accepted == 200, "\(glyph.rawValue): an exact drawing is accepted at any size and place")
}

// MARK: The panel in the room

print("-- the panel")
let eye = SIMD3<Float>(0, 1.3, 0)
let level = SIMD3<Float>(0, 0, -1)
let plane = DrawingPlane(origin: eye, aim: level)!
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool { simd_length(a - b) < tolerance }
check(near(plane.center, SIMD3(0, 1.3, -1)), "the panel is one meter ahead of the phone")
check(near(plane.right, SIMD3(1, 0, 0)) && near(plane.up, SIMD3(0, 1, 0)), "looking along -z, the panel's right is +x and up is +y")
let center = plane.cursor(origin: eye, aim: level)!
check(abs(center.x) < 1e-6 && abs(center.y) < 1e-6, "the cursor starts at the middle of the panel")

func rotatedAim(yawDegrees: Float, pitchDegrees: Float) -> SIMD3<Float> {
    let yaw = yawDegrees * .pi / 180, pitch = pitchDegrees * .pi / 180
    // Yaw to the right (clockwise seen from above), then pitch up.
    return SIMD3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
}
let right10 = plane.cursor(origin: eye, aim: rotatedAim(yawDegrees: 10, pitchDegrees: 0))!
check(abs(right10.x - tan(10 * .pi / 180)) < 0.01 && abs(right10.y) < 0.01, "turning 10 degrees right moves the cursor about 18 cm right")
let up10 = plane.cursor(origin: eye, aim: rotatedAim(yawDegrees: 0, pitchDegrees: 10))!
check(abs(up10.y - tan(10 * .pi / 180)) < 0.01 && abs(up10.x) < 0.01, "tilting 10 degrees up moves the cursor about 18 cm up")
check(plane.cursor(origin: eye, aim: SIMD3(0, 0, 1)) == nil, "aiming away from the panel gives no cursor")
check(plane.cursor(origin: eye, aim: SIMD3(1, 0, -0.05)) == nil, "aiming almost along the panel gives no cursor")

let down = SIMD3<Float>(0, -0.5, -0.866)
let tilted = DrawingPlane(origin: eye, aim: down)!
let tiltedCenter = tilted.cursor(origin: eye, aim: down)!
check(abs(tiltedCenter.x) < 1e-5 && abs(tiltedCenter.y) < 1e-5, "a panel placed where the phone looks down is centered on that aim")
check(tilted.up.y > 0.8, "the panel stays upright even when it is placed looking down")
check(abs(simd_dot(tilted.right, SIMD3<Float>(0, 1, 0))) < 1e-5, "the panel's right axis is level")
check(DrawingPlane(origin: eye, aim: SIMD3(0, -1, 0)) == nil && DrawingPlane(origin: eye, aim: SIMD3(0, 1, 0)) == nil, "no panel when the phone points straight down or up")
check(DrawingPlane(origin: eye, aim: .zero) == nil, "no panel without an aim direction")

let stepAside = plane.cursor(origin: eye + SIMD3(0.3, 0, 0), aim: level)!
check(abs(stepAside.x - 0.3) < 1e-5, "moving the phone sideways without turning moves the cursor with it")

print("-- holding still to place the panel")
var steadiness = AimSteadiness()
var firstPlaced: Int?
for frame in 0 ..< 90 {
    // 60 frames a second, with a degree of tremor.
    let tremor = Float(gaussian()) * 0.006
    if steadiness.update(aim: SIMD3(tremor, tremor, -1), now: Double(frame) / 60), firstPlaced == nil { firstPlaced = frame }
}
check(firstPlaced.map { (48 ... 52).contains($0) } ?? false, "placed after holding still for 0.8 s, tremor and all (frame \(firstPlaced.map(String.init) ?? "never"))")

var moving = AimSteadiness()
var everPlaced = false
for frame in 0 ..< 240 {
    let angle = Float(frame) * 0.02
    if moving.update(aim: SIMD3(sin(angle), 0, -cos(angle)), now: Double(frame) / 60) { everPlaced = true }
}
check(!everPlaced, "a phone that keeps turning never places the panel")

var restart = AimSteadiness()
for frame in 0 ..< 60 { _ = restart.update(aim: SIMD3(0, 0, -1), now: Double(frame) / 60) }
check(!restart.update(aim: SIMD3(0.5, 0, -1), now: 1.05), "turning away restarts the wait")
check(!restart.update(aim: SIMD3(0.5, 0, -1), now: 1.5), "and the wait counts from the new aim")
check(restart.update(aim: SIMD3(0.5, 0, -1), now: 1.9), "so it places 0.8 s after the turn")
var zero = AimSteadiness()
check(!zero.update(aim: .zero, now: 5), "no aim, no placement")

print(failures == 0 ? "OK: all trace checks passed" : "FAILED: \(failures) trace checks failed")
exit(failures == 0 ? 0 : 1)
