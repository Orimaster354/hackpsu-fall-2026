import SwiftUI

/// A big title that slams onto the screen for a moment and leaves: "EMERGENCY MEETING". It plays
/// each time `trigger` changes, and never covers the touches of the screen under it. Under Reduce
/// Motion it is a plain fade, with no slam, flash or sliding bars.
struct StageStinger: View {
    /// Increment to play it.
    let trigger: Int
    let title: String
    var tint: Color = Theme.Palette.emergency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Values {
        var opacity = 0.0
        var scale = 1.7
        var flash = 0.0
        var bars = 0.0
    }

    var body: some View {
        let reduced = reduceMotion
        Color.clear
            .keyframeAnimator(initialValue: Values(), trigger: trigger) { _, values in
                StingerFrame(values: values, title: title, tint: tint, reduced: reduced)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    CubicKeyframe(1, duration: 0.1)
                    LinearKeyframe(1, duration: 1.0)
                    CubicKeyframe(0, duration: 0.35)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1, duration: 0.3)
                    LinearKeyframe(1.04, duration: 1.15)
                }
                KeyframeTrack(\.flash) {
                    CubicKeyframe(0.5, duration: 0.1)
                    CubicKeyframe(0, duration: 0.5)
                }
                KeyframeTrack(\.bars) {
                    CubicKeyframe(1, duration: 0.35)
                    LinearKeyframe(1, duration: 0.8)
                    CubicKeyframe(0, duration: 0.3)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One frame of the stinger, so a still can be drawn for any moment.
struct StingerFrame: View {
    let values: StageStinger.Values
    let title: String
    let tint: Color
    var reduced = false

    var body: some View {
        ZStack {
            tint.opacity(reduced ? 0 : values.flash).ignoresSafeArea()
            VStack(spacing: 14) {
                bar
                Text(title)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .tracking(3)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                    .shadow(color: tint, radius: 14)
                    .shadow(color: tint.opacity(0.7), radius: 30)
                    .scaleEffect(reduced ? 1 : values.scale)
                bar
            }
            .padding(.horizontal, 28)
            .opacity(values.opacity)
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(LinearGradient(colors: [.clear, tint, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: proxy.size.width * (reduced ? 1 : values.bars), height: 3)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 3)
    }
}
