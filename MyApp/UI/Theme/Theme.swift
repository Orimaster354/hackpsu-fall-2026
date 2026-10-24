import SwiftUI

/// Design tokens. The game is dark only: it is played in a dim room and "lights out" dims it further.
/// Contrast was checked against WCAG AA (4.5:1): white on accent 5.35, secondary text 9.1, every avatar fill 5.0 or better.
enum Theme {
    enum Palette {
        static let backgroundTop = Color(hex: 0x0B1020)
        static let backgroundBottom = Color(hex: 0x151D3B)
        static let surface = Color.white.opacity(0.07)
        static let surfaceStroke = Color.white.opacity(0.10)
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.72)
        /// Dark text on bright fills such as avatars.
        static let ink = Color(hex: 0x0B1020)
        /// Fill behind white button text.
        static let accent = Color(hex: 0x2A5FEA)
        static let crew = Color(hex: 0x5BB0FF)
        static let impostor = Color(hex: 0xFF5A6B)
        static let success = Color(hex: 0x3DDC97)
        static let danger = Color(hex: 0xFF7A85)
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

    /// A raised group: a faint fill with a hairline edge.
    func gameCard(radius: CGFloat = Theme.Radius.card) -> some View {
        background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Palette.surfaceStroke, lineWidth: 1)
            }
    }
}

struct GameBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Theme.Palette.backgroundTop, Theme.Palette.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
