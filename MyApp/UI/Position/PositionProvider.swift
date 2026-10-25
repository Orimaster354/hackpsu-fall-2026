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

/// What the player is told about AR. `PositionStatus` stays the coarse three-way signal (searching, tracking,
/// failed) that existing screens switch on; this is the precise reason behind it.
enum PositionDetail: Equatable {
    case idle
    case downloadingMap
    case mapMissing
    case downloadFailed(String)
    case decodeFailed(String)
    case relocalizing
    case timedOut
    case interrupted
    case sessionFailed(String)
    case tracking
    /// AR is working but the phone is not on a playable tile. No tile is reported, which is not a failure.
    case outsideGrid

    var message: String {
        switch self {
        case .idle: "AR is not running."
        case .downloadingMap: "Downloading the room map…"
        case .mapMissing: "The host has not uploaded a room map yet. Ask the host to finish the scan, then retry."
        case let .downloadFailed(reason): "Could not download the room map: \(reason)"
        case let .decodeFailed(reason): "The room map could not be read: \(reason)"
        case .relocalizing: "Finding your place in the room. Point the camera at the walls and move slowly."
        case .timedOut: "AR could not find your place within 20 seconds. Retry AR, or use manual tiles."
        case .interrupted: "AR was interrupted (app switch, call or covered camera). It resumes when the camera is back."
        case let .sessionFailed(reason): "AR stopped: \(reason)"
        case .tracking: "AR is tracking you."
        case .outsideGrid: "You are outside the room grid. Walk back into the room."
        }
    }

    var icon: String {
        switch self {
        case .tracking: "checkmark.circle.fill"
        case .outsideGrid: "arrow.up.left.and.down.right.magnifyingglass"
        case .interrupted: "pause.circle.fill"
        case .idle, .downloadingMap, .relocalizing: "viewfinder"
        case .mapMissing, .downloadFailed, .decodeFailed, .timedOut, .sessionFailed: "exclamationmark.triangle.fill"
        }
    }

    /// AR has stopped trying. A retry starts a fresh attempt.
    var isProblem: Bool {
        switch self {
        case .mapMissing, .downloadFailed, .decodeFailed, .timedOut, .sessionFailed: true
        default: false
        }
    }

    var canRetry: Bool { isProblem }

    /// The coarse status existing screens use.
    var status: PositionStatus {
        switch self {
        case .idle: .idle
        case .downloadingMap, .relocalizing, .interrupted: .searching
        case .tracking, .outsideGrid: .tracking
        case .mapMissing, .downloadFailed, .decodeFailed, .timedOut, .sessionFailed: .failed(message)
        }
    }
}

protocol PositionProvider: AnyObject {
    var source: TileSource { get }
    /// The tile the phone is on right now, nil until known.
    var tile: MapTile? { get }
    var status: PositionStatus { get }
    /// The precise reason behind `status`.
    var detail: PositionDetail { get }
    func start(on grid: MapGrid)
    func stop()
    /// A fresh attempt on the grid given to the last `start`: reload the room map, restart relocalization in the
    /// same coordinate frame, and clear any earlier error. Providers with nothing to reload ignore it.
    func restart()
}

extension PositionProvider {
    var detail: PositionDetail {
        switch status {
        case .idle: .idle
        case .searching: .relocalizing
        case .tracking: .tracking
        case let .failed(reason): .sessionFailed(reason)
        }
    }

    func restart() {}
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
    @ObservationIgnored private var retryCount = 0

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
    /// What AR is doing, whichever source is active. Manual tiles do not hide an AR problem.
    var arDetail: PositionDetail { ar?.detail ?? .idle }

    func begin(grid: MapGrid, report: @escaping (MapTile, TileSource) -> Void) {
        guard loop == nil else { return }
        manual.start(on: grid)
        ar?.start(on: grid)
        loop = Task { [weak self] in
            var searchingSince: Date?
            var seenRetry = 0
            while !Task.isCancelled {
                guard let self else { return }
                // A retry is a new search: its 20 s clock starts over.
                if seenRetry != self.retryCount { seenRetry = self.retryCount; searchingSince = nil }
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

    /// Switch to AR. If AR had given up, this is a retry: switching the source alone would leave it stuck on the
    /// old failure, so it starts a fresh attempt. If AR is working or still searching, it just switches.
    func useAR() {
        guard let ar else { return }
        mode = .ar
        offerManual = false
        if ar.detail.isProblem { restartAR(ar) }
    }

    /// "Retry AR": always a fresh attempt. Reloads the room's ARWorldMap and relocalizes again in the same
    /// coordinate frame. Works from manual mode too, and clears the manual-tiles offer.
    func retryAR() {
        guard let ar else { return }
        mode = .ar
        offerManual = false
        restartAR(ar)
    }

    /// Call when the app returns to the foreground. If AR gave up while the app was away, try once more
    /// instead of leaving the player on a stale error. A player who chose manual tiles stays on them.
    func appBecameActive() {
        guard mode == .ar, isRunning, let ar, ar.detail.isProblem else { return }
        restartAR(ar)
    }

    private func restartAR(_ ar: any PositionProvider) {
        retryCount += 1
        ar.restart()
    }

    /// A tap on the map. Only counts in manual mode, where the map is the input.
    func pick(_ tile: MapTile) {
        guard mode == .manual else { return }
        manual.select(tile)
    }
}
