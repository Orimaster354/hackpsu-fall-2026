import ARKit
import Observation

/// Owns the `ARSession`, runs world tracking and publishes pose, quality and errors.
@Observable
final class ARTrackingSession: NSObject, PlayerTracking, ARSessionDelegate {
    @ObservationIgnored let session = ARSession()

    private(set) var pose: TrackedPose?
    /// Quality is published immediately on change, unlike `pose`, which is throttled for the UI.
    private(set) var quality: TrackingQuality = .notAvailable
    private(set) var lastError: String?
    private(set) var isInterrupted = false
    private(set) var isRunning = false
    /// Increments on every `reset()`. Positions from before a reset share no coordinate frame with later ones.
    private(set) var resetCount = 0

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    @ObservationIgnored private var lastPublish: TimeInterval = 0
    private static let publishInterval: TimeInterval = 1.0 / 15.0

    override init() {
        super.init()
        session.delegate = self
    }

    // MARK: Control

    func start() {
        guard Self.isSupported else {
            lastError = "World tracking is not supported on this device (simulator or no ARKit)."
            return
        }
        session.delegate = self
        session.run(Self.makeConfiguration())
        isRunning = true
    }

    func pause() {
        session.pause()
        isRunning = false
        quality = .notAvailable
    }

    /// Discards the world map and all anchors. The origin becomes the phone's current pose.
    func reset() {
        guard Self.isSupported else { return }
        session.delegate = self
        session.run(Self.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        pose = nil
        quality = .initializing
        lastError = nil
        isInterrupted = false
        isRunning = true
        resetCount += 1
    }

    private static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        return config
    }

    // MARK: ARSessionDelegate (delivered on the main queue)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let position = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                    frame.camera.transform.columns.3.y,
                                    frame.camera.transform.columns.3.z)
        let sample = TrackedPose(position: position,
                                 quality: TrackingQuality(frame.camera.trackingState),
                                 timestamp: frame.timestamp)
        MainActor.assumeIsolated { publish(sample) }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let q = TrackingQuality(camera.trackingState)
        MainActor.assumeIsolated { quality = q }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = Self.describe(error)
        MainActor.assumeIsolated {
            lastError = message
            quality = .notAvailable
            isRunning = false
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            isInterrupted = true
            quality = .notAvailable
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated { isInterrupted = false }
    }

    /// Keep the existing coordinate frame after an interruption instead of silently restarting at a new origin.
    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    // MARK: Helpers

    private func publish(_ sample: TrackedPose) {
        let qualityChanged = sample.quality != quality
        if qualityChanged { quality = sample.quality }
        guard qualityChanged || sample.timestamp - lastPublish >= Self.publishInterval else { return }
        lastPublish = sample.timestamp
        pose = sample
        if lastError != nil, sample.quality != .notAvailable { lastError = nil }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.localizedDescription) (code \(ns.code))"
        if let reason = ns.localizedFailureReason { text += ": \(reason)" }
        if ns.code == ARError.cameraUnauthorized.rawValue {
            text += ". Enable Camera for this app in Settings."
        }
        return text
    }
}
