import ARKit
import AVFoundation
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
    private var grid: MapGrid?
    private var map = PositionDetailResolver.MapState.idle

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

    /// Keep borrowing the same view through interruptions; never open a second camera then.
    var taskARView: ARView? { tracking.isRunning ? tracking.arView : nil }

    /// Manual fallback may be selected while a map download is still in flight. Cancel it before
    /// a task-only session takes the camera; retain lastGrid so Retry AR can still reload the map.
    func prepareForManualTask() {
        if !tracking.isRunning { cancelInFlight() }
    }

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
        if current == .tracking, let live = currentTile {
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

    /// The tile under a reliable AR position, whether or not it is playable.
    private var currentTile: MapTile? {
        guard let grid, tracking.positionMode == .ar, let position = tracking.reliablePosition else { return nil }
        let tile = grid.tile(atX: Double(position.x), z: Double(position.z))
        return grid.contains(tile) ? tile : nil
    }

    func start(on grid: MapGrid) {
        begin(grid)
    }

    /// A fresh attempt on the grid given to the last `start`. Does nothing after `stop()`.
    func restart() {
        guard let grid = lastGrid else { return }
        begin(grid)
    }

    func stop() {
        cancelInFlight()
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
        attempts.next()
    }

    private func begin(_ grid: MapGrid) {
        cancelInFlight()
        tracking.prepareForNewAttempt()
        lastGrid = grid
        self.grid = grid
        map = .downloading
        let id = attempts.next()
        task = Task { [weak self] in
            guard let self else { return }
            let data: Data?
            do {
                data = try await client.downloadMap()
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


/// A task-only coordinate frame for manual movement. Never reports tiles, downloads a map,
/// or replaces the game's AR provider. One retained view owns this session until the sheet closes.
@Observable
final class TaskARPreview {
    private let tracking = ARTrackingSession()
    private var generation = 0

    var arView: ARView? { tracking.isRunning ? tracking.arView : nil }
    var isTracking: Bool { tracking.isRunning && !tracking.isInterrupted && tracking.quality.isReliable }

    func start() async {
        guard ARTrackingSession.isSupported, !tracking.isRunning else { return }
        generation += 1
        let attempt = generation
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard allowed, !Task.isCancelled, attempt == generation else { return }
        tracking.start()
    }

    func stop() {
        generation += 1
        if tracking.isRunning { tracking.pause() }
    }
}
