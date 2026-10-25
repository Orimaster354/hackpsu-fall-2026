import Foundation

// UI-side shapes for the screens. They mirror the models in docs/architecture.md but carry
// distinct names (MapTile, PlayerInfo, MapGrid, MapStation, GameSnapshot) so they do not collide
// with `MyApp/Models`. The integration layer maps wire models onto these and calls
// `GameSession.receive(_:)`, so the views do not change.
//
// TileSource, StationKind, MeetingReason and Winner are not declared here. They are plain enums
// of wire strings, and `MyApp/Models` already defines them with the same cases, so the UI uses those.
//
// Gaps in docs/architecture.md found while building this:
//  - `lobby` has no host id, so the host is taken to be players[0], the creator.
//  - There is no `ready` intent, so "ready" is derived from the player count.
//  - There is no `leave` intent, so leaving only resets the client and disconnects.
//  - `error` codes are not listed. The codes used by the mock are placeholders.
//  - Nothing tells a client that setup is confirmed. The host treats its own `confirmSetup` as
//    confirmed until a new `setup` arrives.
//  - `GameState` has no per-player task completion and no emergency usage. The client keeps its own.
//  - `GameState` has no server time, so countdowns compare `endsAt` with the phone clock.
//  - `result` names no impostor for a win by kills or tasks, so the end screen cannot reveal them.

/// A cell on the room grid. docs: `Tile { x, y }`, y runs along the floor's z axis.
struct MapTile: Hashable, Comparable {
    var x: Int
    var y: Int

    static func < (a: MapTile, b: MapTile) -> Bool { (a.y, a.x) < (b.y, b.x) }
}

/// docs: `Player`.
struct PlayerInfo: Identifiable, Hashable {
    let id: String
    var name: String
    var tile: MapTile?
    var alive: Bool
    var tileSource: TileSource
    /// Lobby readiness from the server. Advisory: it is not an extra start requirement.
    var ready: Bool
    /// False while the player's socket is down. A disconnected player keeps their seat.
    var connected: Bool

    init(id: String, name: String, tile: MapTile? = nil, alive: Bool = true, tileSource: TileSource = .manual,
         ready: Bool = false, connected: Bool = true) {
        self.id = id
        self.name = name
        self.tile = tile
        self.alive = alive
        self.tileSource = tileSource
        self.ready = ready
        self.connected = connected
    }
}

/// docs: `Grid`. `edge` is a subset of `playable`.
struct MapGrid: Equatable {
    var cols: Int
    var rows: Int
    var tileSize = 1.0
    var originX = 0.0
    var originZ = 0.0
    var playable: Set<MapTile>
    var edge: Set<MapTile>

    func contains(_ tile: MapTile) -> Bool { playable.contains(tile) }

    /// World position (x, z) of a tile's center. docs, AR view: `originX + (x + 0.5)`.
    func worldCenter(of tile: MapTile) -> (x: Double, z: Double) {
        (originX + (Double(tile.x) + 0.5) * tileSize, originZ + (Double(tile.y) + 0.5) * tileSize)
    }

    /// The tile under a world position. docs, positioning: `floor((pos - origin) / 1.0)`.
    /// It may fall outside `playable`, and the server decides what to do with that.
    func tile(atX x: Double, z: Double) -> MapTile {
        MapTile(
            x: Int(((x - originX) / tileSize).rounded(.down)),
            y: Int(((z - originZ) / tileSize).rounded(.down))
        )
    }
}

/// docs: `TaskType`. Raw values are the wire strings.
enum TaskKind: String, CaseIterable {
    case shake, tilt, dial, hold, gesture
}

/// docs: `Station`.
struct MapStation: Identifiable, Hashable {
    let id: String
    var name: String
    var tile: MapTile
    var task: TaskKind
    var kind: StationKind
}

/// Raw values are the wire strings.
enum PlayerRole: String {
    case crew, impostor
}

/// Raw values are the wire strings.
enum GamePhase: String {
    case lobby, playing, meeting, ended
}

/// A vote target: a player id, or "skip" on the wire.
enum Vote: Hashable {
    case player(String)
    case skip
}

/// docs: `MeetingState`. `endsAt` is epoch ms on the wire.
struct MeetingInfo: Equatable {
    var reason: MeetingReason
    var bodyOf: String?
    var endsAt: Date
    var votes: [String: Vote]
}

/// docs: server to client `result`.
struct MeetingResult: Equatable {
    var ejected: String?
    var role: PlayerRole?
    var winner: Winner?
}

/// docs: `GameState`. Times are `Date`, converted from epoch ms by the integration layer.
struct GameSnapshot: Equatable {
    var phase: GamePhase
    var players: [PlayerInfo]
    var tasksDone: Int
    var tasksTotal: Int
    var lightsOut: Bool
    var killCooldownEndsAt: Date?
    var meeting: MeetingInfo?
}

/// docs: server to client `processing` step.
enum SetupStep: String {
    case polygon, gemini, placing
}

struct SessionError: Equatable {
    let code: String
    let message: String

    static let timeout = SessionError(
        code: "timeout",
        message: "The server did not answer. Check the server address in Settings."
    )
}

/// Client to server. Case names follow the `t` values in docs/architecture.md.
enum ClientIntent: Equatable {
    case create(name: String)
    case join(room: String, name: String)
    case ready(Bool)
    case editStation(MapStation)
    case deleteStation(id: String)
    case confirmSetup
    case start
    case tile(MapTile, source: TileSource)
    case taskDone(stationID: String)
    case kill(targetID: String)
    case report(bodyID: String)
    case emergency
    case vote(Vote)
    case sabotage
    case fix(stationID: String)
}

/// Server to client. Case names follow the `t` values in docs/architecture.md.
enum ServerEvent: Equatable {
    case joined(playerID: String, room: String)
    case lobby(players: [PlayerInfo], grid: MapGrid?, stations: [MapStation], hasMap: Bool)
    case processing(SetupStep)
    case setup(grid: MapGrid, stations: [MapStation])
    /// The server's `setupConfirmed` flag, sent by the network adapter right after each `lobby` and
    /// `setup`. The mock does not send it, so the session's local assumption still applies there.
    case setupStatus(confirmed: Bool)
    case role(PlayerRole)
    case state(GameSnapshot)
    case killed
    case meeting(MeetingInfo)
    case result(MeetingResult)
    case error(SessionError)
}

enum RoomCode {
    static let length = 4

    /// Uppercases and keeps ASCII letters only, capped at `length`. Safe to call on every keystroke.
    static func clamp(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(length))
    }

    static func isValid(_ code: String) -> Bool {
        code.count == length && clamp(code) == code
    }
}

enum PlayerName {
    static let maxLength = 12

    /// Caps the length only, so a space can still be typed between two words.
    static func clamp(_ raw: String) -> String {
        String(raw.prefix(maxLength))
    }

    /// What gets sent to the server.
    static func normalized(_ raw: String) -> String {
        clamp(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isValid(_ name: String) -> Bool {
        !normalized(name).isEmpty
    }
}

/// `UserDefaults` keys shared by the settings and lobby screens. The network client reads
/// `serverAddress` (host or host:port, as typed by the user).
enum SettingsKey {
    static let playerName = "playerName"
    static let serverAddress = "serverAddress"
    /// Testing aid in manual mode: draw every player on the map.
    static let showEveryone = "showEveryone"
}
