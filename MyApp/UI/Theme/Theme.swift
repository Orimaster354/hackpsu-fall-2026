import SwiftUI

/// Design tokens. The game is dark only: it is played in a dim room and "lights out" dims it further.
/// Contrast was checked against WCAG AA (4.5:1): white on accent 5.35, secondary text 9.1, every avatar fill 5.0 or better.
enum Theme {
    enum Palette {
        static let backgroundTop = Color(hex: 0x050814)
        static let backgroundBottom = Color(hex: 0x0B1433)
        /// Dark glass behind cards and panels, over the space backdrop.
        static let panel = Color(hex: 0x0A1230)
        /// The space-cyberpunk accents: neon cyan for edges and glows, electric blue for buttons,
        /// violet and magenta only in the backdrop's nebula and horizon.
        static let neon = Color(hex: 0x3DDCFF)
        static let glow = Color(hex: 0x3D8BFF)
        static let violet = Color(hex: 0x7B5CFF)
        static let magenta = Color(hex: 0xFF3DB8)
        static let surface = Color.white.opacity(0.07)
        static let surfaceStroke = Color.white.opacity(0.10)
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.72)
        /// Dark text on bright fills such as avatars.
        static let ink = Color(hex: 0x0B1020)
        /// Fill behind white button text.
        static let accent = Color(hex: 0x2A5FEA)
        /// Text, icons and the app tint on the dark background: 7.2.
        static let crew = Color(hex: 0x5BB0FF)
        static let impostor = Color(hex: 0xFF5A6B)
        static let success = Color(hex: 0x3DDC97)
        static let danger = Color(hex: 0xFF7A85)
        /// Placeholder text in fields: 4.6:1 or better on the field fill.
        static let placeholder = Color.white.opacity(0.5)
        /// Fill behind white icons on the emergency tile: 5.49.
        static let emergency = Color(hex: 0xC8283D)
        /// The fix station's wrench. Dark ink on it is 9.9.
        static let warning = Color(hex: 0xEAB308)
    }

    /// Outer radius = inner radius + padding. A 12pt padded card holds 12pt rows, so the card is 24.
    enum Radius {
        static let row: CGFloat = 12
        static let control: CGFloat = 16
        static let card: CGFloat = 24
    }

    /// Widest the content column grows on iPad and landscape.
    static let columnWidth: CGFloat = 480
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// The centered content column. The backdrop is drawn once, by `RootView`.
    func gameColumn() -> some View {
        frame(maxWidth: Theme.columnWidth)
            .frame(maxWidth: .infinity)
    }

    /// A dark glass panel: deep navy over the backdrop, with a hairline edge that catches a little
    /// neon at the top left.
    func gameCard(radius: CGFloat = Theme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Theme.Palette.panel.opacity(0.7), in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Theme.Palette.neon.opacity(0.3), Color.white.opacity(0.07), Theme.Palette.glow.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
    }
}

/// The calm space backdrop for sheets and covers. `RootView` draws the richer per-screen scenes.
struct GameBackdrop: View {
    var body: some View {
        SpaceBackdrop(scene: .game, animated: false)
    }
}
