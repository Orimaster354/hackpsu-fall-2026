import SwiftUI

/// One button style for the whole app. Pressing scales to 0.96 over 150ms (ease-out). A disabled
/// button never scales, and under Reduce Motion the press dims instead of moving.
struct GameButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text }

    var kind: Kind = .primary
    var tint: Color = Theme.Palette.accent
    /// A request is in flight: keep the full-strength look instead of the dimmed disabled one.
    var isBusy = false
    /// Opt out where the motion would distract.
    var scalesOnPress = true

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        let dimmed = !isEnabled && !isBusy
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)

        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(foreground.opacity(dimmed ? 0.55 : 1))
            .frame(maxWidth: kind == .text ? nil : .infinity, minHeight: kind == .text ? 44 : 56)
            .padding(.horizontal, kind == .text ? 16 : 0)
            .background {
                switch kind {
                case .primary:
                    shape.fill(tint.opacity(dimmed ? 0.35 : 1))
                case .secondary:
                    shape.fill(Theme.Palette.surface)
                        .overlay { shape.strokeBorder(Theme.Palette.surfaceStroke, lineWidth: 1) }
                case .text:
                    Color.clear
                }
            }
            .contentShape(shape)
            .scaleEffect(pressed && scalesOnPress && !reduceMotion ? 0.96 : 1)
            .opacity(pressed && (reduceMotion || !scalesOnPress) ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: Theme.Palette.textPrimary
        case .text: Theme.Palette.textSecondary
        }
    }
}

extension ButtonStyle where Self == GameButtonStyle {
    /// `.buttonStyle(.game(.primary, busy: session.pending == .create))`
    static func game(_ kind: GameButtonStyle.Kind, busy: Bool = false, tint: Color = Theme.Palette.accent) -> GameButtonStyle {
        GameButtonStyle(kind: kind, tint: tint, isBusy: busy)
    }
}

/// Button label that swaps to a spinner and a progress word while a request is in flight.
struct BusyLabel: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isBusy { ProgressView().tint(.white) }
            Text(isBusy ? busyTitle : title)
        }
    }
}
