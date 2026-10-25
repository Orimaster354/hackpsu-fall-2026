import Foundation
import Observation

/// Live tile for gameplay: the phone downloads the host's ARWorldMap, relocalizes into the host's coordinate
/// system, and reports which grid tile it is standing on. `PositionCoordinator` (UI) calls `start`, reads `tile`
/// and `status` twice a second and sends `tile { tile, source: "ar" }`. If the map is missing or ARKit cannot
/// relocalize within 20 s, `status` becomes `.failed` and the coordinator offers the manual tile picker.
///
/// Tiles are approximate (ARKit drifts, relocalization is a few tens of centimetres off), which is fine for a demo:
/// the server only accepts a tile after two identical reports in a row.
@Observable
final class ARPositionProvider: PositionProvider {
    let source = TileSource.ar

    @ObservationIgnored private let tracking = ARTrackingSession()
    @ObservationIgnored private let client: GameClient
    @ObservationIgnored private var task: Task<Void, Never>?
    private var grid: MapGrid?
    private var failure: String?

    init(client: GameClient) {
        self.client = client
    }

    /// The tile under the phone, or nil while relocalizing, when tracking is degraded, or outside the room.
    var tile: MapTile? {
        guard let grid, failure == nil, tracking.positionMode == .ar,
              let position = tracking.reliablePosition else { return nil }
        let tile = grid.tile(atX: Double(position.x), z: Double(position.z))
        return grid.contains(tile) ? tile : nil
    }

    var status: PositionStatus {
        if let failure { return .failed(failure) }
        guard grid != nil else { return .idle }
        switch tracking.positionMode {
        case .ar: return .tracking
        case .manual: return .failed(tracking.lastError ?? "Could not find your place in the room.")
        case .unlocalized, .relocalizing: return .searching
        }
    }

    func start(on grid: MapGrid) {
        stop()
        self.grid = grid
        failure = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let data = try await client.downloadMap() else {
                    failure = "The host has not uploaded a room map."
                    return
                }
                guard !Task.isCancelled else { return }
                try tracking.loadWorldMap(data)
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if tracking.isRunning { tracking.pause() }
        grid = nil
        failure = nil
    }
}
