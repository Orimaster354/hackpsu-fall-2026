import SwiftUI

/// The impostor's kill control: slide the knob across to eliminate a player on your tile (docs:
/// "impostor swipes"). The server still checks the tile and the cooldown, this only decides
/// whether to offer the slide. With more than one player on the tile it asks who.
struct KillPad: View {
    let targets: [PlayerInfo]
    let cooldownEndsAt: Date?
    let onKill: (PlayerInfo) -> Void

    @State private var drag: CGFloat = 0
    @State private var choosing = false
    @State private var kills = 0
    /// Counts kills, to play the slash across the track.
    @State private var slashes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Grows with Dynamic Type so the label still fits the track.
    @ScaledMetric(relativeTo: .subheadline) private var scaledKnob: CGFloat = 48

    private var knob: CGFloat { min(scaledKnob, 72) }
    /// Track radius = knob radius + this inset: 16 + 4.
    private let inset: CGFloat = 4

    private enum Mode: Equatable { case cooling(Int), noTarget, ready }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
            pad(mode(at: timeline.date))
        }
        .frame(height: knob + inset * 2)
        .confirmationDialog("Eliminate who?", isPresented: $choosing, titleVisibility: .visible) {
            ForEach(targets) { target in
                Button(target.name, role: .destructive) { fire(target) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: kills)
    }

    private func mode(at now: Date) -> Mode {
        let remaining = cooldownEndsAt.map { $0.timeIntervalSince(now) } ?? 0
        if remaining > 0 { return .cooling(Int(remaining.rounded(.up))) }
        return targets.isEmpty ? .noTarget : .ready
    }

    private func pad(_ mode: Mode) -> some View {
        let ready = mode == .ready
        return GeometryReader { proxy in
            let travel = max(0, proxy.size.width - knob - inset * 2)
            ZStack(alignment: .leading) {
                // A groove the knob slides in: darker than the screen, edged in red once it is armed.
                RoundedRectangle(cornerRadius: 16 + inset, style: .continuous)
                    .fill(LinearGradient(colors: [.black.opacity(0.4), .black.opacity(0.18)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16 + inset, style: .continuous)
                            .strokeBorder(ready ? Theme.Palette.emergency.opacity(0.55) : Theme.Palette.surfaceStroke, lineWidth: 1)
                    }
                Text(label(mode))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(ready ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob + inset)
                    .padding(.trailing, inset * 2)
                Image(systemName: ready ? "chevron.right.2" : "lock.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: knob, height: knob)
                    .background { KnobSlab(active: ready) }
                    .offset(x: inset + drag)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { if ready { drag = min(max(0, $0.translation.width), travel) } }
                            .onEnded { _ in
                                let finished = ready && drag >= travel * 0.85
                                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0)) { drag = 0 }
                                if finished { trigger() }
                            }
                    )
            }
        }
        .overlay { SlashFlash(trigger: slashes, radius: 16 + inset) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eliminate")
        .accessibilityValue(label(mode))
        .accessibilityAddTraits(ready ? .isButton : [])
        .accessibilityAction(named: "Eliminate nearby player") { if ready { trigger() } }
    }

    private func label(_ mode: Mode) -> String {
        switch mode {
        case let .cooling(seconds): "Recharging, \(seconds) s"
        case .noTarget: "No one on your tile"
        case .ready: targets.count == 1 ? "Swipe to eliminate \(targets[0].name)" : "Swipe to eliminate"
        }
    }

    private func trigger() {
        if targets.count == 1 { fire(targets[0]) } else if targets.count > 1 { choosing = true }
    }

    private func fire(_ target: PlayerInfo) {
        kills += 1
        slashes += 1
        onKill(target)
    }
}

/// The knob: a red slab with the same raised look as the buttons.
private struct KnobSlab: View {
    let active: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            shape
                .fill(Theme.Palette.emergency.slabLip)
                .shadow(color: Theme.Palette.emergency.opacity(active ? 0.5 : 0), radius: 10, y: 4)
                .offset(y: 3)
            shape
                .fill(LinearGradient(
                    colors: [Theme.Palette.emergency.slabFaceTop, Theme.Palette.emergency.slabFaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [Theme.Palette.emergency.slabEdge, Theme.Palette.emergency.slabEdge.opacity(0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
                }
        }
        .opacity(active ? 1 : 0.4)
    }
}

/// A bright slash running across the track, and a red flash, when the kill goes out.
private struct SlashFlash: View {
    let trigger: Int
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Values {
        var sweep = 0.0
        var flash = 0.0
    }

    var body: some View {
        let reduced = reduceMotion
        Color.clear
            .keyframeAnimator(initialValue: Values(), trigger: trigger) { _, values in
                GeometryReader { proxy in
                    ZStack {
                        Theme.Palette.emergency.opacity(values.flash)
                        if !reduced {
                            Capsule()
                                .fill(LinearGradient(colors: [.clear, .white, Theme.Palette.impostor, .clear], startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * 0.5, height: 4)
                                .rotationEffect(.degrees(-18))
                                .offset(x: -proxy.size.width * 0.5 + values.sweep * proxy.size.width * 1.5)
                                .opacity(values.sweep > 0 && values.sweep < 1 ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } keyframes: { _ in
                KeyframeTrack(\.sweep) { CubicKeyframe(1, duration: 0.3) }
                KeyframeTrack(\.flash) {
                    CubicKeyframe(0.45, duration: 0.08)
                    CubicKeyframe(0, duration: 0.4)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
