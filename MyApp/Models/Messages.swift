import Foundation

// Wire messages. Every frame is a JSON object `{ "t": "<type>", ...fields }` (docs/architecture.md,
// "Protocol"). Fields sit beside `t`, so `state` and `meeting` payloads are flat.

/// Arbitrary JSON, for opaque payloads such as the `suggest` `boxes` metadata.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }
}

// MARK: - Client to server

enum ClientMessage: Equatable {
    case create(name: String)
    /// `playerId` is supplied only on reconnect.
    case join(room: String, name: String, playerId: String? = nil)
    case ready(Bool)
    case setRoom(grid: Grid, stations: [Station])
    /// `photos` holds exactly one base64 JPEG (server limit 4 MiB).
    case suggest(photos: [String], boxes: JSONValue? = nil)
    case scanStart
    case scanFrame(frameId: String, timestampMs: Int, jpeg: String)
    case scanStop
    case editStation(Station)
    case deleteStation(id: String)
    case confirmSetup
    case start
    case tile(Tile, source: TileSource)
    case taskDone(stationId: String)
    case kill(targetId: String)
    case report(bodyId: String)
    case emergency
    /// A player id, or `MeetingState.skip`.
    case vote(target: String)
    case sabotage
    case fix(stationId: String)

    var type: String {
        switch self {
        case .create: return "create"
        case .join: return "join"
        case .ready: return "ready"
        case .setRoom: return "setRoom"
        case .suggest: return "suggest"
        case .scanStart: return "scan_start"
        case .scanFrame: return "scan_frame"
        case .scanStop: return "scan_stop"
        case .editStation, .deleteStation: return "editStation"
        case .confirmSetup: return "confirmSetup"
        case .start: return "start"
        case .tile: return "tile"
        case .taskDone: return "taskDone"
        case .kill: return "kill"
        case .report: return "report"
        case .emergency: return "emergency"
        case .vote: return "vote"
        case .sabotage: return "sabotage"
        case .fix: return "fix"
        }
    }
}

extension ClientMessage: Encodable {
    private enum Keys: String, CodingKey {
        case t, name, room, playerId, ready, grid, stations, photos, boxes
        case frameId, timestampMs, jpeg, station, id, delete
        case tile, source, stationId, targetId, bodyId, target
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(type, forKey: .t)
        switch self {
        case let .create(name):
            try c.encode(name, forKey: .name)
        case let .join(room, name, playerId):
            try c.encode(room, forKey: .room)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(playerId, forKey: .playerId)
        case let .ready(ready):
            try c.encode(ready, forKey: .ready)
        case let .setRoom(grid, stations):
            try c.encode(grid, forKey: .grid)
            try c.encode(stations, forKey: .stations)
        case let .suggest(photos, boxes):
            try c.encode(photos, forKey: .photos)
            try c.encodeIfPresent(boxes, forKey: .boxes)
        case let .scanFrame(frameId, timestampMs, jpeg):
            try c.encode(frameId, forKey: .frameId)
            try c.encode(timestampMs, forKey: .timestampMs)
            try c.encode(jpeg, forKey: .jpeg)
        case let .editStation(station):
            try c.encode(station, forKey: .station)
        case let .deleteStation(id):
            try c.encode(id, forKey: .id)
            try c.encode(true, forKey: .delete)
        case let .tile(tile, source):
            try c.encode(tile, forKey: .tile)
            try c.encode(source, forKey: .source)
        case let .taskDone(stationId), let .fix(stationId):
            try c.encode(stationId, forKey: .stationId)
        case let .kill(targetId):
            try c.encode(targetId, forKey: .targetId)
        case let .report(bodyId):
            try c.encode(bodyId, forKey: .bodyId)
        case let .vote(target):
            try c.encode(target, forKey: .target)
        case .scanStart, .scanStop, .confirmSetup, .start, .emergency, .sabotage:
            break
        }
    }
}

// MARK: - Server to client

enum Winner: String, Codable, Hashable {
    case crew, impostor
}

struct ScanStatus: Codable, Hashable {
    enum State: String, Codable, Hashable { case connecting, ready, stopped }
    var state: State
    /// Present when stopped: host_stopped, duration_limit, game_started, host_disconnected,
    /// host_reconnected, server_stopped, error.
    var reason: String?
    var maxFps: Double?
    var maxFrameBytes: Int?
    var maxDurationMs: Int?
}

struct LobbySnapshot: Codable, Hashable {
    var players: [Player]
    var grid: Grid
    var stations: [Station]
    var hasMap: Bool
}

struct GameResult: Hashable {
    /// Id of the ejected player, or nil when nobody was ejected.
    var ejected: String?
    var role: Role?
    var winner: Winner?
}

enum ServerMessage: Equatable {
    case joined(playerId: String, room: String)
    case lobby(LobbySnapshot)
    case suggestions(objects: [DetectedObject])
    case scanStatus(ScanStatus)
    case scanDetections(frameId: String, timestampMs: Int, objects: [DetectedObject])
    /// `role` is nil if the server sent none (for example a reconnect before the game started).
    case role(Role?)
    case state(GameState)
    /// Sent to the victim only. The killer is not revealed.
    case killed
    case meeting(MeetingState)
    case result(GameResult)
    case error(code: String, message: String)
    /// Documented scan-processing progress: "polygon", "gemini" or "placing".
    case processing(step: String)
    case setup(grid: Grid, stations: [Station])
    /// A well-formed frame with a type this client does not know. Ignored, not fatal.
    case unknown(type: String)
}

extension ServerMessage: Decodable {
    private enum Keys: String, CodingKey {
        case t, playerId, room, objects, frameId, timestampMs, role, ejected, winner
        case code, message, step, grid, stations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .t)
        switch type {
        case "joined":
            self = .joined(playerId: try c.decode(String.self, forKey: .playerId),
                           room: try c.decode(String.self, forKey: .room))
        case "lobby":
            self = .lobby(try LobbySnapshot(from: decoder))
        case "suggestions":
            self = .suggestions(objects: try c.decode([DetectedObject].self, forKey: .objects))
        case "scan_status":
            self = .scanStatus(try ScanStatus(from: decoder))
        case "scan_detections":
            self = .scanDetections(frameId: try c.decode(String.self, forKey: .frameId),
                                   timestampMs: try c.decode(Int.self, forKey: .timestampMs),
                                   objects: try c.decode([DetectedObject].self, forKey: .objects))
        case "role":
            self = .role(try c.decodeIfPresent(Role.self, forKey: .role))
        case "state":
            self = .state(try GameState(from: decoder))
        case "killed":
            self = .killed
        case "meeting":
            self = .meeting(try MeetingState(from: decoder))
        case "result":
            self = .result(GameResult(ejected: try c.decodeIfPresent(String.self, forKey: .ejected),
                                      role: try c.decodeIfPresent(Role.self, forKey: .role),
                                      winner: try c.decodeIfPresent(Winner.self, forKey: .winner)))
        case "error":
            self = .error(code: try c.decode(String.self, forKey: .code),
                          message: try c.decode(String.self, forKey: .message))
        case "processing":
            self = .processing(step: try c.decode(String.self, forKey: .step))
        case "setup":
            self = .setup(grid: try c.decode(Grid.self, forKey: .grid),
                          stations: try c.decode([Station].self, forKey: .stations))
        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - Codec

enum WireCodec {
    static func encode(_ message: ClientMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(message, .init(codingPath: [], debugDescription: "Not UTF-8"))
        }
        return text
    }

    static func decode(_ text: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }

    static func decode(_ data: Data) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: data)
    }
}
