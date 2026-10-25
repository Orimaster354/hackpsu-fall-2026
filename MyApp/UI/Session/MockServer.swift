import Foundation

/// Stand-in for the Node server until Net and the backend are ready. It answers the same intents
/// with the same events, after a short delay, adds bot players, pretends to process a room scan,
/// and runs the documented game rules (`MockGame`) so one simulator can play a whole round.
/// Error codes are placeholders, see the gaps note in SessionModels.swift.
final class MockServer {
    struct Config {
        /// `.zero` makes everything synchronous, which is what the tests want.
        var latency: Duration = .milliseconds(450)
        var botJoinInterval: Duration = .milliseconds(1100)
        var scanStepDelay: Duration = .milliseconds(700)
        var tick: Duration = .milliseconds(250)
        /// nil picks at random, 1 impostor in 4.
        var myRole: PlayerRole?
        var rules = MockGame.Rules()
        var seed: UInt64?
        /// false: nothing runs on its own and the caller drives `step(now:)`.
        var runsLoop = true
    }

    /// Joining this code lands you in a room with a host and one other player. The host starts the
    /// game once the fourth player arrives. `fullRoom` and `startedRoom` fail, anything else is unknown.
    static let joinableRoom = "ABCD"
    static let fullRoom = "FULL"
    static let startedRoom = "LIVE"
    static let myID = "p-me"

    private static let botNames = ["Nova", "Pixel", "Orbit", "Comet"]

    /// Tests replace this to control time.
    var clock: () -> Date = { Date() }

    private weak var session: GameSession?
    private let config: Config
    private var rng: MockRandom
    private var roster: [PlayerInfo] = []
    private var grid: MapGrid?
    private var stations: [MapStation] = []
    private var setupConfirmed = false
    /// Readable so tests can watch the world. Only the server mutates it.
    private(set) var game: MockGame?
    private var generation = 0
    private var fillTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?

    init(config: Config = Config()) {
        self.config = config
        rng = MockRandom(seed: config.seed)
    }

    func attach(to session: GameSession) {
        self.session = session
        session.transportName = "Mock server (no network)"
        session.send = { [self] in handle($0) }
        session.disconnect = { [self] in reset() }
    }

    // MARK: Intents

    private func handle(_ intent: ClientIntent) {
        guard config.latency > .zero else { process(intent); return }
        let sentIn = generation
        Task { [self] in
            try? await Task.sleep(for: config.latency)
            guard sentIn == generation else { return }
            process(intent)
        }
    }

    private func process(_ intent: ClientIntent) {
        switch intent {
        case let .create(name): create(name: name)
        case let .join(room, name): join(room: room, name: name)
        case let .editStation(station): editStation(station)
        case let .deleteStation(id): deleteStation(id)
        case .confirmSetup: setupConfirmed = true
        case .start: start()
        default: play(intent)
        }
    }

    private func create(name: String) {
        reset()
        roster = [PlayerInfo(id: Self.myID, name: name)]
        deliver(.joined(playerID: Self.myID, room: Self.randomCode()))
        deliver(lobbyEvent())
        scan()
        addBots(hostStartsWhenFull: false)
    }

    private func join(room: String, name: String) {
        switch room {
        case Self.joinableRoom:
            reset()
            let fixture = MockFixture.room()
            grid = fixture.grid
            stations = fixture.stations
            setupConfirmed = true
            roster = [PlayerInfo(id: "p-nova", name: "Nova"), PlayerInfo(id: "p-pixel", name: "Pixel"), PlayerInfo(id: Self.myID, name: name)]
            deliver(.joined(playerID: Self.myID, room: room))
            deliver(lobbyEvent())
            addBots(hostStartsWhenFull: true)
        case Self.fullRoom:
            deliver(.error(SessionError(code: "room_full", message: "That room is full.")))
        case Self.startedRoom:
            deliver(.error(SessionError(code: "game_started", message: "That game has already started.")))
        default:
            deliver(.error(SessionError(code: "room_not_found", message: "No room with code \(room).")))
        }
    }

    private func editStation(_ station: MapStation) {
        guard roster.first?.id == Self.myID else { deliver(notHost()); return }
        guard let grid, grid.edge.contains(station.tile) else {
            deliver(.error(SessionError(code: "not_edge_tile", message: "Stations go on edge tiles.")))
            return
        }
        if let index = stations.firstIndex(where: { $0.id == station.id }) {
            stations[index] = station
        } else {
            stations.append(station)
        }
        setupConfirmed = false
        deliver(.setup(grid: grid, stations: stations))
    }

    private func deleteStation(_ id: String) {
        guard roster.first?.id == Self.myID else { deliver(notHost()); return }
        guard let grid else { return }
        stations.removeAll { $0.id == id }
        setupConfirmed = false
        deliver(.setup(grid: grid, stations: stations))
    }

    private func start() {
        guard roster.count >= GameSession.requiredPlayers else {
            deliver(.error(SessionError(code: "not_enough_players", message: "You need 4 players to start.")))
            return
        }
        guard setupConfirmed else {
            deliver(.error(SessionError(code: "setup_not_confirmed", message: "Confirm the room setup first.")))
            return
        }
        startRound()
    }

    private func play(_ intent: ClientIntent) {
        guard var current = game else { return }
        let output = current.handle(intent, from: Self.myID, now: clock())
        game = current
        deliver(output)
    }

    // MARK: Lobby

    private func scan() {
        let startedIn = generation
        guard config.scanStepDelay > .zero else { finishScan(); return }
        Task { [self] in
            for step in [SetupStep.polygon, .gemini, .placing] {
                try? await Task.sleep(for: config.scanStepDelay)
                guard startedIn == generation else { return }
                deliver(.processing(step))
            }
            try? await Task.sleep(for: config.scanStepDelay)
            guard startedIn == generation else { return }
            finishScan()
        }
    }

    private func finishScan() {
        let fixture = MockFixture.room()
        grid = fixture.grid
        stations = fixture.stations
        setupConfirmed = false
        deliver(.setup(grid: fixture.grid, stations: fixture.stations))
    }

    private func addBots(hostStartsWhenFull: Bool) {
        fillTask?.cancel()
        guard config.botJoinInterval > .zero else {
            while roster.count < GameSession.requiredPlayers, addBot() {}
            if hostStartsWhenFull { startRound() }
            return
        }
        let startedIn = generation
        fillTask = Task { [self] in
            while roster.count < GameSession.requiredPlayers {
                try? await Task.sleep(for: config.botJoinInterval)
                guard !Task.isCancelled, startedIn == generation, addBot() else { return }
            }
            guard hostStartsWhenFull else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, startedIn == generation else { return }
            startRound()
        }
    }

    @discardableResult
    private func addBot() -> Bool {
        guard let name = Self.botNames.first(where: { name in !roster.contains { $0.name == name } }) else { return false }
        roster.append(PlayerInfo(id: "p-\(name.lowercased())", name: name))
        deliver(lobbyEvent())
        return true
    }

    private func lobbyEvent() -> ServerEvent {
        .lobby(players: roster, grid: grid, stations: stations, hasMap: grid != nil)
    }

    // MARK: Game

    private func startRound() {
        guard let grid, game == nil else { return }
        let ids = roster.map(\.id)
        let others = ids.filter { $0 != Self.myID }
        let impostor: String
        switch config.myRole {
        case .impostor?: impostor = Self.myID
        case .crew?: impostor = others.randomElement(using: &rng) ?? ids[0]
        case nil: impostor = ids.randomElement(using: &rng) ?? ids[0]
        }
        let now = clock()
        var started = MockGame(players: roster, impostors: [impostor], grid: grid, stations: stations, rules: config.rules, now: now)
        deliver(.role(impostor == Self.myID ? .impostor : .crew))
        deliver(.state(started.snapshot()))

        // Every bot takes a starting tile. The player starts with no tile and sets it themselves.
        var output: [MockGame.Output] = []
        let tiles = grid.playable.sorted()
        for id in others {
            guard let spot = tiles.randomElement(using: &rng) else { continue }
            output += started.handle(.tile(spot, source: .manual), from: id, now: now)
            output += started.handle(.tile(spot, source: .manual), from: id, now: now)
        }
        game = started
        deliver(output)
        startLoop()
    }

    private func startLoop() {
        guard config.runsLoop else { return }
        let startedIn = generation
        loopTask = Task { [self] in
            while !Task.isCancelled, startedIn == generation, game?.phase != .ended {
                try? await Task.sleep(for: config.tick)
                guard !Task.isCancelled, startedIn == generation else { return }
                step(now: clock())
            }
        }
    }

    /// One tick of the world: the meeting timer, then each bot's turn. The loop calls this, and
    /// tests call it directly with a clock they control.
    func step(now: Date) {
        guard var current = game, current.phase != .ended else { return }
        var output = current.tick(now: now)
        for bot in roster where bot.id != Self.myID {
            for intent in MockBots.intents(for: bot.id, in: current, now: now, tick: config.tick.seconds, rng: &rng) {
                output += current.handle(intent, from: bot.id, now: now)
            }
        }
        game = current
        deliver(output)
    }

    // MARK: Plumbing

    private func reset() {
        generation += 1
        fillTask?.cancel()
        loopTask?.cancel()
        roster = []
        grid = nil
        stations = []
        setupConfirmed = false
        game = nil
    }

    private func notHost() -> ServerEvent {
        .error(SessionError(code: "not_host", message: "Only the host can do that."))
    }

    private func deliver(_ event: ServerEvent) {
        session?.receive(event)
    }

    private func deliver(_ output: [MockGame.Output]) {
        for item in output where item.to == nil || item.to == Self.myID {
            session?.receive(item.event)
        }
    }

    private static func randomCode() -> String {
        String((0..<RoomCode.length).compactMap { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ".randomElement() })
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
