import ARKit
import Observation

/// Owns one coordinate frame for both host passes, map handoff and live tile tracking.
@Observable
final class ARTrackingSession: NSObject, PlayerTracking, ARSessionDelegate {
    @ObservationIgnored let session = ARSession()
    private(set) var pose: TrackedPose?
    private(set) var quality: TrackingQuality = .notAvailable
    private(set) var lastError: String?
    private(set) var isInterrupted = false
    private(set) var isRunning = false
    private(set) var resetCount = 0
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    enum CaptureStage { case overviewReady, overviewRecording, overviewSaving, edgeReady, edgeRecording, edgeSaving, mapReady, mapSaving, ready, uploading, uploaded }
    enum PositionMode: String { case unlocalized, relocalizing, ar, manual }
    private(set) var captureStage: CaptureStage = .overviewReady
    private(set) var positionMode: PositionMode = .unlocalized
    private(set) var captureStartedAt: TimeInterval?
    private(set) var overviewArtifact: CaptureArtifact?
    private(set) var edgeArtifact: CaptureArtifact?
    private(set) var mapURL: URL?
    private(set) var uploadStatus = ""
    private(set) var uploadSeconds: TimeInterval?
    private(set) var isDownloadingMap = false
    private(set) var currentTile: SIMD2<Int>?
    private(set) var stationIcons: [ARStationIcon] = []
    private(set) var playerAlive = true
    private(set) var lightsOut = false
    private(set) var grid: ServerGridTracking?

    /// D wires this to GameClient's documented tile message. It receives no raw poses.
    @ObservationIgnored var onTileReport: ((_ x: Int, _ y: Int, _ source: String) -> Void)?
    /// B presents the existing manual tile picker in response to this callback/state.
    @ObservationIgnored var onManualModeRequested: (() -> Void)?
    @ObservationIgnored private var recorder: CaptureRecorder?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var relocalizationTimeout: Task<Void, Never>?
    @ObservationIgnored private var tileTimer: Timer?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var minimumFrameTimestamp: TimeInterval = 0
    @ObservationIgnored private var lastPublish: TimeInterval = 0
    private static let publishInterval: TimeInterval = 1.0 / 15.0

    var isRecording: Bool { captureStage == .overviewRecording || captureStage == .edgeRecording }
    var isBusy: Bool {
        isDownloadingMap || isRecording || [.overviewSaving, .edgeSaving, .mapSaving, .uploading].contains(captureStage)
    }
    var iconsVisible: Bool {
        positionMode == .ar && isRunning && !isInterrupted && reliablePosition != nil && playerAlive
    }

    override init() {
        super.init()
        session.delegateQueue = .main
        session.delegate = self
    }

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
        if isRecording || captureStage == .overviewSaving || captureStage == .edgeSaving || captureStage == .mapSaving {
            invalidateCapture()
            lastError = "Capture interrupted. Record both passes again in one uninterrupted session."
        }
        session.pause()
        isRunning = false; quality = .notAvailable; pose = nil; currentTile = nil
        tileTimer?.invalidate(); tileTimer = nil
        relocalizationTimeout?.cancel(); relocalizationTimeout = nil
        if positionMode == .ar { positionMode = .relocalizing }
    }

    func reset() {
        guard captureStage != .uploading else { return }
        invalidateCapture()
        grid = nil; stationIcons = []; currentTile = nil
        relocalizationTimeout?.cancel(); relocalizationTimeout = nil
        positionMode = .unlocalized
        guard Self.isSupported else { return }
        minimumFrameTimestamp = ProcessInfo.processInfo.systemUptime
        session.delegate = self
        session.run(Self.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        pose = nil; quality = .initializing; lastError = nil; isInterrupted = false
        isRunning = true; lastPublish = 0; resetCount += 1
        startTileTimer()
    }

    // MARK: Host capture

    func startPass(_ pass: CapturePass) {
        guard isRunning, !isInterrupted, reliablePosition != nil, !isBusy,
              let frame = session.currentFrame else {
            lastError = "Wait for healthy tracking before recording."
            return
        }
        guard (pass == .overview && captureStage == .overviewReady)
                || (pass == .edge && captureStage == .edgeReady) else { return }
        do {
            recorder = try CaptureRecorder(sourceWidth: CVPixelBufferGetWidth(frame.capturedImage),
                                           sourceHeight: CVPixelBufferGetHeight(frame.capturedImage),
                                           intrinsics: frame.camera.intrinsics)
            captureStage = pass == .overview ? .overviewRecording : .edgeRecording
            captureStartedAt = ProcessInfo.processInfo.systemUptime
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func finishPass() {
        guard isRecording, let recorder else { return }
        let pass: CapturePass = captureStage == .overviewRecording ? .overview : .edge
        captureStage = pass == .overview ? .overviewSaving : .edgeSaving
        captureStartedAt = nil
        let epoch = generation
        operation = Task { [weak self] in
            do {
                let artifact = try await recorder.finish()
                guard let self, !Task.isCancelled, epoch == generation else { return }
                self.recorder = nil
                if pass == .overview {
                    overviewArtifact = artifact
                    captureStage = .edgeReady
                } else {
                    edgeArtifact = artifact
                    captureStage = .mapReady
                    await saveMapAfterCapture(epoch: epoch)
                }
            } catch {
                guard let self, !Task.isCancelled, epoch == generation else { return }
                self.recorder?.cancel(); self.recorder = nil
                captureStage = pass == .overview ? .overviewReady : .edgeReady
                lastError = error.localizedDescription
            }
        }
    }

    func cancelCapture() {
        guard captureStage != .uploading else { return }
        invalidateCapture()
    }

    private func invalidateCapture() {
        generation += 1
        operation?.cancel(); operation = nil
        let discardedFiles = Set([recorder?.directory, overviewArtifact?.directory,
                                  edgeArtifact?.directory, mapURL].compactMap { $0 })
        recorder?.cancel(); recorder = nil
        overviewArtifact = nil; edgeArtifact = nil; mapURL = nil
        captureStartedAt = nil; captureStage = .overviewReady
        uploadStatus = ""; uploadSeconds = nil; isDownloadingMap = false
        // These URLs are generated by this capture flow in the app's temporary directory.
        for file in discardedFiles { try? FileManager.default.removeItem(at: file) }
    }

    func retrySaveMap() {
        guard captureStage == .mapReady else { return }
        let epoch = generation
        operation = Task { [weak self] in await self?.saveMapAfterCapture(epoch: epoch) }
    }

    private func saveMapAfterCapture(epoch: Int) async {
        guard edgeArtifact != nil, overviewArtifact != nil, isRunning, reliablePosition != nil else {
            lastError = "Wait for healthy tracking, then retry saving the map."
            return
        }
        captureStage = .mapSaving
        do {
            let map: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
                session.getCurrentWorldMap { map, error in
                    if let map { continuation.resume(returning: map) }
                    else { continuation.resume(throwing: error ?? ARCaptureError.invalid("World map unavailable. Scan more of the room and retry.")) }
                }
            }
            guard !Task.isCancelled, epoch == generation else { return }
            let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".arworldmap")
            try data.write(to: file, options: .atomic)
            mapURL = file; captureStage = .ready; positionMode = .ar
            relocalizationTimeout?.cancel(); relocalizationTimeout = nil
            lastError = nil
        } catch {
            guard !Task.isCancelled, epoch == generation else { return }
            captureStage = .mapReady; lastError = error.localizedDescription
        }
    }

    func uploadCapture(baseURL: URL, room: String) {
        guard captureStage == .ready, let overviewArtifact, let edgeArtifact, let mapURL else { return }
        let transport = ARCaptureTransport(baseURL: baseURL, room: room.uppercased())
        captureStage = .uploading; lastError = nil
        let started = ProcessInfo.processInfo.systemUptime
        let epoch = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                uploadStatus = "Uploading overview…"
                try await transport.upload(overviewArtifact, pass: .overview)
                uploadStatus = "Uploading edge walk…"
                try await transport.upload(edgeArtifact, pass: .edge)
                uploadStatus = "Uploading world map…"
                try await transport.uploadMap(mapURL)
                uploadSeconds = ProcessInfo.processInfo.systemUptime - started
                uploadStatus = "Requesting server processing…"
                try await transport.process()
                guard !Task.isCancelled, epoch == generation else { return }
                captureStage = .uploaded
                uploadStatus = "Uploaded. Waiting for setup from GameClient."
            } catch {
                guard !Task.isCancelled, epoch == generation else { return }
                captureStage = .ready; uploadStatus = "Upload failed; ready to retry."
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Joiner map and manual fallback

    func downloadMap(baseURL: URL, room: String) {
        guard !isBusy else { return }
        operation?.cancel()
        isDownloadingMap = true; positionMode = .unlocalized; currentTile = nil; lastError = nil
        let transport = ARCaptureTransport(baseURL: baseURL, room: room.uppercased())
        let epoch = generation
        operation = Task { [weak self] in
            do {
                let data = try await transport.downloadMap()
                guard let self, !Task.isCancelled, epoch == generation else { return }
                isDownloadingMap = false
                try loadWorldMap(data)
            } catch {
                guard let self, !Task.isCancelled, epoch == generation else { return }
                isDownloadingMap = false
                lastError = error.localizedDescription
                useManualMode()
            }
        }
    }

    /// D may call this directly after fetching the documented binary endpoint.
    func loadWorldMap(_ data: Data) throws {
        guard Self.isSupported, !isBusy else { throw ARCaptureError.invalid("Stop capture before loading a world map.") }
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw ARCaptureError.invalid("The downloaded world map is invalid.")
        }
        invalidateCapture()
        grid = nil; stationIcons = []; currentTile = nil
        minimumFrameTimestamp = ProcessInfo.processInfo.systemUptime
        pose = nil; quality = .relocalizing; isInterrupted = false; lastError = nil
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
        relocalizationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, positionMode == .relocalizing else { return }
            lastError = "Relocalization timed out after 20 seconds. Use the manual tile picker."
            useManualMode()
        }
    }

    func useManualMode() {
        if isDownloadingMap {
            operation?.cancel(); isDownloadingMap = false
        }
        relocalizationTimeout?.cancel(); relocalizationTimeout = nil
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
            if isRecording {
                guard sample.quality.isReliable else {
                    invalidateCapture()
                    lastError = "Tracking was lost while recording. Record both passes again."
                    return
                }
                do { try recorder?.append(pixelBuffer: frame.capturedImage, timestamp: frame.timestamp, transform: frame.camera.transform) }
                catch { invalidateCapture(); lastError = error.localizedDescription }
            }
            if positionMode == .relocalizing, sample.quality.isReliable {
                positionMode = .ar
                relocalizationTimeout?.cancel(); relocalizationTimeout = nil
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
            if isRecording || captureStage == .overviewSaving || captureStage == .edgeSaving || captureStage == .mapSaving { invalidateCapture() }
            lastError = message; quality = .notAvailable; isRunning = false; pose = nil
            useManualMode()
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            isInterrupted = true; quality = .notAvailable; pose = nil; currentTile = nil
            if isRecording || captureStage == .overviewSaving || captureStage == .edgeSaving || captureStage == .mapSaving {
                invalidateCapture()
                lastError = "Capture interrupted. Record both passes again."
            }
            if positionMode == .ar { positionMode = .relocalizing }
            relocalizationTimeout?.cancel()
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
