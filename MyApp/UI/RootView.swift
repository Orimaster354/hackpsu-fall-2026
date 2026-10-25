import SwiftUI
import UIKit

/// A closure that can sit in the environment without invalidating every view on each update:
/// two of these are equal when they are the same instance.
struct RoomScanAction: Equatable {
    private let id = UUID()
    let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }
    static func == (a: RoomScanAction, b: RoomScanAction) -> Bool { a.id == b.id }
}

extension EnvironmentValues {
    /// Set by the AR module to start the host's two-pass room capture. Nil until then, and the
    /// setup card simply does not offer a scan button.
    @Entry var startRoomScan: RoomScanAction? = nil
}

/// Shows the screen for the session's current stage. This is the one view the app mounts.
///
/// Integration points, all optional:
/// - a `GameSession` wired to `GameClient` instead of the mock (`send`, `receive`),
/// - a `PositionCoordinator(ar:)` holding the AR module's `PositionProvider`,
/// - `startRoomScan`, which opens the AR capture flow for the host.
struct RootView: View {
    @State private var session: GameSession
    @State private var position: PositionCoordinator
    @State private var homePath: [HomeRoute]
    private let preview: ScreenPreview
    private let scanAction: RoomScanAction?

    /// Explicit session for previews and for the integration layer. `homePath` and `preview` set
    /// initial screen state for previews and screenshots.
    init(
        session: GameSession,
        position: PositionCoordinator = PositionCoordinator(),
        homePath: [HomeRoute] = [],
        preview: ScreenPreview = ScreenPreview(),
        startRoomScan: (() -> Void)? = nil
    ) {
        _session = State(initialValue: session)
        _position = State(initialValue: position)
        _homePath = State(initialValue: homePath)
        self.preview = preview
        scanAction = startRoomScan.map { RoomScanAction($0) }
    }

    /// Runs on the mock server and manual tiles. Integration swaps this for the real wiring.
    init() {
        let launch = MockLaunch.current
        let ar: MockARProvider? = switch launch.position {
        case .manual: nil
        case .ar: MockARProvider()
        case .arFail: MockARProvider(failsToRelocalize: true)
        }
        let position = PositionCoordinator(ar: ar)
        if launch.position == .arFail { position.searchTimeout = .seconds(6) }
        self.init(
            session: .mock(launch.scenario, role: launch.role, fast: launch.fast, seed: launch.seed),
            position: position,
            homePath: launch.scenario == .join ? [.join] : [],
            preview: launch.preview
        )
    }

    var body: some View {
        ZStack {
            GameBackdrop().ignoresSafeArea()
            screen
                .id(session.stage)
                .transition(Motion.screen)
        }
        .animation(.easeOut(duration: 0.3), value: session.stage)
        .environment(session)
        .environment(position)
        .environment(\.startRoomScan, scanAction)
        .preferredColorScheme(.dark)
        .tint(Theme.Palette.crew)
        .onChange(of: session.stage) {
            // Once in a room, forget the Join screen so leaving the room lands on Home.
            if session.stage != .home {
                withTransaction(Transaction(animation: nil)) { homePath = [] }
            }
        }
        .task(id: session.stage) { syncWithStage() }
    }

    @ViewBuilder private var screen: some View {
        switch session.stage {
        case .home:
            HomeFlow(path: $homePath)
        case .lobby:
            WaitingRoomView(showsSetupReview: preview.setupReview)
        case .roleReveal:
            RoleRevealView(
                role: session.role ?? .crew,
                startsRevealed: preview.roleRevealed,
                onContinue: session.acknowledgeRole
            )
        case .playing:
            GameView(showPositionSheet: preview.positionSheet)
        case .meeting:
            MeetingView()
        case .result:
            ResultView()
        case .ended:
            EndView()
        }
    }

    /// Position starts when the role is revealed, so AR can relocalize while the player reads it,
    /// and stops when the game does. The phone stays awake all game: a ghost's phone is a body.
    private func syncWithStage() {
        switch session.stage {
        case .roleReveal, .playing, .meeting, .result:
            if let grid = session.grid { position.begin(grid: grid, report: session.reportTile) }
        case .home, .lobby, .ended:
            position.end()
        }
        UIApplication.shared.isIdleTimerDisabled = session.stage != .home
    }
}
