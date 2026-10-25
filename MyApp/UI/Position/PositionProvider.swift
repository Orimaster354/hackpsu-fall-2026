import Foundation
import Observation

// Where the phone thinks it is. The docs give two sources and one message: ARKit computes
// `floor((pos - origin) / 1.0)` and manual mode has the player tap a tile, and both are sent as
// `tile { tile, source }` at 2 to 4 Hz. Everything above this file only asks a `PositionProvider`.
//
// To replace manual input with ARKit, the AR module conforms one class to `PositionProvider`
// (publish `tile`, and `status` while it relocalizes) and passes it to
// `PositionCoordinator(ar:)`. No screen changes. `MapGrid.tile(atX:z:)` does the conversion.

enum PositionStatus: Equatable {
    case idle
    /// Relocalizing against the saved ARWorldMap.
    case searching
    case tracking
    case failed(String)
}

protocol PositionProvider: AnyObject {
    var source: TileSource { get }
    /// The tile the phone is on right now, nil until known.
    var tile: MapTile? { get }
    var status: PositionStatus { get }
    func start(on grid: MapGrid)
    func stop()
}

/// The fallback and testing source: the player taps their tile on the 2D map.
@Observable
final class ManualPositionProvider: PositionProvider {
    let source = TileSource.manual
    private(set) var tile: MapTile?
    private(set) var status = PositionStatus.idle

    func start(on grid: MapGrid) { status = .tracking }
    func stop() { status = .idle }
    func select(_ tile: MapTile) { self.tile = tile }
    func reset() { tile = nil }
}

/// Owns the active source, offers manual mode when AR cannot find the player, and reports the
/// current tile to the session twice a second. Twice a second means the server's drift filter
/// (two identical reports in a row) accepts a tile within about a second, for either source.
@Observable
final class PositionCoordinator {
    private(set) var mode: TileSource
    /// True once AR has been searching longer than `searchTimeout` (docs: 20 s) or has failed.
    private(set) var offerManual = false
    let manual = ManualPositionProvider()
    let ar: (any PositionProvider)?

    @ObservationIgnored var searchTimeout: Duration = .seconds(20)
    @ObservationIgnored var reportInterval: Duration = .milliseconds(500)
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(ar: (any PositionProvider)? = nil) {
        self.ar = ar
        mode = ar == nil ? .manual : .ar
    }

    var canUseAR: Bool { ar != nil }
    var isRunning: Bool { loop != nil }

    var active: any PositionProvider {
        if mode == .ar, let ar { return ar }
        return manual
    }

    var tile: MapTile? { active.tile }
    var status: PositionStatus { active.status }

    func begin(grid: MapGrid, report: @escaping (MapTile, TileSource) -> Void) {
        guard loop == nil else { return }
        manual.start(on: grid)
        ar?.start(on: grid)
        loop = Task { [weak self] in
            var searchingSince: Date?
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.active
                if let tile = current.tile { report(tile, current.source) }
                if self.mode == .ar {
                    if current.status == .searching {
                        let since = searchingSince ?? Date()
                        searchingSince = since
                        if Date().timeIntervalSince(since) > self.searchTimeout.seconds { self.offerManual = true }
                    } else {
                        searchingSince = nil
                    }
                    if case .failed = current.status { self.offerManual = true }
                }
                try? await Task.sleep(for: self.reportInterval)
            }
        }
    }

    func end() {
        loop?.cancel()
        loop = nil
        manual.stop()
        manual.reset()
        ar?.stop()
        offerManual = false
        mode = ar == nil ? .manual : .ar
    }

    func useManual() {
        mode = .manual
        offerManual = false
    }

    func useAR() {
        guard ar != nil else { return }
        mode = .ar
        offerManual = false
    }

    /// A tap on the map. Only counts in manual mode, where the map is the input.
    func pick(_ tile: MapTile) {
        guard mode == .manual else { return }
        manual.select(tile)
    }
}
