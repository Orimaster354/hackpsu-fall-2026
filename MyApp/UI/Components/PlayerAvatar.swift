import SwiftUI

enum PlayerPalette {
    private static let colors: [Color] = [0xEF4444, 0x4C8DFF, 0x22C55E, 0xEAB308, 0xA78BFA, 0x22D3EE, 0xFB923C, 0xF472B6]
        .map { Color(hex: $0) }

    /// Colors follow a player's position in the lobby list, so that list's order must stay stable.
    /// Every fill has 4.5:1 or better against `Theme.Palette.ink`.
    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}

/// A colored disc with the player's initial. `name == nil` draws an empty slot.
struct PlayerAvatar: View {
    let name: String?
    let colorIndex: Int
    @ScaledMetric private var scaledSize: CGFloat = 40
    /// Counts the times this slot filled, so a player joining pops in. Not on first appearance.
    @State private var joins = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Follows Dynamic Type, but stops growing so a row never turns into one big circle.
    private var size: CGFloat { min(scaledSize, 56) }

    var body: some View {
        ZStack {
            if let name {
                Circle().fill(PlayerPalette.color(at: colorIndex))
                Text(String(name.first ?? "?").uppercased())
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.Palette.ink)
            } else {
                Circle()
                    .strokeBorder(Theme.Palette.textSecondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: 1.0, trigger: joins) { avatar, scale in
            avatar.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(0.7, duration: 0.01)
            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
        }
        .onChange(of: name != nil) { _, filled in
            if filled && !reduceMotion { joins += 1 }
        }
        .accessibilityHidden(true)
    }
}
