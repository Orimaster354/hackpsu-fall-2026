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
    var fixStation: MapStation? { stations.first { $0.kind == .fix } }

    /// The task station the player stands on, if any.
    var taskStationHere: MapStation? {
        guard let myTile else { return nil }
        return taskStations.first { $0.tile == myTile }
    }

    var onEmergencyTile: Bool { myTile != nil && emergencyStation?.tile == myTile }
    var onFixTile: Bool { myTile != nil && fixStation?.tile == myTile }

    var canDoTaskHere: Bool { taskStationHere.map(canDoTask(at:)) ?? false }

    func canDoTask(at station: MapStation) -> Bool {
        role == .crew && isAlive && !lightsOut && phase == .playing
            && station.kind == .task && station.tile == myTile
            && !completedStationIDs.contains(station.id)
    }

    var canCallEmergency: Bool {
        isAlive && phase == .playing && !emergencyUsed && onEmergencyTile
    }

    var canFixHere: Bool {
        role == .crew && isAlive && phase == .playing && lightsOut && onFixTile
    }

    // MARK: Bodies and kills

    /// Dead players whose phones lie on this tile and whose meeting has not happened yet.
    var bodiesHere: [PlayerInfo] {
        guard let myTile else { return [] }
        return players.filter { !$0.alive && $0.id != myID && $0.tile == myTile && !reportedBodyIDs.contains($0.id) }
    }

    var canReportHere: Bool { isAlive && phase == .playing && !bodiesHere.isEmpty }

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
