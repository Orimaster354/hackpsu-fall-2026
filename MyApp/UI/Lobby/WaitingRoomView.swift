import SwiftUI

/// The lobby after create or join: the room code, who is in, the host's room setup, and whether
/// the game can start. `start` needs 4 players and confirmed setup (docs).
struct WaitingRoomView: View {
    @Environment(GameSession.self) private var session
    @State private var confirmLeave = false
    @State private var showSetup: Bool

    /// `showsSetupReview` is for previews and screenshots.
    init(showsSetupReview: Bool = false) {
        _showSetup = State(initialValue: showsSetupReview)
    }

    private var slotCount: Int { max(GameSession.requiredPlayers, session.players.count) }
    private var isStarting: Bool { session.lobbyStatus == .starting }

    var body: some View {
        ScrollScreen(spacing: 24) {
            VStack(spacing: 14) {
                Text("ROOM CODE")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Theme.Palette.textSecondary)
                RoomCodeBadge(code: session.roomCode ?? "")
                if session.players.count < GameSession.requiredPlayers {
                    Text("Everyone else taps Join room and types this in.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .staggeredEntrance(0)

            playersCard.staggeredEntrance(1)

            if session.isHost {
                SetupCard(status: session.setupStatus, stationCount: session.taskStations.count) { showSetup = true }
                    .staggeredEntrance(2)
            }

            VStack(spacing: 12) {
                StatusLine(status: session.lobbyStatus, isHost: session.isHost)
                if let error = session.error {
                    ErrorMessage(text: error.message)
                }
            }
            .staggeredEntrance(3)
        } bar: {
            actions
        }
        .sensoryFeedback(.impact(weight: .light), trigger: session.players.count)
        .fullScreenCover(isPresented: $showSetup) { SetupReviewView() }
        .confirmationDialog("Leave this room?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave room", role: .destructive) { session.leave() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("You will need the room code to get back in.")
        }
    }

    private var playersCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Players")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                Text("\(session.players.count)/\(slotCount)")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .accessibilityLabel("\(session.players.count) of \(slotCount) players")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            ForEach(0..<slotCount, id: \.self) { slot in
                let player = session.players.indices.contains(slot) ? session.players[slot] : nil
                PlayerRow(
                    player: player,
                    colorIndex: slot,
                    isYou: player != nil && player?.id == session.myID,
                    isHost: player != nil && player?.id == session.hostID
                )
            }
        }
        .padding(12)
        .gameCard()
        .animation(.spring(duration: 0.3, bounce: 0), value: session.players)
    }

    private var actions: some View {
        VStack(spacing: 4) {
            if session.isHost {
                if session.setupStatus == .needsReview {
                    Button("Review setup") { showSetup = true }
                        .buttonStyle(.game(.primary))
                        .accessibilityIdentifier("reviewSetupButton")
                } else {
                    Button { session.startGame() } label: {
                        BusyLabel(title: "Start game", busyTitle: "Starting…", isBusy: isStarting)
                    }
                    .buttonStyle(.game(.primary, busy: isStarting))
                    .disabled(!session.canStart)
                    .accessibilityIdentifier("startGameButton")
                }
            }
            Button("Leave room") { confirmLeave = true }
                .buttonStyle(.game(.text))
                .disabled(isStarting)
                .accessibilityIdentifier("leaveRoomButton")
        }
    }
}

/// One of the lobby slots, filled or waiting for a player.
private struct PlayerRow: View {
    let player: PlayerInfo?
    let colorIndex: Int
    let isYou: Bool
    let isHost: Bool

    /// The old content leaves at once and the new content fades in, so the two never overlap.
    private let swap = AnyTransition.asymmetric(insertion: .opacity, removal: .identity)

    var body: some View {
        HStack(spacing: 12) {
            PlayerAvatar(name: player?.name, colorIndex: colorIndex)
            ZStack(alignment: .leading) {
                if let player {
                    SplitLine {
                        Text(player.name)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                    } extras: {
                        if isHost { Tag(text: "Host") }
                        if isYou { Tag(text: "You") }
                    }
                    .transition(swap)
                } else {
                    Text("Waiting for player…")
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .transition(swap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(
            player == nil ? Color.clear : Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        guard let player else { return "Empty slot, waiting for a player" }
        return player.name + (isHost ? ", host" : "") + (isYou ? ", you" : "")
    }
}

/// The host's setup step: scan, wait for the server, review, confirm. What the scan itself does
/// belongs to the AR module, which supplies `startRoomScan` through the environment.
private struct SetupCard: View {
    let status: GameSession.SetupStatus
    let stationCount: Int
    let onEdit: () -> Void
    @Environment(\.startRoomScan) private var startScan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                icon.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(.headline, design: .rounded, weight: .bold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch status {
            case .needsScan:
                if let startScan {
                    Button("Scan room", action: startScan.run).buttonStyle(.game(.primary))
                }
            case .processing, .needsReview:
                EmptyView()
            case .confirmed:
                Button("Edit setup", action: onEdit).buttonStyle(.game(.secondary))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gameCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .needsScan: Image(systemName: "viewfinder").font(.title3.weight(.bold))
        case .processing: ProgressView()
        case .needsReview: Image(systemName: "map").font(.title3.weight(.bold))
        case .confirmed: Image(systemName: "checkmark.circle.fill").font(.title3.weight(.bold)).foregroundStyle(Theme.Palette.success)
        }
    }

    private var title: String {
        switch status {
        case .needsScan: "Scan the room"
        case .processing: "Building the room…"
        case .needsReview: "Review the room setup"
        case .confirmed: "Room setup confirmed"
        }
    }

    private var detail: String {
        switch status {
        case .needsScan: "Walk the room twice with the camera: once past every object, once along the walls. The server builds the map."
        case let .processing(step):
            switch step {
            case .polygon: "Finding the walls."
            case .gemini: "Spotting objects in the videos."
            case .placing: "Placing stations on the edge tiles."
            }
        case .needsReview: "\(stationCount) stations placed. Review them and confirm to unlock Start."
        case .confirmed: "\(stationCount) stations. Editing asks you to confirm again."
        }
    }
}

/// The ready states: waiting for players, setup to confirm, ready to start, starting.
private struct StatusLine: View {
    let status: GameSession.LobbyStatus
    let isHost: Bool

    /// Which icon is showing. The icon swaps only when this changes, not when a count does.
    private enum Kind: Equatable { case waiting, setup, ready, guestReady, starting }

    private var kind: Kind {
        switch status {
        case .waiting: .waiting
        case .needsSetup: .setup
        case .ready: isHost ? .ready : .guestReady
        case .starting: .starting
        }
    }

    private var message: String {
        switch status {
        case let .waiting(missing): missing == 1 ? "Waiting for 1 more player" : "Waiting for \(missing) more players"
        case .needsSetup: "Everyone is here. Confirm the room setup to start."
        case .ready: isHost ? "Everyone is here. Start when ready." : "Waiting for the host to start"
        case .starting: "Starting game…"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                icon.id(kind).transition(IconSwap())
            }
            .animation(.iconSwap, value: kind)
            Text(message)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(Theme.Palette.textPrimary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .waiting: Image(systemName: "person.badge.plus")
        case .setup: Image(systemName: "map")
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
        case .guestReady: Image(systemName: "clock")
        case .starting: ProgressView()
        }
    }
}

#Preview("Scanning") {
    RootView(session: .mock(.scanning))
}

#Preview("Waiting, host, setup to review") {
    RootView(session: .mock(.waiting))
}

#Preview("Four players, setup to confirm") {
    RootView(session: .mock(.needsSetup))
}

#Preview("Ready, host") {
    RootView(session: .mock(.ready))
}

#Preview("Ready, guest") {
    RootView(session: .mock(.readyGuest))
}

#Preview("Starting") {
    RootView(session: .mock(.starting))
}
