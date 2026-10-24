import Foundation

/// Stand-in for the Node server until Net and the backend are ready. It answers the same intents
/// with the same events after a short delay, and adds bot players so one simulator can walk the
/// whole lobby flow. Error codes are placeholders, see the gaps note in SessionModels.swift.
final class MockServer {
    struct Config {
        var latency: Duration = .milliseconds(450)
        var botJoinInterval: Duration = .milliseconds(1100)
        /// nil picks at random, 1 impostor in 4.
        var myRole: PlayerRole?
    }

    /// Joining this code lands you in a room with a host and one other player. The host starts the
    /// game once the fourth player arrives. `fullRoom` and `startedRoom` fail, anything else is unknown.
    static let joinableRoom = "ABCD"
    static let fullRoom = "FULL"
    static let startedRoom = "LIVE"

    private static let botNames = ["Nova", "Pixel", "Orbit", "Comet"]
    private static let myID = "p-me"

    private weak var session: GameSession?
    private let config: Config
    private var roster: [LobbyPlayer] = []
    private var generation = 0
    private var botTask: Task<Void, Never>?

    init(config: Config = Config()) {
        self.config = config
    }

    func attach(to session: GameSession) {
        self.session = session
        session.transportName = "Mock server (no network)"
        session.send = { [self] in handle($0) }
        session.disconnect = { [self] in
            generation += 1
            botTask?.cancel()
        }
    }

    private func handle(_ intent: ClientIntent) {
        let sentIn = generation
        Task { [self] in
            try? await Task.sleep(for: config.latency)
            guard sentIn == generation else { return }
            switch intent {
            case let .create(name): create(name: name)
            case let .join(room, name): join(room: room, name: name)
            case .start: start()
            }
        }
    }

    private func create(name: String) {
        roster = [LobbyPlayer(id: Self.myID, name: name)]
        deliver(.joined(playerID: Self.myID, room: Self.randomCode()))
        deliver(.lobby(players: roster))
        addBots(hostStartsWhenFull: false)
    }

    private func join(room: String, name: String) {
        switch room {
        case Self.joinableRoom:
            roster = [bot("Nova"), bot("Pixel"), LobbyPlayer(id: Self.myID, name: name)]
            deliver(.joined(playerID: Self.myID, room: room))
            deliver(.lobby(players: roster))
            addBots(hostStartsWhenFull: true)
        case Self.fullRoom:
            deliver(.error(SessionError(code: "room_full", message: "That room is full.")))
        case Self.startedRoom:
            deliver(.error(SessionError(code: "game_started", message: "That game has already started.")))
        default:
            deliver(.error(SessionError(code: "room_not_found", message: "No room with code \(room).")))
        }
    }

    private func start() {
        guard roster.count >= GameSession.requiredPlayers else {
            deliver(.error(SessionError(code: "not_enough_players", message: "You need 4 players to start.")))
            return
        }
        startRound()
    }

    private func startRound() {
        let role = config.myRole ?? [.crew, .crew, .crew, .impostor].randomElement() ?? .crew
        deliver(.role(role))
        deliver(.state(phase: .playing))
    }

    private func addBots(hostStartsWhenFull: Bool) {
        botTask?.cancel()
        let startedIn = generation
        botTask = Task { [self] in
            while roster.count < GameSession.requiredPlayers {
                try? await Task.sleep(for: config.botJoinInterval)
                guard !Task.isCancelled, startedIn == generation else { return }
                guard let name = Self.botNames.first(where: { name in !roster.contains { $0.name == name } }) else { return }
                roster.append(bot(name))
                deliver(.lobby(players: roster))
            }
            guard hostStartsWhenFull else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, startedIn == generation else { return }
            startRound()
        }
    }

    private func bot(_ name: String) -> LobbyPlayer {
        LobbyPlayer(id: "p-\(name.lowercased())", name: name)
    }

    private func deliver(_ event: ServerEvent) {
        session?.receive(event)
    }

    private static func randomCode() -> String {
        String((0..<RoomCode.length).compactMap { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ".randomElement() })
    }
}

// MARK: - Fast-forward for previews and screenshots

/// Puts a mock session on a given screen without waiting for the flow to get there.
enum MockScenario: String {
    case home, join, waiting, ready, readyGuest, starting, crew, impostor, playing

    func apply(to session: GameSession) {
        let me = "Alex"
        func players(_ names: [String]) -> [LobbyPlayer] {
            names.map { LobbyPlayer(id: $0 == me ? "p-me" : "p-\($0.lowercased())", name: $0) }
        }
        func enter(_ names: [String]) {
            session.receive(.joined(playerID: "p-me", room: "KQMR"))
            session.receive(.lobby(players: players(names)))
        }
        let full = [me, "Nova", "Pixel", "Orbit"]

        switch self {
        case .home, .join:
            break
        case .waiting:
            enter([me, "Nova"])
        case .ready:
            enter(full)
        case .readyGuest:
            enter(["Nova", "Pixel", me, "Orbit"])
        case .starting:
            enter(full)
            session.receive(.state(phase: .playing))
        case .crew, .impostor, .playing:
            enter(full)
            session.receive(.role(self == .impostor ? .impostor : .crew))
            session.receive(.state(phase: .playing))
            if self == .playing { session.acknowledgeRole() }
        }
    }
}

extension GameSession {
    /// A session wired to a `MockServer`. `role` forces the role the mock deals you.
    static func mock(_ scenario: MockScenario = .home, role: PlayerRole? = nil) -> GameSession {
        let session = GameSession()
        MockServer(config: MockServer.Config(myRole: role)).attach(to: session)
        scenario.apply(to: session)
        return session
    }
}

/// Launch arguments for simulator screenshots:
/// `xcrun simctl launch booted <bundle id> -mockScenario impostor -mockRevealed YES`
struct MockLaunch {
    var scenario: MockScenario = .home
    var role: PlayerRole?
    var revealed = false

    static var current: MockLaunch {
        #if DEBUG
        let defaults = UserDefaults.standard
        return MockLaunch(
            scenario: defaults.string(forKey: "mockScenario").flatMap(MockScenario.init(rawValue:)) ?? .home,
            role: defaults.string(forKey: "mockRole").flatMap(PlayerRole.init(rawValue:)),
            revealed: defaults.bool(forKey: "mockRevealed")
        )
        #else
        MockLaunch()
        #endif
    }
}
