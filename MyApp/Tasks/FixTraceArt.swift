import SwiftUI

/// Draws the lights-out drawing panel: a holo frame, the symbol to draw as a faint guide, and the player's
/// stroke as a trail of light. The same drawing serves the AR view, where `map` projects a point of the panel
/// into the camera, and the on-screen fallback, where `map` is a flat rectangle. Nothing here is a grid:
/// the guide is only a hint, and the stroke is judged by its shape (see `GlyphRecognizer`).
struct FixTraceArt {
    /// Where a point on the panel lands on screen, or nil when it is out of sight.
    var map: (TracePoint) -> CGPoint?
    var target: FixGlyph
    /// The stroke being drawn now.
    var stroke: [TracePoint] = []
    /// The last finished stroke, which fades out and keeps the color of its verdict.
    var finished: [TracePoint] = []
    var finishedColor: Color = Theme.Palette.danger
    var finishedOpacity: Double = 0
    var tint: Color = Theme.Palette.neon
    /// 0 to 1, a pulse on the frame, for the moment the power comes back.
    var glow: Double = 0
    /// Seconds, for the guide's moving dashes.
    var time: Double = 0

    func draw(_ context: inout GraphicsContext) {
        drawFrame(&context)
        drawGuide(&context)
        if finishedOpacity > 0.01 { drawTrail(&context, finished, color: finishedColor, opacity: finishedOpacity) }
        drawTrail(&context, stroke, color: tint, opacity: 1)
    }

    // MARK: Frame

    private func drawFrame(_ context: inout GraphicsContext) {
        let corners = DrawingPlane.corners.map(map)
        guard corners.allSatisfy({ $0 != nil }) else { return }
        let points = corners.compactMap { $0 }

        var quad = Path()
        quad.move(to: points[0])
        for point in points.dropFirst() { quad.addLine(to: point) }
        quad.closeSubpath()
        context.fill(quad, with: .color(tint.opacity(0.06 + 0.12 * glow)))
        context.stroke(quad, with: .color(tint.opacity(0.35 + 0.4 * glow)), lineWidth: 1.2)

        // Brackets at the corners, each a short piece of the two edges that meet there.
        var brackets = Path()
        for index in 0 ..< 4 {
            let corner = points[index]
            let next = points[(index + 1) % 4], previous = points[(index + 3) % 4]
            for neighbor in [next, previous] {
                brackets.move(to: corner)
                brackets.addLine(to: CGPoint(x: corner.x + (neighbor.x - corner.x) * 0.16, y: corner.y + (neighbor.y - corner.y) * 0.16))
            }
        }
        context.stroke(brackets, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        context.stroke(brackets, with: .color(tint), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
    }

    // MARK: Guide

    private func drawGuide(_ context: inout GraphicsContext) {
        let guide = target.guide.map { map(DrawingPlane.panelPoint(forGuide: $0)) }
        guard guide.allSatisfy({ $0 != nil }) else { return }
        let points = guide.compactMap { $0 }
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        context.stroke(
            path,
            with: .color(tint.opacity(0.4)),
            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [7, 9], dashPhase: CGFloat(-time * 14))
        )
    }

    // MARK: Trail

    private func drawTrail(_ context: inout GraphicsContext, _ points: [TracePoint], color: Color, opacity: Double) {
        var path = Path()
        var open = false
        for point in points {
            guard let screen = map(point) else {
                open = false
                continue
            }
            if open { path.addLine(to: screen) } else { path.move(to: screen) }
            open = true
        }
        guard !path.isEmpty else { return }
        let round = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        for (width, alpha, tone) in [(18.0, 0.16, color), (9.0, 0.45, color), (3.5, 0.95, Color.white)] as [(CGFloat, Double, Color)] {
            var style = round
            style.lineWidth = width
            context.stroke(path, with: .color(tone.opacity(alpha * opacity)), style: style)
        }
    }
}
