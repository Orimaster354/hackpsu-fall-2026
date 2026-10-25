import Foundation

// ARKit-free rules for what the AR position state means to the player. `ARPositionProvider` feeds in what
// ARKit and the map download say; this decides the one precise status to show. Keeping it free of ARKit lets the
// Mac checks (Tests/ARScanChecks) cover every state.

/// Hands out attempt numbers so a callback from an old attempt can tell it is old. Every retry, cancel,
/// interruption or timeout starts a new number; anything holding an older one must do nothing.
struct AttemptCounter: Equatable {
    private(set) var current = 0

    @discardableResult
    mutating func next() -> Int {
        current += 1
        return current
    }

    func isCurrent(_ id: Int) -> Bool { id == current }
}

enum PositionDetailResolver {
    /// The room map download and decode, before ARKit is involved.
    enum MapState: Equatable {
        case idle, downloading, missing
        case downloadFailed(String)
        case decodeFailed(String)
        case loaded
    }

    /// Mirrors `ARTrackingSession.PositionMode`.
    enum Mode: String, Equatable {
        case unlocalized, relocalizing, ar, manual
    }

    /// Why AR gave up. Cleared when a new attempt starts.
    enum Failure: Equatable {
        case timedOut
        case sessionFailed(String)
    }

    /// - Parameters:
    ///   - hasReliablePosition: ARKit reports normal tracking with a position.
    ///   - insideGrid: that position falls on a playable tile. Only meaningful with `hasReliablePosition`.
    static func resolve(map: MapState, mode: Mode, interrupted: Bool, failure: Failure?,
                        hasReliablePosition: Bool, insideGrid: Bool) -> PositionDetail {
        switch map {
        case .idle: return .idle
        case .downloading: return .downloadingMap
        case .missing: return .mapMissing
        case let .downloadFailed(message): return .downloadFailed(message)
        case let .decodeFailed(message): return .decodeFailed(message)
        case .loaded: break
        }
        switch failure {
        case let .sessionFailed(message)?: return .sessionFailed(message)
        case .timedOut?: return .timedOut
        case nil: break
        }
        if interrupted { return .interrupted }
        switch mode {
        case .unlocalized, .relocalizing:
            return .relocalizing
        case .manual:
            // Manual without a recorded cause: AR gave up before this model existed. Offer a retry.
            return .timedOut
        case .ar:
            guard hasReliablePosition else { return .relocalizing }
            return insideGrid ? .tracking : .outsideGrid
        }
    }
}
