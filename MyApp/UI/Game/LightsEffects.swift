import SwiftUI

/// What a crew member sees when the impostor kills the lights, and when the crew brings them
/// back. Going dark is a flicker and then a held dim with a slow red pulse at the edges. Coming
/// back is a cyan scan line sweeping down the screen, a flash and a "Lights restored" chip. It
/// never takes touches. Under Reduce Motion the dim is still and the return is a fade.
struct LightsEffect: View {
    /// True while the lights are out for this player.
    let isOut: Bool
    /// Increment when the crew fixes the lights, to play the return.
    let restores: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var darkness = 0.0

    struct Return {
        var sweep = 0.0
        var flash = 0.0
        var chip = 0.0
    }

    var body: some View {
        let reduced = reduceMotion
        ZStack {
            LightsDimFrame(darkness: darkness)
            if isOut, !reduced { StrobeEdge() }
            Color.clear
                .keyframeAnimator(initialValue: Return(), trigger: restores) { _, values in
                    LightsReturnFrame(values: values, reduced: reduced)
                } keyframes: { _ in
                    KeyframeTrack(\.sweep) { CubicKeyframe(1, duration: 0.7) }
                    KeyframeTrack(\.flash) {
                        CubicKeyframe(0.28, duration: 0.12)
                        CubicKeyframe(0, duration: 0.45)
                    }
                    KeyframeTrack(\.chip) {
                        CubicKeyframe(1, duration: 0.25)
                        LinearKeyframe(1, duration: 1.5)
                        CubicKeyframe(0, duration: 0.3)
                    }
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: isOut) { await updateDarkness() }
    }

    private func updateDarkness() async {
        if !isOut {
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.5)) { darkness = 0 }
            return
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { darkness = 1 }
            return
        }
        // A failing light: a few quick steps, with no animation between them, then it settles dark.
        for (level, pause) in [(0.0, 0), (0.85, 60), (0.15, 70), (0.9, 60), (0.35, 80), (0.75, 90)] as [(Double, Int)] {
            try? await Task.sleep(for: .milliseconds(pause))
            guard !Task.isCancelled else { return }
            withTransaction(Transaction(animation: nil)) { darkness = level }
        }
        withAnimation(.easeOut(duration: 0.4)) { darkness = 1 }
    }
}

/// The held dim: a veil over everything and heavier edges.
struct LightsDimFrame: View {
    let darkness: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.24 * darkness)
            RadialGradient(colors: [.clear, Color.black.opacity(0.66 * darkness)], center: .center, startRadius: 120, endRadius: 540)
        }
    }
}

/// A slow red pulse around the edge of the screen while the lights are out.
private struct StrobeEdge: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            let pulse = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 4.4)
            Rectangle()
                .strokeBorder(Theme.Palette.impostor.opacity(0.1 + 0.28 * pulse), lineWidth: 10)
                .blur(radius: 9)
        }
    }
}

/// One frame of the return: the scan line, the flash, and the chip.
struct LightsReturnFrame: View {
    let values: LightsEffect.Return
    var reduced = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Theme.Palette.neon.opacity(reduced ? 0 : values.flash)
                if !reduced {
                    let band: CGFloat = 140
                    LinearGradient(colors: [.clear, Theme.Palette.neon.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: band)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .offset(y: -band + values.sweep * (proxy.size.height + band * 2))
                        .opacity(values.sweep > 0 && values.sweep < 1 ? 1 : 0)
                }
                chip
                    .padding(.top, proxy.safeAreaInsets.top + 12)
                    .offset(y: reduced ? 0 : (1 - values.chip) * -24)
                    .opacity(values.chip)
            }
        }
    }

    private var chip: some View {
        Label("LIGHTS RESTORED", systemImage: "bolt.fill")
            .font(.system(.footnote, design: .rounded, weight: .heavy))
            .tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Theme.Palette.panel.opacity(0.92), in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.Palette.neon, lineWidth: 1.5) }
            .shadow(color: Theme.Palette.neon.opacity(0.6), radius: 12)
    }
}
