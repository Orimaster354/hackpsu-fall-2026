import Foundation

/// A room shaped the way a scanned room is: not a rectangle. Task stations sit on edge tiles at
/// least 2 tiles apart, the emergency tile is the playable tile nearest the center (docs, "Server
/// scan processing"). This is the mock's stand-in for the server's `setup` message.
enum MockFixture {
    static func room() -> (grid: MapGrid, stations: [MapStation]) {
        let cols = 7
        let rows = 6
        var playable = Set<MapTile>()
        for y in 0..<rows {
            for x in 0..<cols where !(x >= 5 && y <= 1) { playable.insert(MapTile(x: x, y: y)) }
        }
        let edge = playable.filter { tile in
            [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { !playable.contains(MapTile(x: tile.x + $0.0, y: tile.y + $0.1)) }
        }
        let grid = MapGrid(cols: cols, rows: rows, playable: playable, edge: edge)

        let cx = playable.map { Double($0.x) + 0.5 }.reduce(0, +) / Double(playable.count)
        let cy = playable.map { Double($0.y) + 0.5 }.reduce(0, +) / Double(playable.count)
        let center = playable.sorted().min {
            hypot(Double($0.x) + 0.5 - cx, Double($0.y) + 0.5 - cy) < hypot(Double($1.x) + 0.5 - cx, Double($1.y) + 0.5 - cy)
        } ?? MapTile(x: 3, y: 3)

        let stations = [
            MapStation(id: "s1", name: "Kitchen counter", tile: MapTile(x: 0, y: 2), task: .hold, kind: .task),
            MapStation(id: "s2", name: "Sofa", tile: MapTile(x: 3, y: 0), task: .tilt, kind: .task),
            MapStation(id: "s3", name: "Front door", tile: MapTile(x: 6, y: 3), task: .dial, kind: .task),
            MapStation(id: "s4", name: "Desk", tile: MapTile(x: 4, y: 5), task: .shake, kind: .task),
            MapStation(id: "s5", name: "Bookshelf", tile: MapTile(x: 0, y: 5), task: .gesture, kind: .task),
            MapStation(id: "f1", name: "Breaker box", tile: MapTile(x: 6, y: 5), task: .hold, kind: .fix),
            MapStation(id: "e1", name: "Meeting spot", tile: center, task: .hold, kind: .emergency),
        ]
        return (grid, stations)
    }
}

/// Puts a mock session on a given screen without waiting for the flow to get there.
enum MockScenario: String {
    // Before a game
    case home, join, scanning, waiting, needsSetup, ready, readyGuest, starting
    // Role reveal
    case crew, impostor
    // Playing
    case hud, hudNoTile, hudBody, hudEmergency, hudImpostor, hudImpostorCooling, lights, ghost
    // Meeting and after
    case meeting, ejected, endCrew, endImpostor

    func apply(to session: GameSession) {
        let room = MockFixture.room()
        let names = ["Alex", "Nova", "Pixel", "Orbit"]
        func id(_ name: String) -> String { name == "Alex" ? "p-me" : "p-\(name.lowercased())" }
        func players(_ list: [String], tiles: [String: MapTile] = [:], dead: Set<String> = []) -> [PlayerInfo] {
            list.map { PlayerInfo(id: id($0), name: $0, tile: tiles[$0], alive: !dead.contains($0)) }
        }
        func enterLobby(_ list: [String], withSetup: Bool) {
            session.receive(.joined(playerID: "p-me", room: "KQMR"))
            session.receive(.lobby(players: players(list), grid: withSetup ? room.grid : nil, stations: withSetup ? room.stations : [], hasMap: withSetup))
        }
        func play(role: PlayerRole, phase: GamePhase = .playing, tiles: [String: MapTile], dead: Set<String> = [],
                  tasks: (done: Int, total: Int) = (4, 15), lights: Bool = false, cooldown: TimeInterval? = nil, meeting: MeetingInfo? = nil) {
            enterLobby(names, withSetup: true)
            session.receive(.role(role))
            session.receive(.state(GameSnapshot(
                phase: phase, players: players(names, tiles: tiles, dead: dead),
                tasksDone: tasks.done, tasksTotal: tasks.total, lightsOut: lights,
                killCooldownEndsAt: cooldown.map { Date().addingTimeInterval($0) }, meeting: meeting)))
            session.acknowledgeRole()
        }
        let spread = ["Alex": MapTile(x: 3, y: 0), "Nova": MapTile(x: 0, y: 2), "Pixel": MapTile(x: 6, y: 3), "Orbit": MapTile(x: 4, y: 5)]

        switch self {
        case .home, .join:
            break
        case .scanning:
            enterLobby(["Alex"], withSetup: false)
            session.receive(.processing(.gemini))
        case .waiting:
            enterLobby(["Alex", "Nova"], withSetup: false)
            session.receive(.setup(grid: room.grid, stations: room.stations))
        case .needsSetup:
            enterLobby(names, withSetup: false)
            session.receive(.setup(grid: room.grid, stations: room.stations))
        case .ready:
            enterLobby(names, withSetup: false)
            session.receive(.setup(grid: room.grid, stations: room.stations))
            session.confirmSetup()
        case .readyGuest:
            session.receive(.joined(playerID: "p-me", room: "KQMR"))
            session.receive(.lobby(players: players(["Nova", "Pixel", "Alex", "Orbit"]), grid: room.grid, stations: room.stations, hasMap: true))
        case .starting:
            enterLobby(names, withSetup: false)
            session.receive(.setup(grid: room.grid, stations: room.stations))
            session.confirmSetup()
            session.receive(.state(GameSnapshot(phase: .playing, players: players(names), tasksDone: 0, tasksTotal: 15, lightsOut: false, killCooldownEndsAt: nil, meeting: nil)))
        case .crew, .impostor:
            enterLobby(names, withSetup: true)
            session.receive(.role(self == .impostor ? .impostor : .crew))
            session.receive(.state(GameSnapshot(phase: .playing, players: players(names, tiles: spread), tasksDone: 0, tasksTotal: 15, lightsOut: false, killCooldownEndsAt: nil, meeting: nil)))
        case .hud:
            play(role: .crew, tiles: spread)
        case .hudNoTile:
            play(role: .crew, tiles: spread.filter { $0.key != "Alex" })
        case .hudBody:
            let here = MapTile(x: 2, y: 2)
            play(role: .crew, tiles: ["Alex": here, "Pixel": here, "Nova": MapTile(x: 0, y: 2), "Orbit": MapTile(x: 4, y: 5)], dead: ["Pixel"], tasks: (3, 10))
        case .hudEmergency:
            play(role: .crew, tiles: spread.merging(["Alex": room.stations[6].tile]) { $1 })
        case .hudImpostor:
            let here = MapTile(x: 6, y: 3)
            play(role: .impostor, tiles: ["Alex": here, "Pixel": here, "Nova": MapTile(x: 0, y: 2), "Orbit": MapTile(x: 4, y: 5)])
        case .hudImpostorCooling:
            let here = MapTile(x: 6, y: 3)
            play(role: .impostor, tiles: ["Alex": here, "Pixel": here, "Nova": MapTile(x: 0, y: 2), "Orbit": MapTile(x: 4, y: 5)], cooldown: 14)
        case .lights:
            play(role: .crew, tiles: spread.merging(["Alex": MapTile(x: 5, y: 5)]) { $1 }, lights: true)
        case .ghost:
            play(role: .crew, tiles: spread.merging(["Alex": MapTile(x: 2, y: 2)]) { $1 }, dead: ["Alex"], tasks: (3, 10))
        case .meeting:
            let info = MeetingInfo(reason: .report, bodyOf: id("Pixel"), endsAt: Date().addingTimeInterval(21),
                                   votes: [id("Nova"): .skip, id("Orbit"): .player(id("Nova"))])
            play(role: .crew, phase: .meeting, tiles: spread, dead: ["Pixel"], tasks: (3, 10), meeting: info)
        case .ejected:
            play(role: .crew, tiles: spread, dead: ["Nova"], tasks: (3, 10))
            session.receive(.meeting(MeetingInfo(reason: .emergency, bodyOf: nil, endsAt: Date().addingTimeInterval(1), votes: [:])))
            session.receive(.result(MeetingResult(ejected: id("Nova"), role: .crew, winner: nil)))
            session.receive(.state(GameSnapshot(phase: .playing, players: players(names, tiles: spread, dead: ["Nova"]), tasksDone: 3, tasksTotal: 10, lightsOut: false, killCooldownEndsAt: nil, meeting: nil)))
        case .endCrew:
            play(role: .crew, phase: .meeting, tiles: spread, dead: ["Pixel"], tasks: (3, 10),
                 meeting: MeetingInfo(reason: .report, bodyOf: id("Pixel"), endsAt: Date().addingTimeInterval(1), votes: [:]))
            session.receive(.result(MeetingResult(ejected: id("Orbit"), role: .impostor, winner: .crew)))
            session.receive(.state(GameSnapshot(phase: .ended, players: players(names, tiles: spread, dead: ["Pixel", "Orbit"]), tasksDone: 3, tasksTotal: 6, lightsOut: false, killCooldownEndsAt: nil, meeting: nil)))
            session.acknowledgeResult()
        case .endImpostor:
            play(role: .impostor, tiles: spread, dead: ["Pixel", "Orbit"], tasks: (2, 5))
            session.receive(.result(MeetingResult(ejected: nil, role: nil, winner: .impostor)))
            session.receive(.state(GameSnapshot(phase: .ended, players: players(names, tiles: spread, dead: ["Pixel", "Orbit"]), tasksDone: 2, tasksTotal: 5, lightsOut: false, killCooldownEndsAt: nil, meeting: nil)))
        }
    }
}

extension GameSession {
    /// A session wired to a `MockServer`. `role` forces the role the mock deals you, `fast` shortens
    /// every wait and timer so a whole round fits in a minute.
    static func mock(_ scenario: MockScenario = .home, role: PlayerRole? = nil, fast: Bool = false, seed: UInt64? = nil) -> GameSession {
        var config = MockServer.Config(myRole: role, seed: seed)
        if fast {
            config.latency = .milliseconds(120)
            config.botJoinInterval = .milliseconds(350)
            config.scanStepDelay = .milliseconds(250)
            config.tick = .milliseconds(200)
            config.rules.killCooldown = 8
            config.rules.meetingLength = 14
            config.rules.sabotageCooldown = 12
        }
        let session = GameSession()
        MockServer(config: config).attach(to: session)
        scenario.apply(to: session)
        return session
    }
}

/// Presentation state a preview or screenshot can ask for on top of a scenario.
struct ScreenPreview: Equatable {
    var roleRevealed = false
    var setupReview = false
    var positionSheet = false
}

/// Launch arguments for simulator screenshots, for example
/// `xcrun simctl launch booted <bundle id> -mockScenario hudImpostor -mockPosition ar`.
/// Scenario names are the cases of `MockScenario`.
struct MockLaunch {
    var scenario: MockScenario = .home
    var role: PlayerRole?
    var fast = false
    /// Repeats the same mock game: who the impostor is, where the bots go.
    var seed: UInt64?
    var preview = ScreenPreview()
    var position: MockPositionMode = .manual

    static var current: MockLaunch {
        #if DEBUG
        let defaults = UserDefaults.standard
        let sheet = defaults.string(forKey: "mockSheet")
        return MockLaunch(
            scenario: defaults.string(forKey: "mockScenario").flatMap(MockScenario.init(rawValue:)) ?? .home,
            role: defaults.string(forKey: "mockRole").flatMap(PlayerRole.init(rawValue:)),
            fast: defaults.bool(forKey: "mockFast"),
            seed: defaults.object(forKey: "mockSeed") == nil ? nil : UInt64(max(0, defaults.integer(forKey: "mockSeed"))),
            preview: ScreenPreview(
                roleRevealed: defaults.bool(forKey: "mockRevealed"),
                setupReview: sheet == "setup",
                positionSheet: sheet == "position"
            ),
            position: defaults.string(forKey: "mockPosition").flatMap(MockPositionMode.init(rawValue:)) ?? .manual
        )
        #else
        MockLaunch()
        #endif
    }
}

/// Which position source the mock app starts with. `ar` and `arFail` use `MockARProvider`.
enum MockPositionMode: String {
    case manual, ar, arFail
}
