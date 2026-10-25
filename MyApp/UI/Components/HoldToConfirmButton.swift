import SwiftUI

/// A button you press and hold until it fills. Used for the stand-in task and for fixing the
/// lights. Letting go early resets it. VoiceOver cannot hold, so its default action completes it.
struct HoldToConfirmButton: View {
    let title: String
    var duration: Double = 2
    var tint: Color = Theme.Palette.accent
    let onComplete: () -> Void

    @State private var progress = 0.0
    @State private var completions = 0
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Text(title)
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.55))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                shape.fill(tint.opacity(isEnabled ? 0.45 : 0.25))
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            tint.opacity(isEnabled ? 1 : 0.35).frame(width: proxy.size.width * progress)
                        }
                    }
                    .clipShape(shape)
            }
            .contentShape(shape)
            .onLongPressGesture(minimumDuration: duration, maximumDistance: 60, perform: complete, onPressingChanged: pressing)
            .sensoryFeedback(.success, trigger: completions)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint("Press and hold. VoiceOver users can double tap to finish at once.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { complete() }
    }

    private func pressing(_ isPressing: Bool) {
        guard isEnabled, progress < 1 else { return }
        withAnimation(isPressing ? .linear(duration: duration) : .easeOut(duration: 0.15)) {
            progress = isPressing ? 1 : 0
        }
    }

    private func complete() {
        guard isEnabled else { return }
        completions += 1
        onComplete()
        withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
    }
}
