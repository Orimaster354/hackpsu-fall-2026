import Foundation
import Observation

/// Everything the lobby and role screens know about the game, and the only thing they talk to.
/// Intents go out through `send`. Events come in through `receive`. The mock server and the
/// future `GameClient` adapter both plug into those two seams.
@Observable
final class GameSession {
    enum Stage: Equatable { case home, lobby, roleReveal, playing }
    enum Request: Equatable { case create, join, start }
    enum LobbyStatus: Equatable { case waiting(missing: Int), ready, starting }

    /// `start` needs 4 players (docs/architecture.md).
    static let requiredPlayers = 4

    private(set) var roomCode: String?
    private(set) var myID: String?
    private(set) var players: [LobbyPlayer] = []
    private(set) var phase: GamePhase = .lobby
    private(set) var role: PlayerRole?
    private(set) var roleAcknowledged = false
    /// The request waiting for a server answer, if any. Screens show progress from this.
    private(set) var pending: Request?
    private(set) var error: SessionError?

    @ObservationIgnored var send: (ClientIntent) -> Void = { _ in }
    @ObservationIgnored var disconnect: () -> Void = {}
    /// Shown in settings so nobody mistakes the mock for a live server.
    @ObservationIgnored var transportName = "Not connected"
    @ObservationIgnored var requestTimeout: Duration = .seconds(8)
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    /// The host is the creator, who joins first (see the gaps note in SessionModels.swift).
    var hostID: String? { players.first?.id }
    var isHost: Bool { myID != nil && myID == hostID }

    var stage: Stage {
        guard roomCode != nil else { return .home }
        guard phase != .lobby, role != nil else { return .lobby }
        return roleAcknowledged ? .playing : .roleReveal
    }

    var lobbyStatus: LobbyStatus {
        // The game has started but this phone's `role` has not arrived yet.
        if pending == .start || phase != .lobby { return .starting }
        let missing = Self.requiredPlayers - players.count
        return missing > 0 ? .waiting(missing: missing) : .ready
    }

    var canStart: Bool { isHost && lobbyStatus == .ready && pending == nil }

    // MARK: Intents

    func createRoom(name: String) {
        let name = PlayerName.normalized(name)
        guard pending == nil, PlayerName.isValid(name) else { return }
        begin(.create, sending: .create(name: name))
    }

    func joinRoom(code: String, name: String) {
        let name = PlayerName.normalized(name)
        let code = RoomCode.clamp(code)
        guard pending == nil, PlayerName.isValid(name), RoomCode.isValid(code) else { return }
        begin(.join, sending: .join(room: code, name: name))
    }

    func startGame() {
        guard canStart else { return }
        begin(.start, sending: .start)
    }

    func acknowledgeRole() {
        roleAcknowledged = true
    }

    func dismissError() {
        error = nil
    }

    func leave() {
        timeoutTask?.cancel()
        disconnect()
        roomCode = nil
        myID = nil
        players = []
        phase = .lobby
        role = nil
        roleAcknowledged = false
        pending = nil
        error = nil
    }

    // MARK: Events

    func receive(_ event: ServerEvent) {
        switch event {
        case let .joined(playerID, room):
            myID = playerID
            roomCode = room
            finish(.create)
            finish(.join)
        case let .lobby(players):
            self.players = players
        case let .role(role):
            self.role = role
        case let .state(phase):
            self.phase = phase
            if phase != .lobby { finish(.start) }
        case let .error(error):
            fail(error)
        }
    }

    // MARK: Requests

    private func begin(_ request: Request, sending intent: ClientIntent) {
        error = nil
        pending = request
        send(intent)
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, requestTimeout] in
            try? await Task.sleep(for: requestTimeout)
            guard !Task.isCancelled, let self, self.pending == request else { return }
            self.fail(.timeout)
        }
    }

    private func finish(_ request: Request) {
        guard pending == request else { return }
        pending = nil
        timeoutTask?.cancel()
    }

    private func fail(_ error: SessionError) {
        self.error = error
        pending = nil
        timeoutTask?.cancel()
    }
}
