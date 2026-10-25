import SwiftUI

/// The home screen logo: the mark over the wordmark, with an eye that has a life of its own. It
/// opens when the screen appears, then every few seconds glances somewhere else or blinks. Tapping
/// it startles the eye, which snaps to look at you. Under Reduce Motion the eye is open and still.
/// The home screen is seen once per session, so this is the one place a looping idle is earned.
struct BlindspotLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lookX: CGFloat = -0.55
    @State private var lookY: CGFloat = 0.1
    /// Starts shut, so the eye wakes up with the screen.
    @State private var lid: CGFloat = 0.06
    @State private var startles = 0
    /// Counts the scale pops, which Reduce Motion skips; the haptic and the eye still react.
    @State private var pops = 0

    private let restingLook = CGPoint(x: -0.55, y: 0.1)

    var body: some View {
        VStack(spacing: 10) {
            BlindspotMark(size: 136, lookX: lookX, lookY: lookY, lid: lid)
                .keyframeAnimator(initialValue: 1.0, trigger: pops) { mark, scale in
                    mark.scaleEffect(scale)
                } keyframes: { _ in
                    CubicKeyframe(1.07, duration: 0.09)
                    SpringKeyframe(1.0, duration: 0.35, spring: .smooth)
                }
                .onTapGesture { startle() }
            BlindspotWordmark()
        }
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.5), trigger: startles)
        .task { await idle() }
    }

    // MARK: Eye

    private func idle() async {
        if reduceMotion {
            lid = 1
            return
        }
        try? await Task.sleep(for: .milliseconds(650))
        withAnimation(.easeOut(duration: 0.25)) { lid = 1 }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.4 ... 4.8)))
            guard !Task.isCancelled else { return }
            if Int.random(in: 0 ..< 3) == 0 {
                await blink()
            } else {
                // Never far to the right: the eye sits near the right edge of the glass.
                withAnimation(.easeOut(duration: 0.26)) {
                    lookX = .random(in: -1 ... 0.25)
                    lookY = .random(in: -0.8 ... 0.8)
                }
            }
        }
    }

    private func blink() async {
        withAnimation(.easeOut(duration: 0.09)) { lid = 0.06 }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.easeOut(duration: 0.14)) { lid = 1 }
    }

    private func startle() {
        startles += 1
        if !reduceMotion { pops += 1 }
        withAnimation(.easeOut(duration: 0.12)) {
            lookX = 0
            lookY = 0
            lid = reduceMotion ? 1 : 1.18
        }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.3)) {
                lookX = restingLook.x
                lookY = restingLook.y
                lid = 1
            }
        }
    }
}

#Preview("Logo") {
    ZStack {
        GameBackdrop().ignoresSafeArea()
        BlindspotLogo()
    }
    .preferredColorScheme(.dark)
}
