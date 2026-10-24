import SwiftUI

/// The lobby after create or join: the room code, who is in, and whether the game can start.
struct WaitingRoomView: View {
    @Environment(GameSession.self) private var session
    @State private var confirmLeave = false

    private var slotCount: Int { max(GameSession.requiredPlayers, session.players.count) }
    private var isStarting: Bool { session.lobbyStatus == .starting }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    Text("ROOM CODE")
                        .font(.caption.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    RoomCodeBadge(code: session.roomCode ?? "")
                    Text("Everyone else taps Join room and types this in.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .staggeredEntrance(0)

                playersCard.staggeredEntrance(1)

                VStack(spacing: 12) {
                    StatusLine(status: session.lobbyStatus, isHost: session.isHost)
                    if let error = session.error {
                        ErrorMessage(text: error.message)
                    }
                }
                .staggeredEntrance(2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) { actions }
        .gameColumn()
        .sensoryFeedback(.impact(weight: .light), trigger: session.players.count)
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
                Button { session.startGame() } label: {
                    BusyLabel(title: "Start game", busyTitle: "Starting…", isBusy: isStarting)
                }
                .buttonStyle(.game(.primary, busy: isStarting))
                .disabled(!session.canStart)
                .accessibilityIdentifier("startGameButton")
            }
            Button("Leave room") { confirmLeave = true }
                .buttonStyle(.game(.text))
                .disabled(isStarting)
                .accessibilityIdentifier("leaveRoomButton")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .gameColumn()
    }
}

/// One of the lobby slots, filled or waiting for a player.
private struct PlayerRow: View {
    let player: LobbyPlayer?
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
                    HStack(spacing: 12) {
                        Text(player.name)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
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
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
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

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.14), in: Capsule())
    }
}

/// The ready states: waiting for players, ready to start, starting.
private struct StatusLine: View {
    let status: GameSession.LobbyStatus
    let isHost: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch status {
            case .waiting(let missing):
                Image(systemName: "person.badge.plus")
                Text(missing == 1 ? "Waiting for 1 more player" : "Waiting for \(missing) more players")
            case .ready where isHost:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
                Text("Everyone is here. Start when ready.")
            case .ready:
                Image(systemName: "clock")
                Text("Waiting for the host to start")
            case .starting:
                ProgressView()
                Text("Starting game…")
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(Theme.Palette.textPrimary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Waiting, host, 2 of 4") {
    RootView(session: .mock(.waiting))
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
