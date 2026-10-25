import Foundation
import Observation

/// Everything the screens know about the game, and the only thing they talk to. Intents go out
/// through `send`. Events come in through `receive`. The mock server and the future `GameClient`
/// adapter both plug into those two seams. The server is authoritative: this class never decides
/// a rule, it only remembers what it was told and guards against intents that could not be valid.
@Observable
final class GameSession {
    enum Stage: Equatable { case home, lobby, roleReveal, playing, meeting, result, ended }
    enum Request: Equatable { case create, join, start }
    enum LobbyStatus: Equatable { case waiting(missing: Int), needsSetup, ready, starting }
    enum SetupStatus: Equatable { case needsScan, processing(SetupStep), needsReview, confirmed }

    /// `start` needs 4 players (docs/architecture.md).
    static let requiredPlayers = 4

    // Room
    private(set) var roomCode: String?
    private(set) var myID: String?
    private(set) var players: [PlayerInfo] = []
    private(set) var grid: MapGrid?
    private(set) var stations: [MapStation] = []
    private(set) var hasMap = false
    private(set) var setupStep: SetupStep?
    private(set) var setupConfirmed = false

    // Game
    private(set) var phase: GamePhase = .lobby
    private(set) var role: PlayerRole?
    private(set) var roleAcknowledged = false
    private(set) var tasksDone = 0
    private(set) var tasksTotal = 0
    private(set) var lightsOut = false
    private(set) var killCooldownEndsAt: Date?
    private(set) var meeting: MeetingInfo?
    /// A meeting result the player has not seen yet. The result screen clears it.
    private(set) var pendingResult: MeetingResult?
    private(set) var lastResult: MeetingResult?

    // Bookkeeping the protocol does not carry (see the gaps note in SessionModels.swift)
    private(set) var completedStationIDs: Set<String> = []
    private(set) var emergencyUsed = false
    private(set) var myVote: Vote?
    private(set) var reportedBodyIDs: Set<String> = []

    /// The request waiting for a server answer, if any. Screens show progress from this.
    private(set) var pending: Request?
    private(set) var error: SessionError?

    @ObservationIgnored var send: (ClientIntent) -> Void = { _ in }
    @ObservationIgnored var disconnect: () -> Void = {}
    /// Shown in settings so nobody mistakes the mock for a live server.
    @ObservationIgnored var transportName = "Not connected"
    @ObservationIgnored var requestTimeout: Duration = .seconds(8)
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var lastTaskAttempt: (id: String, at: Date)?

    // MARK: Derived room state

    /// The host is the creator, who joins first (see the gaps note in SessionModels.swift).
    var hostID: String? { players.first?.id }
    var isHost: Bool { myID != nil && myID == hostID }

    var stage: Stage {
        guard roomCode != nil else { return .home }
        guard phase != .lobby, role != nil else { return .lobby }
        guard roleAcknowledged else { return .roleReveal }
        if pendingResult != nil { return .result }
        switch phase {
        case .playing: return .playing
        case .meeting: return .meeting
        case .ended: return .ended
        case .lobby: return .lobby
        }
    }

    var lobbyStatus: LobbyStatus {
        // The game has started but this phone's `role` has not arrived yet.
        if pending == .start || phase != .lobby { return .starting }
        // The server needs four connected players. A disconnected player still holds a seat.
        let missing = Self.requiredPlayers - players.filter(\.connected).count
        if missing > 0 { return .waiting(missing: missing) }
        return isHost && !setupConfirmed ? .needsSetup : .ready
    }

    var setupStatus: SetupStatus {
        if let setupStep { return .processing(setupStep) }
        guard grid != nil, !stations.isEmpty else { return .needsScan }
        return setupConfirmed ? .confirmed : .needsReview
    }

    var canStart: Bool { isHost && lobbyStatus == .ready && pending == nil }

    // MARK: Lobby intents

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

    /// Lobby only. Readiness is advisory; the server does not require it to start.
    func setReady(_ ready: Bool) {
        guard phase == .lobby, roomCode != nil else { return }
        send(.ready(ready))
    }

    /// Host only, lobby only. The tile must be an edge tile (docs: `editStation`).
    func editStation(_ station: MapStation) {
        guard isHost, phase == .lobby, let grid, grid.edge.contains(station.tile) else { return }
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index] = station
        } else {
            stations.append(station)
        }
        setupConfirmed = false
        send(.editStation(station))
    }

    func deleteStation(id: String) {
        guard isHost, phase == .lobby, stations.contains(where: { $0.id == id }) else { return }
        stations.removeAll { $0.id == id }
        setupConfirmed = false
        send(.deleteStation(id: id))
    }

    func confirmSetup() {
        guard isHost, phase == .lobby, setupStatus == .needsReview else { return }
        setupConfirmed = true
        send(.confirmSetup)
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
        grid = nil
        stations = []
        hasMap = false
        setupStep = nil
        setupConfirmed = false
        phase = .lobby
        role = nil
        roleAcknowledged = false
        tasksDone = 0
        tasksTotal = 0
        lightsOut = false
        killCooldownEndsAt = nil
        meeting = nil
        pendingResult = nil
        lastResult = nil
        completedStationIDs = []
        emergencyUsed = false
        myVote = nil
        reportedBodyIDs = []
        lastTaskAttempt = nil
        pending = nil
        error = nil
    }

    // MARK: Game intents

    /// The one funnel for position. The manual picker and ARKit both end up here, at 2 to 4 Hz.
    func reportTile(_ tile: MapTile, source: TileSource) {
        guard phase != .lobby, role != nil else { return }
        send(.tile(tile, source: source))
    }

    func completeTask(at station: MapStation) {
        guard canDoTask(at: station) else { return }
        completedStationIDs.insert(station.id)
        lastTaskAttempt = (station.id, Date())
        send(.taskDone(stationID: station.id))
    }

    func kill(_ target: PlayerInfo) {
        guard role == .impostor, isAlive, phase == .playing else { return }
        send(.kill(targetID: target.id))
    }

    func report(_ body: PlayerInfo) {
        guard isAlive, phase == .playing else { return }
        send(.report(bodyID: body.id))
    }

    func callEmergency() {
        guard canCallEmergency else { return }
        emergencyUsed = true
        send(.emergency)
    }

    func castVote(_ vote: Vote) {
        guard phase == .meeting, isAlive, myVote == nil else { return }
        myVote = vote
        send(.vote(vote))
    }

    func sabotage() {
        guard role == .impostor, isAlive, phase == .playing, !lightsOut else { return }
        send(.sabotage)
    }

    func fix(_ station: MapStation) {
        guard role == .crew, isAlive, phase == .playing, lightsOut, station.kind == .fix else { return }
        send(.fix(stationID: station.id))
    }

    func acknowledgeResult() {
        pendingResult = nil
    }

    // MARK: Events

    func receive(_ event: ServerEvent) {
        switch event {
        case let .joined(playerID, room):
            myID = playerID
            roomCode = room
            finish(.create)
            finish(.join)
        case let .lobby(players, grid, stations, hasMap):
            self.players = players
            self.grid = grid
            self.stations = stations
            self.hasMap = hasMap
        case let .processing(step):
            setupStep = step
        case let .setup(grid, stations):
            self.grid = grid
            self.stations = stations
            setupStep = nil
            setupConfirmed = false
        case let .setupStatus(confirmed):
            setupConfirmed = confirmed
        case let .role(role):
            self.role = role
        case let .state(snapshot):
            apply(snapshot)
        case .killed:
            // The `state` that follows carries alive = false. Marking it now avoids a stale HUD.
            if let index = players.firstIndex(where: { $0.id == myID }) { players[index].alive = false }
        case let .meeting(info):
            if phase == .playing { phase = .meeting }
            setMeeting(info)
        case let .result(result):
            lastResult = result
            if result.ejected != nil || phase == .meeting || meeting != nil { pendingResult = result }
        case let .error(error):
            // A rejected `taskDone` arrives as an error right after the intent. Undo the optimistic mark.
            if let attempt = lastTaskAttempt, Date().timeIntervalSince(attempt.at) < 2 {
                completedStationIDs.remove(attempt.id)
            }
            lastTaskAttempt = nil
            fail(error)
        }
    }

    private func apply(_ snapshot: GameSnapshot) {
        phase = snapshot.phase
        players = snapshot.players
        tasksDone = snapshot.tasksDone
        tasksTotal = snapshot.tasksTotal
        lightsOut = snapshot.lightsOut
        killCooldownEndsAt = snapshot.killCooldownEndsAt
        setMeeting(snapshot.meeting)
        if snapshot.phase != .lobby { finish(.start) }
    }

    private func setMeeting(_ new: MeetingInfo?) {
        if let new {
            if meeting == nil { myVote = nil }
            if let body = new.bodyOf { reportedBodyIDs.insert(body) }
            if let myID, let vote = new.votes[myID] { myVote = vote }
        }
        meeting = new
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
