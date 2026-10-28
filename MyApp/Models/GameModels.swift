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
    case shake, tilt, dial, hold, gesture, hammer, orbs, signal
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

/// A special ability held by one crew member each. Private: it is sent only to its holder.
enum Power: String, Codable, Hashable, CaseIterable {
    /// Revives a freshly killed player, once, by standing on the body before it is reported.
    case medic
    /// Sees where everyone else is standing (tiles and head counts, never names), twice.
    case scout
}

/// The impostors' three sabotages.
enum SabotageKind: String, Codable, Hashable, CaseIterable {
    /// Tasks are off until one crew member repairs it.
    case lights
    /// No reports or emergency meetings, and the map goes dark, until one crew member repairs it.
    case jammer
    /// A countdown. Two crew must repair it together, or the impostors win when it ends.
    case meltdown
}

/// The sabotage that is active right now, public to everyone.
struct SabotageState: Codable, Hashable {
    var kind: SabotageKind
    /// The fix station that repairs it. Chosen by the server when the sabotage starts.
    var fixStationId: String?
    /// Epoch milliseconds when a meltdown ends the game. nil for the other sabotages.
    var endsAt: Int?
    /// Crew who have started repairing a meltdown within the last few seconds.
    var holders: Int
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
    /// The active sabotage, or nil. `lightsOut` stays true for the lights sabotage for older code.
    var sabotage: SabotageState? = nil
}

/// A door between two scanned rooms, seen from one of them. Tiles are local to their own room.
struct DoorInfo: Codable, Hashable {
    var tile: Tile
    var toZone: String
    var toTile: Tile
}

/// One scanned room. `grid` is the room's own grid in its own ARKit frame. `offset` converts its tiles to the game's
/// shared tiles: shared = local + offset. Each room has its own ARWorldMap.
struct ZoneInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var offset: Tile
    var grid: Grid
    var hasMap: Bool
    var doors: [DoorInfo]
}

/// A door as the host sets it: one edge tile in each of two rooms.
struct DoorEnd: Codable, Hashable {
    var zone: String
    var tile: Tile
}

struct DoorLink: Codable, Hashable {
    var a: DoorEnd
    var b: DoorEnd
}

/// The Scout's private ping: where others stand, with head counts only.
struct ScoutTile: Codable, Hashable {
    var x: Int
    var y: Int
    var count: Int
}

struct ScoutPing: Codable, Hashable {
    var tiles: [ScoutTile]
    var usesLeft: Int
    /// Epoch milliseconds when the next ping is allowed.
    var cooldownEndsAt: Int
}

/// One object found by the scan detector. `box` is `[x, y, w, h]`, normalized 0-1 image coordinates.
struct DetectedObject: Codable, Hashable {
    var label: String
    var box: [Double]
}
