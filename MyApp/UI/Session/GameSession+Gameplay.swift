import Foundation

/// What the HUD, meeting and end screens ask the session. Every property is a view of server
/// state, so the server stays the only place a rule is decided. These only decide what to offer.
extension GameSession {
    var me: PlayerInfo? { players.first { $0.id == myID } }
    var isAlive: Bool { me?.alive ?? true }
    var myTile: MapTile? { me?.tile }
    /// Colors follow lobby order, so the list order must stay stable (see PlayerPalette).
    var myColorIndex: Int { players.firstIndex { $0.id == myID } ?? 0 }

    func colorIndex(of id: String) -> Int { players.firstIndex { $0.id == id } ?? 0 }
    func player(_ id: String?) -> PlayerInfo? { players.first { $0.id == id } }

    // MARK: Stations

    var taskStations: [MapStation] { stations.filter { $0.kind == .task } }
    var emergencyStation: MapStation? { stations.first { $0.kind == .emergency } }
    /// One emergency station per scanned room.
    var emergencyStations: [MapStation] { stations.filter { $0.kind == .emergency } }
    /// The fix station that repairs the active sabotage; any fix station while nothing is wrong.
    var fixStation: MapStation? {
        if let id = activeSabotage?.fixStationId, let target = stations.first(where: { $0.id == id }) { return target }
        return stations.first { $0.kind == .fix }
    }
    /// One name per scanned room, written on the room's first playable tile in shared tile coordinates. Empty
    /// unless there are at least two rooms.
    var roomLabels: [(name: String, tile: MapTile)] {
        guard zones.count > 1 else { return [] }
        return zones.compactMap { zone in
            guard let first = zone.grid.playable.min(by: { ($0.y, $0.x) < ($1.y, $1.x) }) else { return nil }
            return (zone.name, MapTile(x: first.x + zone.offset.x, y: first.y + zone.offset.y))
        }
    }

    /// True while the comms jammer is on: the map goes dark and reports and meetings are off.
    var isJammed: Bool { activeSabotage?.kind == .jammer }
    /// The meltdown countdown, when one is running.
    var meltdown: SabotageState? { activeSabotage?.kind == .meltdown ? activeSabotage : nil }

    /// The task station the player stands on, if any.
    var taskStationHere: MapStation? {
        guard let myTile else { return nil }
        return taskStations.first { $0.tile == myTile }
    }

    var onEmergencyTile: Bool { myTile != nil && emergencyStations.contains { $0.tile == myTile } }
    var onFixTile: Bool { myTile != nil && fixStation?.tile == myTile }

    var canDoTaskHere: Bool { taskStationHere.map(canDoTask(at:)) ?? false }

    /// Tasks are interrupted by sabotage, death, or leaving the playing phase, even off tile.
    var canAttemptTasks: Bool { role == .crew && isAlive && !lightsOut && phase == .playing }

    /// Reports and emergency meetings are off while the jammer or a meltdown is active.
    var meetingsBlocked: Bool { isJammed || meltdown != nil }

    func canDoTask(at station: MapStation) -> Bool {
        canAttemptTasks
            && station.kind == .task && station.tile == myTile
            && !completedStationIDs.contains(station.id)
    }

    var canCallEmergency: Bool {
        isAlive && phase == .playing && !emergencyUsed && onEmergencyTile && !meetingsBlocked
    }

    var canFixHere: Bool {
        role == .crew && isAlive && phase == .playing && activeSabotage != nil && onFixTile
    }

    // MARK: Bodies and kills

    /// Dead players whose phones lie on this tile and whose meeting has not happened yet.
    var bodiesHere: [PlayerInfo] {
        guard let myTile else { return [] }
        return players.filter { !$0.alive && $0.id != myID && $0.tile == myTile && !reportedBodyIDs.contains($0.id) }
    }

    var canReportHere: Bool { isAlive && phase == .playing && !bodiesHere.isEmpty && !meetingsBlocked }

    /// The Medic can revive a body on this tile, once.
    var canReviveHere: Bool {
        role == .crew && power == .medic && isAlive && phase == .playing && !reviveUsed && !bodiesHere.isEmpty
    }

    /// The Scout can ping (the server enforces the two uses and the cooldown).
    var canScout: Bool { role == .crew && power == .scout && isAlive && phase == .playing }

    /// The impostors on my team, other than me. Empty unless I am an impostor.
    var partnerPlayers: [PlayerInfo] { partners.compactMap { id in players.first { $0.id == id } } }

    /// Living players sharing the impostor's tile. The server also checks the victim is crew.
    var killTargetsHere: [PlayerInfo] {
        guard role == .impostor, isAlive, phase == .playing, let myTile else { return [] }
        return players.filter { $0.id != myID && $0.alive && $0.tile == myTile }
    }

    func killCooldownRemaining(at now: Date) -> TimeInterval {
        max(0, killCooldownEndsAt?.timeIntervalSince(now) ?? 0)
    }

    // MARK: Meeting

    /// Everyone alive except me, in lobby order.
    var voteCandidates: [PlayerInfo] { players.filter { $0.alive && $0.id != myID } }

    var winner: Winner? { lastResult?.winner }

    var didWin: Bool? {
        guard let winner, let role else { return nil }
        return (winner == .crew) == (role == .crew)
    }
}
