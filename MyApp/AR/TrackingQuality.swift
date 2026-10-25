import ARKit

/// Tracking quality, decoupled from ARKit types so game code never imports ARKit.
///
/// `.normal` means ARKit is not reporting a problem. It is NOT a guarantee of accuracy:
/// drift accumulates silently while walking. Treat even `.normal` positions as approximate.
nonisolated enum TrackingQuality: Equatable {
    case notAvailable
    case initializing
    case excessiveMotion
    case insufficientFeatures
    case relocalizing
    case normal

    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal: self = .normal
        case .notAvailable: self = .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: self = .initializing
            case .excessiveMotion: self = .excessiveMotion
            case .insufficientFeatures: self = .insufficientFeatures
            case .relocalizing: self = .relocalizing
            @unknown default: self = .notAvailable
            }
        }
    }

    /// Only `.normal` positions may be used for game decisions.
    var isReliable: Bool { self == .normal }

    var label: String {
        switch self {
        case .notAvailable: "Not available"
        case .initializing: "Initializing"
        case .excessiveMotion: "Excessive motion"
        case .insufficientFeatures: "Insufficient features"
        case .relocalizing: "Relocalizing"
        case .normal: "Normal"
        }
    }

    var hint: String {
        switch self {
        case .notAvailable: "No tracking. Camera blocked, session stopped or unsupported."
        case .initializing: "Move the phone slowly so ARKit can build its map."
        case .excessiveMotion: "Slow down. Moving too fast."
        case .insufficientFeatures: "Point at a textured, well-lit surface (not a blank wall)."
        case .relocalizing: "Trying to re-find the known map. Point at the area you scanned."
        case .normal: "Tracking is healthy."
        }
    }
}
