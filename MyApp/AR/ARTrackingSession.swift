import ARKit
import Observation
import RealityKit

/// Owns the one `ARSession`: world tracking, errors, the host scan's frame feed and world-map capture,
/// and (Phase 4) loading a map, the 20 s relocalization timeout and live tile reporting.
@Observable
final class ARTrackingSession: NSObject, PlayerTracking, ARSessionDelegate {
    @ObservationIgnored let session = ARSession()
    private(set) var pose: TrackedPose?
    private(set) var quality: TrackingQuality = .notAvailable
    private(set) var lastError: String?
    private(set) var isInterrupted = false
    private(set) var isRunning = false
    private(set) var resetCount = 0
    /// Counts interruptions and session failures. The host scan starts over whenever this changes, because
    /// poses recorded before and after would no longer share one world frame.
    private(set) var interruptionCount = 0
    private(set) var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    enum PositionMode: String { case unlocalized, relocalizing, ar, manual }
    private(set) var positionMode: PositionMode = .unlocalized
    /// Why AR gave up (timeout or session failure). Cleared when a new attempt starts, so a retry never shows
    /// the previous attempt's error.
    private(set) var positionFailure: PositionDetailResolver.Failure?
    private(set) var currentTile: SIMD2<Int>?
    private(set) var stationIcons: [ARStationIcon] = []
    private(set) var playerAlive = true
    private(set) var lightsOut = false
    private(set) var grid: ServerGridTracking?

    /// Called on the main thread for every frame while the session runs, with the frame still alive for the call.
    /// Copy out what you need; never keep the `ARFrame` (ARKit starves its camera buffer pool if you do).
    @ObservationIgnored var frameHandler: ((ARFrame) -> Void)?
    /// D wires this to GameClient's documented tile message. It receives no raw poses.
    @ObservationIgnored var onTileReport: ((_ x: Int, _ y: Int, _ source: String) -> Void)?
    /// B presents the existing manual tile picker in response to this callback/state.
    @ObservationIgnored var onManualModeRequested: (() -> Void)?
    @ObservationIgnored private var relocalizationTimeout: Task<Void, Never>?
    /// Numbers each relocalization attempt. A timeout that wakes up after the attempt was cancelled, replaced or
    /// interrupted sees an old number and does nothing, so it cannot push a newer attempt into manual mode.
    @ObservationIgnored private var attempts = AttemptCounter()
    @ObservationIgnored private var tileTimer: Timer?
    @ObservationIgnored private var minimumFrameTimestamp: TimeInterval = 0
    @ObservationIgnored private var lastPublish: TimeInterval = 0
    private static let publishInterval: TimeInterval = 1.0 / 15.0

    var iconsVisible: Bool {
        positionMode == .ar && isRunning && !isInterrupted && reliablePosition != nil && playerAlive
    }

    /// The one RealityKit view for the session. Every screen that draws on the AR camera (the host scan, the task
    /// prop) must use this same view instead of creating its own. RealityKit pauses the ARSession when an ARView
    /// that was attached to it goes away, so a throwaway view per task dropped tracking after every task. This one
    /// lives as long as the session, so nothing ever pauses it from outside.
    @ObservationIgnored lazy var arView: ARView = {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session          // makes the view the session delegate...
        session.delegate = self         // ...so the tracking code takes it straight back
        return view
    }()

    override init() {
        super.init()
        session.delegateQueue = .main
        session.delegate = self
    }

    // MARK: Lifecycle

    /// Starts world tracking. The world origin is wherever the phone is now. The host scan calls this once
    /// and never again until it is over; calling `start` or `reset` mid-scan would move the origin.
    func start() {
        guard !isRunning else { return }
        guard Self.isSupported else {
            lastError = "World tracking is unavailable on this device. Use manual tiles when integrated."
            return
        }
        pose = nil; quality = .initializing; isInterrupted = false; lastPublish = 0
        minimumFrameTimestamp = ProcessInfo.processInfo.systemUptime
        session.delegate = self
        session.run(Self.makeConfiguration())
        isRunning = true
        startTileTimer()
        if positionMode == .ar || positionMode == .relocalizing { beginRelocalizationTimeout() }
    }

    func pause() {
        session.pause()
        isRunning = false; quality = .notAvailable; pose = nil; currentTile = nil
        tileTimer?.invalidate(); tileTimer = nil
        invalidatePendingTimeout()
        if positionMode == .ar { positionMode = .relocalizing }
    }

    /// Cancels any waiting relocalization timeout and makes a late one harmless.
    private func invalidatePendingTimeout() {
        relocalizationTimeout?.cancel()
        relocalizationTimeout = nil
        attempts.next()
    }

    /// Clears everything the previous attempt left behind: its timeout, its error, its failure reason and its tile.
    /// Call before starting a new attempt. It does not touch the running session, so the world frame is unchanged
    /// until `loadWorldMap` replaces it with the saved map's frame.
    func prepareForNewAttempt() {
        invalidatePendingTimeout()
        positionFailure = nil
        lastError = nil
        currentTile = nil
        positionMode = .unlocalized
    }

    /// Discards the world map and starts a new coordinate frame at the phone's current pose.
    func reset() {
        grid = nil; stationIcons = []; currentTile = nil
        invalidatePendingTimeout()
        positionFailure = nil
        positionMode = .unlocalized
        guard Self.isSupported else { return }
        minimumFrameTimestamp = ProcessInfo.processInfo.systemUptime
        session.delegate = self
        session.run(Self.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        pose = nil; quality = .initializing; lastError = nil; isInterrupted = false
        isRunning = true; lastPublish = 0; resetCount += 1
        startTileTimer()
    }

    // MARK: Host scan: world map

    /// Snapshot of the running session's ARWorldMap, archived with secure coding. It describes the same world
    /// frame as every pose recorded since `start`, which is why the scan takes it last, in the same session.
    func captureWorldMap() async throws -> Data {
        guard isRunning, !isInterrupted else { throw ARCaptureError.invalid("The AR session is not running.") }
        let map: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
            session.getCurrentWorldMap { map, error in
                if let map { continuation.resume(returning: map) }
                else { continuation.resume(throwing: error ?? ARCaptureError.invalid("The world map is not available yet. Look around the room and try again.")) }
            }
        }
        return try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
    }

    // MARK: Joiner map and manual fallback (Phase 4)

    /// D calls this after fetching the map with `GameClient.downloadMap()`.
    func loadWorldMap(_ data: Data) throws {
        guard Self.isSupported else { throw ARCaptureError.invalid("World tracking is unavailable on this device.") }
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw ARCaptureError.invalid("The downloaded world map is invalid.")
        }
        prepareForNewAttempt()
        grid = nil; stationIcons = []; currentTile = nil
        minimumFrameTimestamp = ProcessInfo.processInfo.systemUptime
        pose = nil; quality = .relocalizing; isInterrupted = false
        let configuration = Self.makeConfiguration()
        configuration.initialWorldMap = map
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true; lastPublish = 0
        beginRelocalizationTimeout()
        startTileTimer()
    }

    private func beginRelocalizationTimeout() {
        positionMode = .relocalizing; currentTile = nil
        relocalizationTimeout?.cancel()
        let id = attempts.next()
        relocalizationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            // Only the newest attempt may time out, and only if it is still searching.
            guard let self, attempts.isCurrent(id), positionMode == .relocalizing else { return }
            positionFailure = .timedOut
            lastError = "Relocalization timed out after 20 seconds."
            useManualMode()
        }
    }

    func useManualMode() {
        invalidatePendingTimeout()
        positionMode = .manual; currentTile = nil
        onManualModeRequested?()
    }

    // MARK: Gameplay handoff (no replacement Tile/Grid/Station model)

    /// Pass the server Grid's fields here once Models and GameClient are available.
    func configureGrid(cols: Int, rows: Int, tileSize: Double, originX: Double, originZ: Double, playable: [SIMD2<Int>]) throws {
        grid = try ServerGridTracking(cols: cols, rows: rows, tileSize: tileSize,
                                      originX: originX, originZ: originZ, playable: playable)
        currentTile = nil
        startTileTimer()
    }

    /// B/D map each Station into presentation input and supply per-player completion state.
    func setStationIcons(_ icons: [ARStationIcon], alive: Bool, lightsOut: Bool) {
        stationIcons = icons; playerAlive = alive; self.lightsOut = lightsOut
        if !alive { currentTile = nil }
    }

    private func startTileTimer() {
        tileTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportTile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tileTimer = timer
    }

    private func reportTile() {
        guard playerAlive, positionMode == .ar, isRunning, !isInterrupted,
              let position = reliablePosition, let tile = grid?.tile(at: position) else {
            currentTile = nil
            return
        }
        currentTile = tile
        // Repeated identical reports are intentional: the server applies its 2-report filter.
        onTileReport?(tile.x, tile.y, "ar")
    }

    private static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        return config
    }

    // MARK: ARSessionDelegate (explicitly delivered on main)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let position = SIMD3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
        let sample = TrackedPose(position: position, quality: TrackingQuality(frame.camera.trackingState), timestamp: frame.timestamp)
        MainActor.assumeIsolated {
            guard isRunning, !isInterrupted, frame.timestamp >= minimumFrameTimestamp else { return }
            if frame.worldMappingStatus != worldMappingStatus { worldMappingStatus = frame.worldMappingStatus }
            frameHandler?(frame)
            if positionMode == .relocalizing, sample.quality.isReliable {
                positionMode = .ar
                invalidatePendingTimeout()
                positionFailure = nil
                lastError = nil
            }
            let changed = sample.quality != quality
            quality = sample.quality
            guard changed || sample.timestamp - lastPublish >= Self.publishInterval else { return }
            lastPublish = sample.timestamp; pose = sample
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let q = TrackingQuality(camera.trackingState)
        MainActor.assumeIsolated {
            guard isRunning, !isInterrupted else { return }
            quality = q
            if !q.isReliable { pose = nil; currentTile = nil }
            if positionMode == .ar, q == .relocalizing { beginRelocalizationTimeout() }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = Self.describe(error)
        MainActor.assumeIsolated {
            lastError = message; quality = .notAvailable; isRunning = false; pose = nil
            interruptionCount += 1
            useManualMode()
            // After useManualMode, so the reason is the session failure, not a timeout.
            positionFailure = .sessionFailed(message)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            isInterrupted = true; quality = .notAvailable; pose = nil; currentTile = nil
            interruptionCount += 1
            if positionMode == .ar { positionMode = .relocalizing }
            // The clock stops while interrupted; `sessionInterruptionEnded` starts a fresh one.
            invalidatePendingTimeout()
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            isInterrupted = false
            if positionMode == .relocalizing { beginRelocalizationTimeout() }
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var message = "\(ns.localizedDescription) (code \(ns.code))"
        if let reason = ns.localizedFailureReason { message += ": " + reason }
        if ns.code == ARError.cameraUnauthorized.rawValue { message += ". Enable Camera in Settings." }
        return message
    }
}
