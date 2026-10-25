import Foundation

// Shared wire models. Field names and raw values match docs/architecture.md ("Shared models")
// and the implemented server (server/rooms.js, server/game.js). Do not rename fields here
// without updating the doc and telling the other owners.

nonisolated struct Tile: Codable, Hashable, Sendable {
    var x: Int
    var y: Int
}

/// 1.0 m tiles on the floor plane (x, z). `originX`/`originZ` are the world position of tile (0,0)'s corner in
/// the host's ARKit frame. `edge` is a subset of `playable`. Produced by the server; clients never send a grid.
struct Grid: Codable, Hashable {
    var cols: Int
    var rows: Int
    var tileSize: Double
    var originX: Double
    var originZ: Double
    var playable: [Tile]
    var edge: [Tile]
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
