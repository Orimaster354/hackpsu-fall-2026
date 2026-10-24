import SwiftUI

/// Stands in for the gameplay HUD (tasks, kill, report, emergency) until the next milestone.
struct PlayingPlaceholderView: View {
    @Environment(GameSession.self) private var session

    var body: some View {
        let role = session.role ?? .crew
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: role.symbol)
                .font(.system(size: 56))
                .foregroundStyle(role.tint)
            Text("Game in progress")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("Your role: \(role.title). The game screen with tasks, kill and emergency buttons comes next.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Back to start") { session.leave() }
                .buttonStyle(.game(.secondary))
        }
        .padding(20)
        .gameColumn()
        .staggeredEntrance(0)
    }
}

#Preview("Playing") {
    RootView(session: .mock(.playing))
}
