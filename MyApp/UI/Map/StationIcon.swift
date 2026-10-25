import SwiftUI

/// The marks the docs describe for AR, drawn once so the 2D map and the AR overlay share a look:
/// a "?" on task tiles (dimmed once the player has done that task), an EMERGENCY badge on the
/// meeting tile, a wrench on the fix station. `.map` is the compact version for the 2D map.
/// `.world` is the large one, with the word spelled out, for the AR module to turn into a
/// texture with `ImageRenderer`.
struct StationIcon: View {
    enum Style { case map, world }

    let kind: StationKind
    var done = false
    var size: CGFloat = 28
    var style: Style = .map

    var body: some View {
        icon
            .opacity(done ? 0.35 : 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .task:
            Text("?")
                .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.Palette.accent, in: Circle())
        case .emergency where style == .world:
            Text("EMERGENCY")
                .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                .tracking(size * 0.02)
                .foregroundStyle(.white)
                .padding(.horizontal, size * 0.4)
                .frame(height: size)
                .background(Theme.Palette.emergency, in: Capsule())
        case .emergency:
            Image(systemName: "exclamationmark")
                .font(.system(size: size * 0.6, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.Palette.emergency, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        case .fix:
            Image(systemName: "wrench.fill")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
                .frame(width: size, height: size)
                .background(Theme.Palette.warning, in: Circle())
        }
    }
}

extension MapStation {
    /// Spoken by VoiceOver on the map and in lists.
    var spokenKind: String {
        switch kind {
        case .task: "task station"
        case .emergency: "emergency meeting tile"
        case .fix: "fix station"
        }
    }
}
