import SwiftUI

/// Shows the screen for the session's current stage. This is the one view the app mounts.
struct RootView: View {
    @State private var session: GameSession
    @State private var homePath: [HomeRoute]
    private let roleStartsRevealed: Bool

    /// Explicit session for previews and for the integration layer. `homePath` and
    /// `roleStartsRevealed` set initial screen state for previews and screenshots.
    init(session: GameSession, homePath: [HomeRoute] = [], roleStartsRevealed: Bool = false) {
        _session = State(initialValue: session)
        _homePath = State(initialValue: homePath)
        self.roleStartsRevealed = roleStartsRevealed
    }

    /// Runs on the mock server. Integration swaps this for a session wired to `GameClient`.
    init() {
        let launch = MockLaunch.current
        self.init(
            session: .mock(launch.scenario, role: launch.role),
            homePath: launch.scenario == .join ? [.join] : [],
            roleStartsRevealed: launch.revealed
        )
    }

    var body: some View {
        ZStack {
            GameBackdrop().ignoresSafeArea()
            screen
                .id(session.stage)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.25), value: session.stage)
        .onChange(of: session.stage) {
            // Once in a room, forget the Join screen so leaving the room lands on Home.
            if session.stage != .home {
                withTransaction(Transaction(animation: nil)) { homePath = [] }
            }
        }
        .environment(session)
        .preferredColorScheme(.dark)
        .tint(Theme.Palette.accent)
    }

    @ViewBuilder private var screen: some View {
        switch session.stage {
        case .home:
            HomeFlow(path: $homePath)
        case .lobby:
            WaitingRoomView()
        case .roleReveal:
            RoleRevealView(
                role: session.role ?? .crew,
                startsRevealed: roleStartsRevealed,
                onContinue: session.acknowledgeRole
            )
        case .playing:
            PlayingPlaceholderView()
        }
    }
}
