import SwiftUI

/// Shows the player's secret role, but only while they press and hold, so a neighbour in the
/// same room cannot read it off the screen. "Got it" appears after the first reveal.
struct RoleRevealView: View {
    let role: PlayerRole
    let onContinue: () -> Void

    @State private var isRevealed: Bool
    @State private var hasRevealed: Bool
    @Environment(\.scenePhase) private var scenePhase

    /// `startsRevealed` is for previews and screenshots.
    init(role: PlayerRole, startsRevealed: Bool = false, onContinue: @escaping () -> Void) {
        self.role = role
        self.onContinue = onContinue
        _isRevealed = State(initialValue: startsRevealed)
        _hasRevealed = State(initialValue: startsRevealed)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Your role")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .staggeredEntrance(0)

                card.staggeredEntrance(1)

                Text(isRevealed ? "Let go to hide it again." : "Cover your screen from the others, then press and hold.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .staggeredEntrance(2)

                Button("Got it", action: onContinue)
                    .buttonStyle(.game(.primary))
                    .opacity(hasRevealed ? 1 : 0)
                    .disabled(!hasRevealed)
                    .accessibilityHidden(!hasRevealed)
                    .accessibilityIdentifier("roleContinueButton")
                    .animation(.easeOut(duration: 0.3), value: hasRevealed)
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .gameColumn()
        .background { glow }
        .onChange(of: scenePhase) {
            if scenePhase != .active { setRevealed(false) }
        }
        .sensoryFeedback(trigger: isRevealed) { _, revealed in
            guard revealed else { return nil }
            return role == .impostor ? .warning : .success
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return ZStack {
            if isRevealed {
                revealedFace.transition(Motion.swap)
            } else {
                hiddenFace.transition(Motion.swap)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(24)
        .background(isRevealed ? role.tint.opacity(0.12) : Theme.Palette.surface, in: shape)
        .overlay {
            shape.strokeBorder(
                isRevealed ? role.tint.opacity(0.7) : Theme.Palette.surfaceStroke,
                lineWidth: isRevealed ? 2 : 1
            )
        }
        .contentShape(shape)
        .animation(.easeOut(duration: isRevealed ? 0.3 : 0.15), value: isRevealed)
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, perform: {}, onPressingChanged: setRevealed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRevealed ? "\(role.title). \(role.briefing)" : "Your role is hidden")
        .accessibilityHint(isRevealed ? "Double tap to hide it" : "Double tap to reveal it")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { setRevealed(!isRevealed) }
        .accessibilityIdentifier("roleCard")
    }

    private var hiddenFace: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("Press and hold to reveal")
                .font(.system(.title, design: .rounded, weight: .heavy))
                .multilineTextAlignment(.center)
        }
    }

    private var revealedFace: some View {
        VStack(spacing: 16) {
            Image(systemName: role.symbol)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(role.tint)
            Text(role.title.uppercased())
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .tracking(2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(role.tint)
            Text(role.briefing)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
    }

    private var glow: some View {
        RadialGradient(
            colors: [role.tint.opacity(isRevealed ? 0.3 : 0), .clear],
            center: .center,
            startRadius: 20,
            endRadius: 380
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: isRevealed)
    }

    private func setRevealed(_ revealed: Bool) {
        isRevealed = revealed
        if revealed { hasRevealed = true }
    }
}

extension PlayerRole {
    var title: String { self == .crew ? "Crewmate" : "Impostor" }
    var symbol: String { self == .crew ? "wrench.and.screwdriver.fill" : "theatermasks.fill" }
    var tint: Color { self == .crew ? Theme.Palette.crew : Theme.Palette.impostor }

    var briefing: String {
        switch self {
        case .crew: "Do tasks at the stations around the room. Report a body, or call a meeting, when something feels off."
        case .impostor: "Eliminate a crewmate when you are alone with one on your tile. Blend in and don't get voted out."
        }
    }
}

#Preview("Crewmate, hidden") {
    RootView(session: .mock(.crew))
}

#Preview("Crewmate, revealed") {
    RootView(session: .mock(.crew), preview: ScreenPreview(roleRevealed: true))
}

#Preview("Impostor, revealed") {
    RootView(session: .mock(.impostor), preview: ScreenPreview(roleRevealed: true))
}
