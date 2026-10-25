import Foundation

// Shared wire models. Field names and raw values match docs/architecture.md ("Shared models")
// and the implemented server (server/rooms.js, server/game.js). Do not rename fields here
// without updating the doc and telling the other owners.

struct Tile: Codable, Hashable {
    var x: Int
    var y: Int
}

/// 1.0 m tiles on the floor plane. `blocked` is what the current server validates. The optional
/// fields are the scan-derived layout from docs/architecture.md and are absent from older servers.
struct Grid: Codable, Hashable {
    var cols: Int
    var rows: Int
    var tileSize: Double
    var blocked: [Tile]
    var originX: Double?
    var originZ: Double?
    var playable: [Tile]?
    var edge: [Tile]?

    init(cols: Int, rows: Int, tileSize: Double = 1.0, blocked: [Tile] = [],
         originX: Double? = nil, originZ: Double? = nil, playable: [Tile]? = nil, edge: [Tile]? = nil) {
        self.cols = cols
        self.rows = rows
        self.tileSize = tileSize
        self.blocked = blocked
        self.originX = originX
        self.originZ = originZ
        self.playable = playable
        self.edge = edge
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        tileSize = try c.decode(Double.self, forKey: .tileSize)
        blocked = try c.decodeIfPresent([Tile].self, forKey: .blocked) ?? []
        originX = try c.decodeIfPresent(Double.self, forKey: .originX)
        originZ = try c.decodeIfPresent(Double.self, forKey: .originZ)
        playable = try c.decodeIfPresent([Tile].self, forKey: .playable)
        edge = try c.decodeIfPresent([Tile].self, forKey: .edge)
    }
}

enum TaskType: String, Codable, Hashable {
    case shake, tilt, dial, hold, gesture
}

enum StationKind: String, Codable, Hashable {
    case task, fix, emergency
}

struct Station: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var tile: Tile
    var task: TaskType
    var kind: StationKind
}

enum Role: String, Codable, Hashable {
    case crew, impostor
}

enum Phase: String, Codable, Hashable {
    case lobby, playing, meeting, ended
}

enum TileSource: String, Codable, Hashable {
    case ar, manual
}

struct Player: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var tile: Tile?
    var alive: Bool
    var tileSource: TileSource
    var ready: Bool
    var connected: Bool
}

enum MeetingReason: String, Codable, Hashable {
    case report, emergency
}

/// `votes` maps voter id to a player id or the literal string "skip".
struct MeetingState: Codable, Hashable {
    static let skip = "skip"

    var reason: MeetingReason
    var bodyOf: String?
    /// Epoch milliseconds.
    var endsAt: Int
    var votes: [String: String]
}

struct GameState: Codable, Hashable {
    var phase: Phase
    var players: [Player]
    var tasksDone: Int
    var tasksTotal: Int
    var lightsOut: Bool
    /// Epoch milliseconds.
    var killCooldownEndsAt: Int?
    var meeting: MeetingState?
}

/// One object found by the scan detector. `box` is `[x, y, w, h]`, normalized 0-1 image coordinates.
struct DetectedObject: Codable, Hashable {
    var label: String
    var box: [Double]
}
