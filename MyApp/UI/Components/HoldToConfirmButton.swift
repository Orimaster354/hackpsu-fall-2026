import SwiftUI

/// A button you press and hold until it fills. Used for fixing the lights. It is the same slab as
/// every other button, with the face filling from the left while you hold. Letting go early resets
/// it. VoiceOver cannot hold, so its default action completes it.
struct HoldToConfirmButton: View {
    let title: String
    var duration: Double = 2
    var tint: Color = Theme.Palette.glow
    let onComplete: () -> Void

    @State private var progress = 0.0
    /// The fill's own animation: linear for the whole hold, a quick ease-out for a reset. Changed
    /// together with `progress`, never through `withAnimation`, so the press animation cannot cut it short.
    @State private var fillAnimation = Animation.easeOut(duration: 0.15)
    @State private var isPressing = false
    @State private var completions = 0
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .font(.system(.headline, design: .rounded, weight: .heavy))
            .foregroundStyle(.white)
            .slabSurface(tint: tint, pressed: isPressing && isEnabled, dimmed: !isEnabled, progress: progress, progressAnimation: fillAnimation)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: isPressing)
            .onLongPressGesture(minimumDuration: duration, maximumDistance: 60, perform: complete, onPressingChanged: pressing)
            .sensoryFeedback(.success, trigger: completions)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint("Press and hold. VoiceOver users can double tap to finish at once.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { complete() }
    }

    private func pressing(_ isPressing: Bool) {
        self.isPressing = isPressing
        guard isEnabled, progress < 1 else { return }
        fillAnimation = isPressing ? .linear(duration: duration) : .easeOut(duration: 0.15)
        progress = isPressing ? 1 : 0
    }

    private func complete() {
        guard isEnabled else { return }
        completions += 1
        onComplete()
        fillAnimation = .easeOut(duration: 0.15)
        progress = 0
    }
}
