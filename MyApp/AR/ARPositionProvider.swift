import ARKit
import RealityKit
import Foundation
import Observation

/// Live tile for gameplay: the phone downloads the host's ARWorldMap, relocalizes into the host's coordinate
/// system, and reports which grid tile it is standing on. `PositionCoordinator` (UI) calls `start`, reads `tile`
/// and `status` twice a second and sends `tile { tile, source: "ar" }`. If the map is missing or ARKit cannot
/// relocalize within 20 s, `status` becomes `.failed` and the coordinator offers the manual tile picker.
///
/// `restart()` is the real "Retry AR": it cancels whatever is in flight, clears the old error, downloads the
/// host's existing map again and relocalizes in that same frame. It never starts an unrelated world origin: the
/// only way the session leaves the saved map's frame is `ARTrackingSession.reset()`, which this class never calls.
///
/// Tiles are approximate (ARKit drifts, relocalization is a few tens of centimetres off), which is fine for a demo:
/// the server only accepts a tile after two identical reports in a row.
@Observable
final class ARPositionProvider: PositionProvider {
    let source = TileSource.ar

    @ObservationIgnored private let tracking = ARTrackingSession()
    @ObservationIgnored private let client: GameClient
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Numbers each map download. A download that finishes after a retry or `stop` sees an old number and does
    /// nothing, so it cannot overwrite the newer attempt's state or load a stale map.
    @ObservationIgnored private var attempts = AttemptCounter()
    /// Kept across `restart()` so a retry knows the grid. Cleared by `stop()`, which ends the game's AR.
    @ObservationIgnored private var lastGrid: MapGrid?
    /// The grid of the room the phone is relocalized in. With several rooms it is that room's own grid, in its own
    /// frame; the tile reported to the game adds the room's offset.
    private var grid: MapGrid?
    private var map = PositionDetailResolver.MapState.idle

    /// The scanned rooms. Each has its own ARWorldMap, so the phone loads one at a time: the room it starts in,
    /// then the next room's map when it walks through a door (or its map did not match where the phone is).
    @ObservationIgnored private var zones: [ZoneInfo] = []
    private var activeZone: ZoneInfo?
    /// Rooms already tried since the phone was last tracking inside one, so a missing match cannot loop forever.
    @ObservationIgnored private var triedZones: [String] = []
    @ObservationIgnored private var outsideSince: Date?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// How near a door (in tiles) the phone has to be, once it left its room's grid, to load the other room's map.
    private static let doorReach = 6
    private static let outsideBeforeSwitch: TimeInterval = 2
    private static let outsideBeforeGuess: TimeInterval = 8

    init(client: GameClient) {
        self.client = client
    }

    /// The one ARSession, for views that draw on it (the task screen's 3D prop). Never run or pause it from there.
    var arSession: ARSession { tracking.session }

    /// The session's one shared RealityKit view. Draw on this; never create another ARView for the session, because
    /// RealityKit pauses the session when such a view goes away.
    var arView: ARView { tracking.arView }

    /// ARKit owns the camera right now. While true, nothing else (an AVCaptureSession) may use it.
    var isSessionRunning: Bool { tracking.isRunning && !tracking.isInterrupted }

    /// How long the last good tile keeps being reported after tracking drops, while ARKit finds its place again.
    static let holdLastTileSeconds: TimeInterval = 10

    /// The last tile AR was sure of, and when. Not observed: it only feeds the continuity rule below.
    @ObservationIgnored private var lastGood: (tile: MapTile, at: Date)?

    /// The tile under the phone. While tracking it is the live tile. For a short time after tracking drops
    /// (a task screen, a call, a glance away) while ARKit is relocalizing or interrupted, it stays the last good
    /// tile: a player who just finished a task is still standing on that station's tile, so the map and the server
    /// do not lose them. nil when outside the grid, after the hold runs out, and for real failures.
    var tile: MapTile? {
        let now = Date()
        let current = detail
        if current == .tracking, let local = currentTile {
            // The room's tile in the game's shared tiles (the offset is zero for a one-room game).
            let offset = activeZone?.offset ?? Tile(x: 0, y: 0)
            let live = MapTile(x: local.x + offset.x, y: local.y + offset.y)
            lastGood = (live, now)
            return live
        }
        if (current == .relocalizing || current == .interrupted), let lastGood,
           now.timeIntervalSince(lastGood.at) < Self.holdLastTileSeconds {
            return lastGood.tile
        }
        return nil
    }

    var status: PositionStatus { detail.status }

    /// The precise state: which of map missing, download or decode failure, relocalizing, timed out, interrupted,
    /// session failure, tracking and outside-the-grid applies.
    var detail: PositionDetail {
        let onTile = currentTile
        return PositionDetailResolver.resolve(
            map: map,
            mode: PositionDetailResolver.Mode(rawValue: tracking.positionMode.rawValue) ?? .unlocalized,
            interrupted: tracking.isInterrupted,
            failure: tracking.positionFailure,
            hasReliablePosition: tracking.positionMode == .ar && tracking.reliablePosition != nil,
            insideGrid: onTile.map { grid?.contains($0) ?? false } ?? false
        )
    }

    /// The tile under a reliable AR position in the active room's own tiles, playable or not.
    private var rawTile: MapTile? {
        guard let grid, tracking.positionMode == .ar, let position = tracking.reliablePosition else { return nil }
        return grid.tile(atX: Double(position.x), z: Double(position.z))
    }

    /// The tile under a reliable AR position, if it is playable.
    private var currentTile: MapTile? {
        guard let grid, let tile = rawTile else { return nil }
        return grid.contains(tile) ? tile : nil
    }

    func useZones(_ zones: [ZoneInfo]) {
        self.zones = zones
    }

    func start(on grid: MapGrid) {
        triedZones = []
        outsideSince = nil
        // A room with an uploaded map first; the others are tried if that one does not match.
        let first = zones.first { $0.hasMap } ?? zones.first
        activeZone = first
        if let first { triedZones = [first.id] }
        begin(grid, zone: first)
    }

    /// A fresh attempt on the grid given to the last `start`, in the room the phone was last relocalizing in.
    /// Does nothing after `stop()`.
    func restart() {
        guard let grid = lastGrid else { return }
        begin(grid, zone: activeZone)
    }

    func stop() {
        cancelInFlight()
        activeZone = nil
        triedZones = []
        outsideSince = nil
        if tracking.isRunning { tracking.pause() }
        tracking.prepareForNewAttempt()
        grid = nil
        lastGrid = nil
        map = .idle
        lastGood = nil
    }

    private func cancelInFlight() {
        task?.cancel()
        task = nil
        watcher?.cancel()
        watcher = nil
        attempts.next()
    }

    /// Loads the map of `zone` (or the only map, with no rooms) and relocalizes in it. `grid` is the game grid; with
    /// rooms the phone works in the room's own grid instead, and the offset puts its tile into the game's tiles.
    private func begin(_ grid: MapGrid, zone: ZoneInfo?) {
        cancelInFlight()
        tracking.prepareForNewAttempt()
        lastGrid = grid
        activeZone = zone
        self.grid = zone.map { MapGrid($0.grid) } ?? grid
        map = .downloading
        let id = attempts.next()
        if zones.count > 1 { watchRooms(id: id) }
        task = Task { [weak self] in
            guard let self else { return }
            let data: Data?
            do {
                data = try await client.downloadMap(zone: zone?.id ?? "z1")
            } catch {
                guard isCurrent(id) else { return }
                map = .downloadFailed(Self.describe(error))
                return
            }
            guard isCurrent(id) else { return }
            guard let data else {
                map = .missing
                return
            }
            do {
                try tracking.loadWorldMap(data)
                map = .loaded
            } catch {
                map = .decodeFailed(Self.describe(error))
            }
        }
    }

    // MARK: Moving between rooms

    /// Checks twice a second whether the phone should load another room's map. It stops when a newer attempt starts.
    private func watchRooms(id: Int) {
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, isCurrent(id) else { return }
                checkRoom()
            }
        }
    }

    private func checkRoom() {
        guard let active = activeZone else { return }
        switch detail {
        case .tracking:
            // Inside the room: this is the right map. A later move may need another one.
            triedZones = [active.id]
            outsideSince = nil
        case .outsideGrid:
            let since = outsideSince ?? Date()
            outsideSince = since
            let away = Date().timeIntervalSince(since)
            if away > Self.outsideBeforeSwitch, let door = nearestDoor(of: active), let next = zones.first(where: { $0.id == door.toZone }) {
                switchRoom(to: next)
            } else if away > Self.outsideBeforeGuess, let next = untriedZone() {
                // No door nearby (none marked, or the phone is somewhere else): try the other rooms' maps.
                switchRoom(to: next)
            }
        case .timedOut:
            // This room's map does not match where the phone is. Try the other rooms before giving up.
            if let next = untriedZone() { switchRoom(to: next) }
        default:
            outsideSince = nil
        }
    }

    /// The door of `zone` closest to the phone, if one is within reach. Distances are in the room's own tiles.
    private func nearestDoor(of zone: ZoneInfo) -> DoorInfo? {
        guard let here = rawTile else { return nil }
        let near = zone.doors.map { door in (door, max(abs(door.tile.x - here.x), abs(door.tile.y - here.y))) }
            .filter { $0.1 <= Self.doorReach }
        return near.min { $0.1 < $1.1 }?.0
    }

    private func untriedZone() -> ZoneInfo? {
        zones.first { $0.hasMap && !triedZones.contains($0.id) }
    }

    private func switchRoom(to zone: ZoneInfo) {
        guard let lastGrid else { return }
        outsideSince = nil
        triedZones.append(zone.id)
        begin(lastGrid, zone: zone)
    }

    private func isCurrent(_ id: Int) -> Bool {
        !Task.isCancelled && attempts.isCurrent(id)
    }

    private static func describe(_ error: Error) -> String {
        if let mapError = error as? GameClient.MapError {
            switch mapError {
            case .notInRoom: return "you are not in a room"
            case .badURL: return "check the server address in Settings"
            case let .http(status): return "the server answered HTTP \(status)"
            }
        }
        if let captureError = error as? ARCaptureError, case let .invalid(text) = captureError { return text }
        return error.localizedDescription
    }
}
