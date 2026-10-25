import Foundation
import Observation

/// Pretends to be the AR module so the swap from manual input to ARKit can be seen without a
/// scan: it searches for a few seconds, then "tracks" a walk around the room's edge. With
/// `failsToRelocalize` its first attempt times out (`.timedOut`), which shows the fallback offer and the
/// Retry AR button, and the retry succeeds, so the whole recovery path can be tried in the Simulator.
/// Real tracking is workstream A's `PositionProvider`.
@Observable
final class MockARProvider: PositionProvider {
    let source = TileSource.ar
    private(set) var tile: MapTile?
    private(set) var status = PositionStatus.idle
    private(set) var detail = PositionDetail.idle

    @ObservationIgnored private let failsToRelocalize: Bool
    @ObservationIgnored private let relocalizeAfter: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastGrid: MapGrid?
    @ObservationIgnored private var attempts = 0

    init(failsToRelocalize: Bool = false, relocalizeAfter: Duration = .seconds(3)) {
        self.failsToRelocalize = failsToRelocalize
        self.relocalizeAfter = relocalizeAfter
    }

    func start(on grid: MapGrid) {
        guard task == nil else { return }
        lastGrid = grid
        attempts += 1
        let willFail = failsToRelocalize && attempts == 1
        set(.relocalizing)
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: relocalizeAfter)
            guard !Task.isCancelled else { return }
            if willFail {
                set(.timedOut)
                return
            }
            set(.tracking)
            let route = Self.ring(of: grid)
            var step = 0
            while !Task.isCancelled, !route.isEmpty {
                tile = route[step % route.count]
                step += 1
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// A fresh attempt: the old one is cancelled and its state cleared before the new one starts.
    func restart() {
        guard let grid = lastGrid else { return }
        cancelTask()
        start(on: grid)
    }

    func stop() {
        cancelTask()
        lastGrid = nil
        attempts = 0
        set(.idle)
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        tile = nil
    }

    private func set(_ new: PositionDetail) {
        detail = new
        status = new.status
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
