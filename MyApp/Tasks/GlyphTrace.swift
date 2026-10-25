import Foundation
import simd

// The rules of the lights-out fix, kept free of ARKit and SwiftUI so they run in plain Swift checks
// (`Tests/TraceChecks`). The player draws a symbol in the air with the phone. Nothing here knows
// about tiles or a grid: a stroke is judged by its shape alone, so where it is drawn, how big it is
// and a little tilt do not matter.

/// A point on the drawing panel, in meters: x to the player's right, y up.
struct TracePoint: Equatable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// The symbols that restart the power. One is picked at random per attempt.
enum FixGlyph: String, CaseIterable, Identifiable {
    case bolt, circle, check

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bolt: "Lightning bolt"
        case .circle: "Circle"
        case .check: "Check mark"
        }
    }

    var symbol: String {
        switch self {
        case .bolt: "bolt.fill"
        case .circle: "circle"
        case .check: "checkmark"
        }
    }

    /// The stroke to draw, in a unit square (x right, y up), as a polyline.
    var guide: [TracePoint] {
        switch self {
        case .bolt:
            return [TracePoint(0.72, 1), TracePoint(0.22, 0.5), TracePoint(0.64, 0.5), TracePoint(0.28, 0)]
        case .check:
            return [TracePoint(0.08, 0.5), TracePoint(0.36, 0.12), TracePoint(0.94, 0.94)]
        case .circle:
            // Clockwise from the top, a full turn.
            return (0 ... 48).map { index in
                let angle = Double(index) / 48 * 2 * .pi
                return TracePoint(0.5 + 0.5 * sin(angle), 0.5 + 0.5 * cos(angle))
            }
        }
    }
}

// MARK: Recognizing a stroke

/// A small template matcher in the style of the $1 unistroke recognizer: resample the stroke to a fixed
/// number of points, tilt it a few degrees either way, move and scale it onto a unit box, and measure the
/// average distance to each template. The score is 1 for a perfect match and falls toward 0.
enum GlyphRecognizer {
    static let sampleCount = 48
    /// The small tilts, in degrees, tried against every template.
    static let tilts: [Double] = [-12, -8, -4, 0, 4, 8, 12]

    /// Best score for each glyph, from 0 to 1. Position, size and a little tilt do not matter.
    static func scores(for stroke: [TracePoint]) -> [FixGlyph: Double] {
        guard stroke.count >= 3, pathLength(stroke) > 0 else {
            return Dictionary(uniqueKeysWithValues: FixGlyph.allCases.map { ($0, 0) })
        }
        let resampled = resample(stroke, count: sampleCount)
        let candidates = tilts.map { normalized(rotated(resampled, degrees: $0)) }
        var result: [FixGlyph: Double] = [:]
        for glyph in FixGlyph.allCases {
            var best = Double.infinity
            for template in templates[glyph] ?? [] {
                for candidate in candidates {
                    best = min(best, distance(candidate, template))
                }
            }
            result[glyph] = max(0, 1 - best / 0.7071)
        }
        return result
    }

    /// Circles are drawn from any point and either way round, so they get a template for every 15 degrees of start, both ways.
    private static let templates: [FixGlyph: [[TracePoint]]] = {
        var all: [FixGlyph: [[TracePoint]]] = [:]
        for glyph in FixGlyph.allCases {
            let base = resample(glyph.guide, count: sampleCount)
            if glyph == .circle {
                let ring = Array(base.dropLast())
                var variants: [[TracePoint]] = []
                for offset in stride(from: 0, to: ring.count, by: 2) {
                    let turned = Array(ring[offset...] + ring[..<offset])
                    variants.append(normalized(resample(turned + [turned[0]], count: sampleCount)))
                    variants.append(normalized(resample(Array(turned.reversed()) + [turned.last ?? turned[0]], count: sampleCount)))
                }
                all[glyph] = variants
            } else {
                all[glyph] = [normalized(base)]
            }
        }
        return all
    }()

    // MARK: Geometry

    static func pathLength(_ points: [TracePoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1 ..< points.count {
            total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return total
    }

    /// `count` points spaced evenly along the path.
    static func resample(_ points: [TracePoint], count: Int) -> [TracePoint] {
        let length = pathLength(points)
        guard points.count > 1, length > 0, count > 1 else { return Array(repeating: points.first ?? TracePoint(0, 0), count: max(count, 1)) }
        let interval = length / Double(count - 1)
        var result = [points[0]]
        var carried = 0.0
        var previous = points[0]
        var index = 1
        while index < points.count {
            let current = points[index]
            let step = hypot(current.x - previous.x, current.y - previous.y)
            if carried + step >= interval, step > 0 {
                let fraction = (interval - carried) / step
                let point = TracePoint(previous.x + fraction * (current.x - previous.x), previous.y + fraction * (current.y - previous.y))
                result.append(point)
                previous = point
                carried = 0
            } else {
                carried += step
                previous = current
                index += 1
            }
        }
        while result.count < count { result.append(points[points.count - 1]) }
        return Array(result.prefix(count))
    }

    private static func rotated(_ points: [TracePoint], degrees: Double) -> [TracePoint] {
        guard degrees != 0 else { return points }
        let center = centroid(points)
        let angle = degrees * .pi / 180
        let (c, s) = (cos(angle), sin(angle))
        return points.map { point in
            let dx = point.x - center.x, dy = point.y - center.y
            return TracePoint(center.x + dx * c - dy * s, center.y + dx * s + dy * c)
        }
    }

    private static func centroid(_ points: [TracePoint]) -> TracePoint {
        let n = Double(points.count)
        return TracePoint(points.reduce(0) { $0 + $1.x } / n, points.reduce(0) { $0 + $1.y } / n)
    }

    /// Scaled onto a unit box (each way, so a tall or a wide drawing of the same shape still matches) and
    /// centered on the origin. A nearly straight stroke is scaled evenly, so a line never stretches into a diagonal.
    private static func normalized(_ points: [TracePoint]) -> [TracePoint] {
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        let big = max(width, height)
        guard big > 1e-9 else { return points }
        let flat = min(width, height) / big < 0.2
        let scaleX = flat ? 1 / big : 1 / max(width, 1e-9)
        let scaleY = flat ? 1 / big : 1 / max(height, 1e-9)
        let scaled = points.map { TracePoint($0.x * scaleX, $0.y * scaleY) }
        let center = centroid(scaled)
        return scaled.map { TracePoint($0.x - center.x, $0.y - center.y) }
    }

    private static func distance(_ a: [TracePoint], _ b: [TracePoint]) -> Double {
        var total = 0.0
        for index in 0 ..< min(a.count, b.count) {
            total += hypot(a[index].x - b[index].x, a[index].y - b[index].y)
        }
        return total / Double(min(a.count, b.count))
    }
}

// MARK: A drawing attempt

/// One stroke at a time: `begin`, a stream of `add`s, then `end` for the verdict.
struct GlyphTraceModel {
    struct Verdict: Equatable {
        enum Kind: Equatable { case accepted, tooShort, wrongShape }

        var kind: Kind
        /// The glyph the stroke looked most like, if it looked like any.
        var best: FixGlyph?
        /// How well the stroke matched the target, 0 to 1.
        var score: Double
    }

    /// The shortest stroke that counts, in meters of path, and the fewest points.
    static let minLength = 0.2
    static let minPoints = 16
    /// How good a match has to be.
    static let acceptScore = 0.8

    let target: FixGlyph
    private(set) var stroke: [TracePoint] = []
    private(set) var isDrawing = false
    private(set) var attempts = 0

    init(target: FixGlyph) {
        self.target = target
    }

    mutating func begin() {
        stroke = []
        isDrawing = true
    }

    mutating func add(_ point: TracePoint) {
        guard isDrawing else { return }
        stroke.append(point)
    }

    mutating func clear() {
        stroke = []
        isDrawing = false
    }

    /// Ends the stroke and judges it against the target. Counts as an attempt only if it was long enough.
    mutating func end() -> Verdict {
        isDrawing = false
        guard stroke.count >= Self.minPoints, GlyphRecognizer.pathLength(stroke) >= Self.minLength else {
            return Verdict(kind: .tooShort, best: nil, score: 0)
        }
        attempts += 1
        let scores = GlyphRecognizer.scores(for: stroke)
        let mine = scores[target] ?? 0
        let best = scores.max { $0.value < $1.value }
        if mine >= Self.acceptScore, best?.key == target {
            return Verdict(kind: .accepted, best: target, score: mine)
        }
        return Verdict(kind: .wrongShape, best: (best?.value ?? 0) >= 0.7 ? best?.key : nil, score: mine)
    }
}

// MARK: The panel in the room

/// An upright panel floating in front of the player, where the symbol is drawn. It is fixed in the room when
/// it is placed, and the phone's aim is a pointer on it: the cursor is where the camera's ray meets the
/// panel. Its axes are the player's right and up, so a drawing reads the same way the player sees it.
struct DrawingPlane: Equatable {
    var center: SIMD3<Float>
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    /// Points back toward the player.
    var normal: SIMD3<Float>

    /// The panel's size in meters.
    static let width = 0.62
    static let height = 0.46

    /// A panel `distance` meters ahead of `origin`, along `aim`. Nil when the phone points nearly straight
    /// up or down, where "upright" has no meaning.
    init?(origin: SIMD3<Float>, aim: SIMD3<Float>, distance: Float = 1) {
        let length = simd_length(aim)
        guard length > 1e-4 else { return nil }
        let forward = aim / length
        guard abs(forward.y) < 0.85 else { return nil }
        let n = -forward
        let r = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), n))
        normal = n
        right = r
        up = simd_cross(n, r)
        center = origin + forward * distance
    }

    func world(_ point: TracePoint) -> SIMD3<Float> {
        center + right * Float(point.x) + up * Float(point.y)
    }

    /// Where a ray from `origin` along `aim` meets the panel, or nil when it points away or runs almost along it.
    func cursor(origin: SIMD3<Float>, aim: SIMD3<Float>) -> TracePoint? {
        let length = simd_length(aim)
        guard length > 1e-4 else { return nil }
        let direction = aim / length
        let facing = simd_dot(direction, normal)
        guard facing < -0.2 else { return nil }
        let distance = simd_dot(center - origin, normal) / facing
        guard distance > 0 else { return nil }
        let hit = origin + direction * distance - center
        return TracePoint(Double(simd_dot(hit, right)), Double(simd_dot(hit, up)))
    }

    /// The panel's corners, in drawing coordinates.
    static var corners: [TracePoint] {
        [TracePoint(-width / 2, height / 2), TracePoint(width / 2, height / 2),
         TracePoint(width / 2, -height / 2), TracePoint(-width / 2, -height / 2)]
    }

    /// The guide glyph's corner-to-corner size on the panel, in meters.
    static let guideSize = 0.34

    /// Maps a point of a glyph's unit square to the panel.
    static func panelPoint(forGuide point: TracePoint) -> TracePoint {
        TracePoint((point.x - 0.5) * guideSize, (point.y - 0.5) * guideSize)
    }
}

/// Decides when the player has held the phone still enough for the panel to be pinned where it is. Until
/// then the panel follows the aim, so it ends up where the player is looking and not where the phone
/// happened to point when the screen opened.
struct AimSteadiness {
    /// How far the aim may wander, and for how long, to count as holding still.
    static let tolerance: Float = 3 * .pi / 180
    static let hold = 0.8

    private var anchor: SIMD3<Float>?
    private var since = 0.0

    /// Feed it the aim each frame with the time in seconds. True once the aim has stayed within the tolerance
    /// of where it was for `hold` seconds.
    mutating func update(aim: SIMD3<Float>, now: Double) -> Bool {
        let length = simd_length(aim)
        guard length > 1e-4 else {
            anchor = nil
            return false
        }
        let direction = aim / length
        if let anchor, acos(min(1, max(-1, simd_dot(direction, anchor)))) < Self.tolerance {
            return now - since >= Self.hold
        }
        anchor = direction
        since = now
        return false
    }

    mutating func reset() {
        anchor = nil
    }
}
