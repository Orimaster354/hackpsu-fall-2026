import ARKit
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

    /// The tile under the phone. nil while relocalizing, interrupted, degraded or outside the playable grid.
    var tile: MapTile? {
        guard detail == .tracking else { return nil }
        return currentTile
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
