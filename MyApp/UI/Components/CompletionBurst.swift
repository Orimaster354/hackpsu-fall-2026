import SwiftUI

/// One frame of the task-complete burst at time `t` (0 to 1): two shockwave rings, a spray of
/// sparks, and a check that draws itself inside a glowing disc. It is `Animatable`, so
/// `withAnimation { t = 1 }` runs the whole thing, and a still can be drawn for any `t`. With
/// `reduced` set (Reduce Motion) only the disc and the check appear.
struct CompletionBurstFrame: View, Animatable {
    var t: Double
    var tint: Color = Theme.Palette.success
    var reduced = false
    /// Off for a plain spray of sparks, such as behind the end banner.
    var showsCheck = true

    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    private static let sparkCount = 16

    var body: some View {
        Canvas { context, size in
            draw(&context, size: size)
        }
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    /// Overshoots a little before settling, like a spring with a touch of bounce.
    private func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        let x = clamp(x)
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2

        if !reduced {
            for (delay, width) in [(0.0, 5.0), (0.14, 2.5)] {
                let p = clamp((t - delay) / 0.7)
                guard p > 0, p < 1 else { continue }
                context.stroke(
                    circle(center, radius * (0.25 + 0.75 * easeOut(p))),
                    with: .color(tint.opacity(0.85 * (1 - p))),
                    lineWidth: width * (1 - 0.7 * p)
                )
            }
            let sparkProgress = clamp((t - 0.04) / 0.85)
            if sparkProgress > 0, sparkProgress < 1 {
                for index in 0 ..< Self.sparkCount {
                    // A fixed fan with a little irregularity, so it reads as a burst and not a clock face.
                    let jitter = sin(Double(index) * 12.9898) * 0.5 + 0.5
                    let angle = Double(index) / Double(Self.sparkCount) * 2 * .pi + jitter * 0.3
                    let reach = radius * (0.7 + 0.3 * jitter)
                    let head = radius * 0.3 + (reach - radius * 0.3) * easeOut(sparkProgress)
                    let tail = max(radius * 0.3, head - (radius * 0.2 * (1 - sparkProgress) + 2))
                    var spark = Path()
                    spark.move(to: CGPoint(x: center.x + cos(angle) * tail, y: center.y + sin(angle) * tail))
                    spark.addLine(to: CGPoint(x: center.x + cos(angle) * head, y: center.y + sin(angle) * head))
                    let color = index % 3 == 0 ? Color.white : (index % 3 == 1 ? tint : Theme.Palette.neon)
                    context.stroke(
                        spark,
                        with: .color(color.opacity(1 - sparkProgress * sparkProgress)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                }
            }
        }

        guard showsCheck else { return }
        let core = radius * 0.34 * (reduced ? clamp(t * 3) : easeOutBack(t / 0.4))
        guard core > 0 else { return }
        context.fill(circle(center, core * 1.5), with: .radialGradient(
            Gradient(colors: [tint.opacity(0.5), tint.opacity(0)]), center: center, startRadius: 0, endRadius: core * 1.5
        ))
        context.fill(circle(center, core), with: .color(Theme.Palette.panel.opacity(0.9)))
        context.stroke(circle(center, core), with: .color(tint.opacity(clamp(t * 6))), lineWidth: 3)

        let drawn = reduced ? clamp((t - 0.1) * 3) : easeOut((t - 0.1) / 0.4)
        guard drawn > 0 else { return }
        var check = Path()
        check.move(to: CGPoint(x: center.x - core * 0.42, y: center.y + core * 0.05))
        check.addLine(to: CGPoint(x: center.x - core * 0.1, y: center.y + core * 0.38))
        check.addLine(to: CGPoint(x: center.x + core * 0.46, y: center.y - core * 0.3))
        let trimmed = check.trimmedPath(from: 0, to: drawn)
        context.stroke(trimmed, with: .color(tint.opacity(0.4)), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
        context.stroke(trimmed, with: .color(.white), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
    }
}

/// The burst, playing once when it appears. It is for rare moments, a finished task above all.
struct CompletionBurst: View {
    var tint: Color = Theme.Palette.success
    var size: CGFloat = 240
    var showsCheck = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var t = 0.0

    var body: some View {
        CompletionBurstFrame(t: t, tint: tint, reduced: reduceMotion, showsCheck: showsCheck)
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.linear(duration: reduceMotion ? 0.3 : 1.0)) { t = 1 }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// A brief wash of color from the middle of the screen: the room lighting up for a finished task.
struct CompletionFlash: View {
    /// Increment to play it.
    let trigger: Int
    var tint: Color = Theme.Palette.success
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reduced = reduceMotion
        RadialGradient(colors: [tint.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 440)
            .ignoresSafeArea()
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, opacity in
                view.opacity(reduced ? 0 : opacity)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.12)
                CubicKeyframe(0, duration: 0.55)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
