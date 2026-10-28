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

    /// A game needs 4 to 10 connected players (docs/architecture.md). One impostor up to six players, two from seven.
    static let minPlayers = 4
    static let maxPlayers = 10
    /// What `start` needs. Kept under the old name for the screens that still use it.
    static let requiredPlayers = minPlayers
    /// A game can span up to six scanned rooms (the server's limit).
    static let maxRooms = 6

    static func impostorCount(forPlayers count: Int) -> Int { count >= 7 ? 2 : 1 }

    // Room
    private(set) var roomCode: String?
    private(set) var myID: String?
    private(set) var players: [PlayerInfo] = []
    private(set) var grid: MapGrid?
    private(set) var stations: [MapStation] = []
    private(set) var hasMap = false
    private(set) var setupStep: SetupStep?
    private(set) var setupConfirmed = false
    /// Counts every `setup` event received. It goes up even when the new grid equals the old one, which is what
    /// happens when the host repeats a perimeter walk with the same poses. A scan step waits for this to change
    /// instead of comparing grids.
    private(set) var setupRevision = 0
    /// The scanned rooms (empty until the first perimeter). Each has its own grid, offset, map and doors.
    private(set) var zones: [ZoneInfo] = []

    // Game
    private(set) var phase: GamePhase = .lobby
    private(set) var role: PlayerRole?
    private(set) var roleAcknowledged = false
    /// This player's special crew power, if any. Private.
    private(set) var power: Power?
    /// Ids of the other impostors, for an impostor. Empty for crew.
    private(set) var partners: [String] = []
    /// The Scout's latest ping and when it arrived. The map shows it for a few seconds.
    private(set) var scoutPing: ScoutPing?
    private(set) var scoutPingAt: Date?
    /// True once the Medic has used the revive, so the button can hide.
    private(set) var reviveUsed = false
    /// Set when the Medic brings this player back; the HUD shows a short notice.
    private(set) var revivedAt: Date?
    private(set) var tasksDone = 0
    private(set) var tasksTotal = 0
    private(set) var lightsOut = false
    /// The sabotage that is active right now (lights, jammer or meltdown), or nil.
    private(set) var activeSabotage: SabotageState?
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

    /// From the server's `lobby.hostId` when known, else the creator who joins first.
    private(set) var serverHostID: String?
    var hostID: String? { serverHostID ?? players.first?.id }
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
        let missing = Self.minPlayers - players.filter(\.connected).count
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
        serverHostID = nil
        players = []
        grid = nil
        stations = []
        hasMap = false
        setupStep = nil
        setupConfirmed = false
        phase = .lobby
        role = nil
        roleAcknowledged = false
        power = nil
        partners = []
        scoutPing = nil
        scoutPingAt = nil
        reviveUsed = false
        revivedAt = nil
        zones = []
        activeSabotage = nil
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

    /// An impostor starts one of the three sabotages. Only one can be active, and they share a cooldown.
    func sabotage(_ kind: SabotageKind) {
        guard role == .impostor, isAlive, phase == .playing, activeSabotage == nil else { return }
        send(.sabotage(kind))
    }

    /// Repairs the active sabotage. It must be at that sabotage's fix station; a meltdown needs two crew at once.
    func fix(_ station: MapStation) {
        guard role == .crew, isAlive, phase == .playing, let sabotage = activeSabotage, station.kind == .fix,
              sabotage.fixStationId == nil || sabotage.fixStationId == station.id else { return }
        send(.fix(stationID: station.id))
    }

    /// Medic: revive the body on this tile. Scout: ping. Both are checked again by the server.
    func useAbility() {
        guard role == .crew, isAlive, phase == .playing, let power else { return }
        switch power {
        case .medic:
            guard !reviveUsed, let body = bodiesHere.first else { return }
            reviveUsed = true
            send(.ability(targetID: body.id))
        case .scout:
            send(.ability(targetID: nil))
        }
    }

    /// Host, lobby: set the doors between scanned rooms.
    func setDoors(_ doors: [DoorLink]) {
        guard isHost, phase == .lobby else { return }
        send(.setDoors(doors))
    }

    func removeZone(_ id: String) {
        guard isHost, phase == .lobby else { return }
        send(.removeZone(id))
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
        case let .zones(zones):
            self.zones = zones
        case let .power(power, partners):
            self.power = power
            self.partners = partners
        case let .scout(ping):
            scoutPing = ping
            scoutPingAt = Date()
        case .revived:
            revivedAt = Date()
            // Back in the game: the old "you were killed" state no longer applies.
            if let index = players.firstIndex(where: { $0.id == myID }) { players[index].alive = true }
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
            setupRevision += 1
        case let .setupStatus(confirmed):
            setupConfirmed = confirmed
        case let .host(id):
            serverHostID = id
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
            // A rejected revive (wrong tile, too late) leaves the Medic their one use.
            if error.code == "INVALID_BODY" || error.code == "ABILITY_USED" { reviveUsed = error.code == "ABILITY_USED" }
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
        activeSabotage = snapshot.sabotage
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
