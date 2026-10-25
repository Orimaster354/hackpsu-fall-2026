import Foundation

/// The documented server rules (docs/architecture.md, "Rules enforced by the server") as a plain
/// state machine with no timers, so the mock server and the tests can both drive it. It is the
/// stand-in for `server/` while that does not exist. Error codes are placeholders.
struct MockGame {
    struct Rules {
        var killCooldown: TimeInterval = 25
        var meetingLength: TimeInterval = 30
        var sabotageCooldown: TimeInterval = 45
        var maxEmergencies = 3
        /// Drift filter: a tile change counts after this many identical reports in a row.
        var identicalTileReports = 2
    }

    /// An event and its audience. `to == nil` means everyone.
    struct Output: Equatable {
        var to: String?
        var event: ServerEvent
    }

    struct Seat {
        var info: PlayerInfo
        var role: PlayerRole
        var lastReport: MapTile?
        var streak = 0
        var emergencyUsed = false
        var finishedTasks: Set<String> = []
    }

    let rules: Rules
    let grid: MapGrid
    let stations: [MapStation]
    private(set) var seats: [Seat]
    private(set) var phase: GamePhase = .playing
    private(set) var killCooldownEndsAt: Date?
    private(set) var sabotageReadyAt: Date?
    private(set) var lightsOut = false
    private(set) var meeting: MeetingInfo?
    private(set) var emergenciesUsed = 0
    private(set) var reportedBodies: Set<String> = []
    private(set) var winner: Winner?

    /// The kill cooldown also runs from game start (docs).
    init(players: [PlayerInfo], impostors: Set<String>, grid: MapGrid, stations: [MapStation], rules: Rules = Rules(), now: Date) {
        self.rules = rules
        self.grid = grid
        self.stations = stations
        seats = players.map { Seat(info: $0, role: impostors.contains($0.id) ? .impostor : .crew) }
        killCooldownEndsAt = now.addingTimeInterval(rules.killCooldown)
    }

    // MARK: Reading

    func seat(_ id: String) -> Seat? { seats.first { $0.info.id == id } }
    func role(of id: String) -> PlayerRole? { seat(id)?.role }

    /// docs: `tasksTotal` counts tasks for living crew only. Ghosts do not do tasks.
    var tasksTotal: Int { seats.filter { $0.role == .crew && $0.info.alive }.count * stations.filter { $0.kind == .task }.count }
    var tasksDone: Int { seats.filter { $0.role == .crew && $0.info.alive }.reduce(0) { $0 + $1.finishedTasks.count } }

    func snapshot() -> GameSnapshot {
        GameSnapshot(
            phase: phase,
            players: seats.map(\.info),
            tasksDone: tasksDone,
            tasksTotal: tasksTotal,
            lightsOut: lightsOut,
            killCooldownEndsAt: killCooldownEndsAt,
            meeting: meeting
        )
    }

    // MARK: Intents

    mutating func handle(_ intent: ClientIntent, from id: String, now: Date) -> [Output] {
        guard let i = seats.firstIndex(where: { $0.info.id == id }), phase != .ended else { return [] }
        switch intent {
        case let .tile(tile, source): return reportTile(tile, source: source, seat: i)
        case let .taskDone(stationID): return taskDone(stationID, seat: i)
        case let .kill(targetID): return kill(targetID, seat: i, now: now)
        case let .report(bodyID): return report(bodyID, seat: i, now: now)
        case .emergency: return emergency(seat: i, now: now)
        case let .vote(vote): return castVote(vote, seat: i)
        case .sabotage: return sabotage(seat: i, now: now)
        case let .fix(stationID): return fix(stationID, seat: i)
        default: return []   // lobby intents belong to the server, not to a running game
        }
    }

    /// Ends the meeting when its time is up.
    mutating func tick(now: Date) -> [Output] {
        guard phase == .meeting, let meeting, now >= meeting.endsAt else { return [] }
        return endMeeting()
    }

    // MARK: Rules

    private mutating func reportTile(_ tile: MapTile, source: TileSource, seat i: Int) -> [Output] {
        // A dead player's phone stays on the body tile.
        guard seats[i].info.alive else { return [] }
        guard grid.contains(tile) else { return fail(i, "not_playable", "That tile is outside the room.") }
        if tile == seats[i].info.tile {
            seats[i].lastReport = nil
            seats[i].streak = 0
            return []
        }
        if tile == seats[i].lastReport {
            seats[i].streak += 1
        } else {
            seats[i].lastReport = tile
            seats[i].streak = 1
        }
        guard seats[i].streak >= rules.identicalTileReports else { return [] }
        seats[i].info.tile = tile
        seats[i].info.tileSource = source
        seats[i].lastReport = nil
        seats[i].streak = 0
        return [stateOutput()]
    }

    private mutating func taskDone(_ stationID: String, seat i: Int) -> [Output] {
        guard phase == .playing, seats[i].role == .crew, seats[i].info.alive else {
            return fail(i, "not_allowed", "Only living crew do tasks.")
        }
        guard !lightsOut else { return fail(i, "lights_out", "Tasks are blocked while the lights are out.") }
        guard let station = stations.first(where: { $0.id == stationID && $0.kind == .task }) else {
            return fail(i, "unknown_station", "There is no such task station.")
        }
        guard station.tile == seats[i].info.tile else { return fail(i, "not_on_station", "Stand on the station to do its task.") }
        guard seats[i].finishedTasks.insert(stationID).inserted else { return [] }
        var out = [stateOutput()]
        if let winner = winCheck(ejectedRole: nil) { out += finish(winner) }
        return out
    }

    private mutating func kill(_ targetID: String, seat i: Int, now: Date) -> [Output] {
        guard phase == .playing, seats[i].role == .impostor, seats[i].info.alive else {
            return fail(i, "not_allowed", "Only the living impostor can do that.")
        }
        guard let t = seats.firstIndex(where: { $0.info.id == targetID }), seats[t].info.alive, seats[t].role == .crew else {
            return fail(i, "invalid_target", "That player cannot be eliminated.")
        }
        guard seats[i].info.tile != nil, seats[i].info.tile == seats[t].info.tile else {
            return fail(i, "not_same_tile", "You must be on the same tile.")
        }
        guard killCooldownEndsAt.map({ $0 <= now }) ?? true else { return fail(i, "cooldown", "Your ability is still recharging.") }
        seats[t].info.alive = false
        killCooldownEndsAt = now.addingTimeInterval(rules.killCooldown)
        var out = [Output(to: targetID, event: .killed), stateOutput()]
        if let winner = winCheck(ejectedRole: nil) { out += finish(winner) }
        return out
    }

    private mutating func report(_ bodyID: String, seat i: Int, now: Date) -> [Output] {
        guard phase == .playing, seats[i].info.alive else { return fail(i, "not_allowed", "You cannot report right now.") }
        guard let b = seats.firstIndex(where: { $0.info.id == bodyID }), !seats[b].info.alive, !reportedBodies.contains(bodyID) else {
            return fail(i, "no_body", "There is no body to report.")
        }
        guard seats[i].info.tile != nil, seats[i].info.tile == seats[b].info.tile else {
            return fail(i, "not_on_body", "You must be on the body's tile.")
        }
        reportedBodies.insert(bodyID)
        return startMeeting(.report, bodyOf: bodyID, now: now)
    }

    private mutating func emergency(seat i: Int, now: Date) -> [Output] {
        guard phase == .playing, seats[i].info.alive else { return fail(i, "not_allowed", "You cannot call a meeting right now.") }
        guard !seats[i].emergencyUsed, emergenciesUsed < rules.maxEmergencies else {
            return fail(i, "no_emergencies_left", "No emergency meetings left.")
        }
        guard let spot = stations.first(where: { $0.kind == .emergency }), spot.tile == seats[i].info.tile else {
            return fail(i, "not_on_emergency_tile", "Go to the emergency tile first.")
        }
        seats[i].emergencyUsed = true
        emergenciesUsed += 1
        return startMeeting(.emergency, bodyOf: nil, now: now)
    }

    private mutating func castVote(_ vote: Vote, seat i: Int) -> [Output] {
        let id = seats[i].info.id
        guard phase == .meeting, var current = meeting, seats[i].info.alive else {
            return fail(i, "cannot_vote", "You cannot vote right now.")
        }
        guard current.votes[id] == nil else { return fail(i, "already_voted", "You already voted.") }
        if case let .player(target) = vote {
            guard let t = seats.firstIndex(where: { $0.info.id == target }), seats[t].info.alive else {
                return fail(i, "invalid_target", "That player is not in the vote.")
            }
        }
        current.votes[id] = vote
        meeting = current
        var out = [Output(to: nil, event: .meeting(current)), stateOutput()]
        if seats.filter({ $0.info.alive }).allSatisfy({ current.votes[$0.info.id] != nil }) { out += endMeeting() }
        return out
    }

    private mutating func sabotage(seat i: Int, now: Date) -> [Output] {
        guard phase == .playing, seats[i].role == .impostor, seats[i].info.alive, !lightsOut else {
            return fail(i, "not_allowed", "You cannot sabotage right now.")
        }
        guard sabotageReadyAt.map({ $0 <= now }) ?? true else { return fail(i, "cooldown", "Sabotage is still recharging.") }
        lightsOut = true
        sabotageReadyAt = now.addingTimeInterval(rules.sabotageCooldown)
        return [stateOutput()]
    }

    private mutating func fix(_ stationID: String, seat i: Int) -> [Output] {
        guard phase == .playing, seats[i].role == .crew, seats[i].info.alive, lightsOut else {
            return fail(i, "not_allowed", "There is nothing to fix.")
        }
        guard let station = stations.first(where: { $0.id == stationID && $0.kind == .fix }), station.tile == seats[i].info.tile else {
            return fail(i, "not_on_fix_station", "Stand on the fix station.")
        }
        lightsOut = false
        return [stateOutput()]
    }

    // MARK: Meetings and winning

    private mutating func startMeeting(_ reason: MeetingReason, bodyOf: String?, now: Date) -> [Output] {
        phase = .meeting
        let info = MeetingInfo(reason: reason, bodyOf: bodyOf, endsAt: now.addingTimeInterval(rules.meetingLength), votes: [:])
        meeting = info
        return [Output(to: nil, event: .meeting(info)), stateOutput()]
    }

    /// Majority ejects. A tie, or skips matching the top vote, ejects no one. Silence counts as a skip.
    private mutating func endMeeting() -> [Output] {
        guard let current = meeting else { return [] }
        var counts: [String: Int] = [:]
        var skips = 0
        for seat in seats where seat.info.alive {
            switch current.votes[seat.info.id] {
            case let .player(target)?: counts[target, default: 0] += 1
            case .skip?, nil: skips += 1
            }
        }
        let top = counts.values.max() ?? 0
        let leaders = counts.filter { $0.value == top }.map(\.key)
        var ejected: String?
        if top > 0, leaders.count == 1, top > skips { ejected = leaders[0] }
        var ejectedRole: PlayerRole?
        if let ejected, let e = seats.firstIndex(where: { $0.info.id == ejected }) {
            seats[e].info.alive = false
            ejectedRole = seats[e].role
        }
        meeting = nil
        phase = .playing
        if let winner = winCheck(ejectedRole: ejectedRole) { return finish(winner, ejected: ejected, role: ejectedRole) }
        return [Output(to: nil, event: .result(MeetingResult(ejected: ejected, role: ejectedRole, winner: nil))), stateOutput()]
    }

    /// docs: crew win when all tasks are done or the impostor is ejected. The impostor wins when
    /// living crew are no more than living impostors.
    private func winCheck(ejectedRole: PlayerRole?) -> Winner? {
        if ejectedRole == .impostor { return .crew }
        let crew = seats.filter { $0.role == .crew && $0.info.alive }.count
        let impostors = seats.filter { $0.role == .impostor && $0.info.alive }.count
        if crew <= impostors { return .impostor }
        if tasksTotal > 0, tasksDone >= tasksTotal { return .crew }
        return nil
    }

    private mutating func finish(_ winner: Winner, ejected: String? = nil, role: PlayerRole? = nil) -> [Output] {
        self.winner = winner
        phase = .ended
        meeting = nil
        return [Output(to: nil, event: .result(MeetingResult(ejected: ejected, role: role, winner: winner))), stateOutput()]
    }

    private func stateOutput() -> Output { Output(to: nil, event: .state(snapshot())) }

    private func fail(_ seat: Int, _ code: String, _ message: String) -> [Output] {
        [Output(to: seats[seat].info.id, event: .error(SessionError(code: code, message: message)))]
    }
}
