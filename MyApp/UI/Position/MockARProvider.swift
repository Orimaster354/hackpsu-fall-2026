import Foundation
import Observation

/// Pretends to be the AR module so the swap from manual input to ARKit can be seen without a
/// scan: it searches for a few seconds, then "tracks" a walk around the room's edge. With
/// `failsToRelocalize` it searches forever, which shows the fallback offer after the timeout.
/// Real tracking is workstream A's `PositionProvider`.
@Observable
final class MockARProvider: PositionProvider {
    let source = TileSource.ar
    private(set) var tile: MapTile?
    private(set) var status = PositionStatus.idle

    @ObservationIgnored private let failsToRelocalize: Bool
    @ObservationIgnored private let relocalizeAfter: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    init(failsToRelocalize: Bool = false, relocalizeAfter: Duration = .seconds(3)) {
        self.failsToRelocalize = failsToRelocalize
        self.relocalizeAfter = relocalizeAfter
    }

    func start(on grid: MapGrid) {
        guard task == nil else { return }
        status = .searching
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: relocalizeAfter)
            guard !Task.isCancelled, !failsToRelocalize else { return }
            status = .tracking
            let route = Self.ring(of: grid)
            var step = 0
            while !Task.isCancelled, !route.isEmpty {
                tile = route[step % route.count]
                step += 1
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        tile = nil
        status = .idle
    }

    /// Edge tiles in order around the room's center.
    private static func ring(of grid: MapGrid) -> [MapTile] {
        let cx = Double(grid.cols) / 2
        let cy = Double(grid.rows) / 2
        return grid.edge.sorted {
            atan2(Double($0.y) + 0.5 - cy, Double($0.x) + 0.5 - cx) < atan2(Double($1.y) + 0.5 - cy, Double($1.x) + 0.5 - cx)
        }
    }
}
