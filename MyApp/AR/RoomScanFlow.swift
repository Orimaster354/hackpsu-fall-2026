import CoreVideo
import Foundation
import Observation
import simd

/// One camera frame as the flow sees it. The pixel buffer is only touched when a sweep frame is due.
struct FrameInput {
    var sample: FrameSample
    var pixelBuffer: CVPixelBuffer?
}

/// Everything the flow needs from the outside world. The live implementation wraps ARKit, `ScanClient`
/// and `GameClient`; tests use a fake.
@MainActor
protocol ScanBackend: AnyObject {
    /// The grid the server last broadcast (`setup`), in the host's ARKit world frame.
    var grid: MapGrid? { get }
    func uploadPerimeter(_ poses: [PoseSample]) async throws -> PerimeterResult
    func uploadSweep(vantage: Tile, intrinsics: CameraIntrinsics, frames: [SweepFrame]) async throws -> SweepResult
    /// Archived ARWorldMap bytes of the running session.
    func captureWorldMap(progress: @escaping @MainActor (String) -> Void) async throws -> Data
    func uploadWorldMap(_ data: Data) async throws
    /// Largest pixel disagreement between the documented projection math and ARKit's own, or nil if unavailable.
    func projectionSelfCheck() -> Double?
    /// How many `setup` events the server has sent so far. It rises on every event, even when the new grid equals
    /// the old one. Backends that cannot count return 0, and the flow then falls back to comparing grids.
    var setupRevision: Int { get }
    /// How complete ARKit's map of the room was when `captureWorldMap` last saved it, or nil if unknown.
    var lastWorldMapQuality: WorldMapQuality? { get }
}

extension ScanBackend {
    var setupRevision: Int { 0 }
    var lastWorldMapQuality: WorldMapQuality? { nil }
}

/// How well ARKit had mapped the room when the world map was saved. A map saved before it is `mapped` or
/// `extending` can fail to relocalize on other phones.
enum WorldMapQuality: Equatable {
    case mapped, extending, limited, notAvailable

    var isComplete: Bool { self == .mapped || self == .extending }

    var label: String {
        switch self {
        case .mapped: "complete"
        case .extending: "complete, still extending"
        case .limited: "incomplete (limited)"
        case .notAvailable: "unavailable"
        }
    }

    /// What to tell the host when the map is not complete, nil when it is fine.
    var warning: String? {
        isComplete ? nil : "The room was only partly mapped (\(label)). Other phones may fail to find their place. Scan the room again, walking slowly and looking at the walls and floor, or expect to use manual tiles."
    }
}

/// Host room scan (docs/ar-capture.md): perimeter walk, vantage pick, sweep, world map. One AR session
/// for all of it. If the session is interrupted the whole scan starts over, because the poses of the
/// earlier steps would no longer share a frame with the map.
@MainActor
@Observable
final class RoomScanFlow {
    enum Step: Equatable {
        case idle, perimeter, uploadingPerimeter, pickingVantage, walkingToVantage
        case sweeping, uploadingSweep, savingMap, done
    }

    struct ReportLine: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        var warn = false
    }

    /// Matches the server's ARWorldMap upload cap (server/maps.js, 64 MiB).
    static let maxMapBytes = 64 * 1024 * 1024
    static let gridWait: Duration = .seconds(8)

    // MARK: Observable state

    private(set) var step: Step = .idle
    /// Last error or instruction for the host. Cleared when a step starts.
    private(set) var message: String?
    private(set) var isTracking = false
    private(set) var livePosition: SIMD3<Float>?
    private(set) var detail = ""

    // Perimeter
    private(set) var perimeterSamples = 0
    private(set) var perimeterElapsed = 0.0
    private(set) var perimeterPath = 0.0
    private(set) var perimeterGap: Double?
    private(set) var perimeterClosed = false

    // Vantage
    private(set) var grid: MapGrid?
    private(set) var chosenTile: MapTile?

    // Sweep
    private(set) var sweepProgress = 0.0
    private(set) var sweepDegrees = 0.0
    private(set) var sweepElapsed = 0.0
    private(set) var sweepFrameCount = 0
    private(set) var sweepTurnRate: Double?
    private(set) var sweepDrifted = false
    private(set) var hasPendingSweep = false

    // World map
    private(set) var mapNote = ""
    private(set) var mapFailed = false

    private(set) var report: [ReportLine] = []

    let backend: ScanBackend

    // MARK: Private state

    @ObservationIgnored private var recorder = PerimeterRecorder()
    @ObservationIgnored private var sampler = SweepSampler()
    @ObservationIgnored private var lastSample: FrameSample?
    @ObservationIgnored private var lastPublish = -Double.infinity
    @ObservationIgnored private var lastSweepPublish = -Double.infinity
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private var encoding = false
    @ObservationIgnored private var sweepEnding = false
    @ObservationIgnored private var sweepFrames: [SweepFrame] = []
    @ObservationIgnored private var sweepIntrinsics: [CameraIntrinsics] = []
    @ObservationIgnored private var sweepBytes: [Int] = []
    @ObservationIgnored private var sweepQualities: [Double] = []
    @ObservationIgnored private var encodeFailures = 0
    @ObservationIgnored private var sweepStart: SIMD3<Float>?
    @ObservationIgnored private var selfCheckError: Double?
    @ObservationIgnored private var pendingSweep: SweepUpload?
    @ObservationIgnored private var sweepResult: SweepResult?
    @ObservationIgnored private var mapBytes = 0
    /// How complete the saved map was, from the backend. nil until a map is saved, or when the backend cannot say.
    private(set) var mapQuality: WorldMapQuality?

    init(backend: ScanBackend) {
        self.backend = backend
    }

    // MARK: Derived

    var liveTile: MapTile? {
        guard let grid, let p = livePosition else { return nil }
        let tile = grid.tile(atX: Double(p.x), z: Double(p.z))
        return grid.contains(tile) ? tile : nil
    }

    var isOnChosenTile: Bool { chosenTile != nil && liveTile == chosenTile }

    var canStartPerimeter: Bool { step == .idle && isTracking }

    var canFinishPerimeter: Bool {
        step == .perimeter && !perimeterClosed && isTracking
            && perimeterSamples >= PerimeterUpload.minSamples
            && (perimeterGap ?? .infinity) <= PerimeterRecorder.closeGap
    }

    var canStartSweep: Bool { step == .walkingToVantage && isTracking && isOnChosenTile && !hasPendingSweep }

    /// The camera is needed (pixel buffer) only while a sweep frame may be taken.
    var wantsPixelBuffer: Bool { step == .sweeping && !encoding && !sweepEnding }

    var isBusyUploading: Bool { step == .uploadingPerimeter || step == .uploadingSweep }

    /// True while a sweep frame is being turned into a JPEG off the main thread.
    var isEncodingFrame: Bool { encoding }

    // MARK: Frames

    func handle(_ input: FrameInput) {
        let sample = input.sample
        lastSample = sample
        publishLive(sample)
        switch step {
        case .perimeter where !perimeterClosed:
            if recorder.add(sample) { publishPerimeter() }
        case .sweeping:
            handleSweep(input)
        default:
            break
        }
    }

    private func publishLive(_ sample: FrameSample) {
        if sample.isTracking != isTracking { isTracking = sample.isTracking }
        guard sample.timestamp - lastPublish >= 0.1 else { return }
        lastPublish = sample.timestamp
        if sample.isFinite { livePosition = sample.position }
        if step == .perimeter, !perimeterClosed {
            perimeterGap = recorder.gapToStart(from: sample.position)
        }
    }

    private func publishPerimeter() {
        perimeterSamples = recorder.count
        perimeterElapsed = recorder.elapsed
        perimeterPath = recorder.pathLength
    }

    // MARK: Step 1: perimeter

    func startPerimeter() {
        guard canStartPerimeter else { return }
        resetCaptureData()
        message = nil
        step = .perimeter
    }

    func finishPerimeter() {
        guard step == .perimeter else { return }
        if !perimeterClosed {
            if let lastSample { recorder.add(lastSample, force: true) }
            publishPerimeter()
        }
        if let problem = recorder.problem {
            switch problem {
            case let .tooShort(samples):
                message = "Only \(samples) poses recorded. Walk the whole room edge (at least \(PerimeterUpload.minSamples) poses, about 10 s)."
            case let .openLoop(gap):
                message = String(format: "You ended %.1f m from where you started. Walk back to the start (within %.2f m).", gap, PerimeterRecorder.closeGap)
            }
            return
        }
        perimeterClosed = true
        message = nil
        step = .uploadingPerimeter
        detail = "Uploading \(recorder.count) poses…"
        let poses = recorder.samples
        let before = backend.grid
        let revisionBefore = backend.setupRevision
        launch { [self] epoch in await runPerimeterUpload(poses, gridBefore: before, revisionBefore: revisionBefore, epoch: epoch) }
    }

    /// Throw away the walk and record a new one in the same session.
    func restartPerimeter() {
        guard step == .perimeter || step == .idle else { return }
        resetCaptureData()
        message = nil
        step = .idle
    }

    private func runPerimeterUpload(_ poses: [PoseSample], gridBefore: MapGrid?, revisionBefore: Int, epoch: Int) async {
        do {
            let result = try await backend.uploadPerimeter(poses)
            guard alive(epoch), step == .uploadingPerimeter else { return }
            detail = "Building the room map…"
            guard let newGrid = await waitForGrid(result: result, before: gridBefore, revisionBefore: revisionBefore, epoch: epoch) else {
                guard alive(epoch) else { return }
                step = .perimeter
                message = "The server accepted the walk but did not send the room map. Tap Done to upload again."
                return
            }
            guard alive(epoch) else { return }
            grid = newGrid
            chosenTile = Vantage.suggested(in: newGrid)
            message = nil
            step = .pickingVantage
        } catch {
            guard alive(epoch), step == .uploadingPerimeter else { return }
            let failure = Self.describe(error)
            if failure.code == "SCAN_FAILED" {
                // Open loop, too small, or no usable path: the walk itself is bad.
                resetCaptureData()
                step = .idle
                message = failure.message + " Walk the room again."
            } else {
                step = .perimeter
                message = failure.message
            }
        }
    }

    /// Waits for the server's `setup` for this upload. A new `setup` event is the acknowledgement, not a changed
    /// grid: uploading the same walk again legitimately produces an identical grid, and the server still sends
    /// a fresh event. The event may even arrive before the HTTP answer, which is why the count is taken before
    /// the upload starts. Backends that cannot count (revision stays 0) fall back to a changed grid.
    private func waitForGrid(result: PerimeterResult, before: MapGrid?, revisionBefore: Int, epoch: Int) async -> MapGrid? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.gridWait)
        while clock.now < deadline, alive(epoch) {
            if let grid = backend.grid, grid.cols == result.cols, grid.rows == result.rows,
               Self.isFreshSetup(revision: backend.setupRevision, revisionBefore: revisionBefore, grid: grid, before: before) {
                return grid
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// A `setup` counts as fresh when the event count went up, or, for a backend without a count, the grid changed.
    static func isFreshSetup(revision: Int, revisionBefore: Int, grid: MapGrid, before: MapGrid?) -> Bool {
        if revision > revisionBefore { return true }
        return revision == 0 && revisionBefore == 0 && grid != before
    }

    // MARK: Step 2: vantage

    func choose(_ tile: MapTile) {
        guard step == .pickingVantage || step == .walkingToVantage, let grid, grid.contains(tile) else { return }
        chosenTile = tile
    }

    func confirmVantage() {
        guard step == .pickingVantage, chosenTile != nil else { return }
        message = nil
        step = .walkingToVantage
    }

    func changeVantage() {
        guard step == .walkingToVantage, !hasPendingSweep else { return }
        step = .pickingVantage
    }

    // MARK: Step 3: sweep

    func startSweep() {
        guard canStartSweep else { return }
        resetSweepData()
        lastSweepPublish = -.infinity
        selfCheckError = backend.projectionSelfCheck()
        sweepStart = livePosition
        message = nil
        step = .sweeping
    }

    private func handleSweep(_ input: FrameInput) {
        let sample = input.sample
        sampler.observe(sample)
        // The sampler sees every frame (about 60 Hz); the screen only needs 10 Hz.
        if sample.timestamp - lastSweepPublish >= 0.1 {
            lastSweepPublish = sample.timestamp
            sweepProgress = sampler.progress
            sweepDegrees = sampler.yawDegrees
            sweepElapsed = sampler.elapsed
            sweepTurnRate = sampler.turnRate
            if let sweepStart, sample.isFinite {
                sweepDrifted = CameraMath.horizontalDistance(sample.position, sweepStart) > 1.0
            }
        }
        if sweepEnding { return }
        if sampler.isComplete {
            sweepEnding = true
            completeSweepIfIdle()
            return
        }
        guard !encoding, let buffer = input.pixelBuffer else { return }
        if sampler.verdict(for: sample) == .take {
            sampler.markTaken()
            dispatchEncode(buffer, sample: sample, t: sampler.elapsed)
        }
    }

    private func dispatchEncode(_ buffer: CVPixelBuffer, sample: FrameSample, t: Double) {
        encoding = true
        let epoch = generation
        let box = PixelBufferBox(buffer)
        let pose = CameraPose(transform: sample.transform)
        let k = sample.intrinsics
        let resolution = (w: sample.imageWidth, h: sample.imageHeight)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SweepFrameEncoder.encode(box.buffer) }
            await MainActor.run { [weak self] in
                self?.encoded(result, epoch: epoch, t: t, pose: pose, k: k, resolution: resolution)
            }
        }
    }

    private func encoded(_ result: Result<EncodedSweepImage, Error>, epoch: Int, t: Double, pose: CameraPose,
                         k: simd_float3x3, resolution: (w: Double, h: Double)) {
        guard epoch == generation else { return }
        encoding = false
        switch result {
        case let .failure(error):
            encodeFailures += 1
            if encodeFailures >= 5 { abortSweep("Could not encode camera frames: \(error.localizedDescription)"); return }
        case let .success(image):
            // The JPEG must describe the same pixels as the intrinsics: check the first one by decoding it.
            if sweepFrames.isEmpty {
                guard let seen = SweepFrameEncoder.inspect(image.jpeg),
                      seen.width == image.width, seen.height == image.height, seen.isUpright else {
                    abortSweep("The JPEG does not match the camera image (size or orientation). Not uploading a sweep that would misplace notes.")
                    return
                }
            }
            // Pixels of the JPEG per pixel the intrinsics are expressed in.
            let sx = Double(image.width) / resolution.w
            let sy = Double(image.height) / resolution.h
            let intrinsics = CameraIntrinsics(fx: Double(k.columns.0.x) * sx, fy: Double(k.columns.1.y) * sy,
                                              cx: Double(k.columns.2.x) * sx, cy: Double(k.columns.2.y) * sy,
                                              width: image.width, height: image.height)
            if let first = sweepIntrinsics.first, first.width != intrinsics.width || first.height != intrinsics.height {
                encodeFailures += 1
            } else {
                sweepFrames.append(SweepFrame(index: sweepFrames.count, t: t, pose: pose, jpegData: image.jpeg))
                sweepIntrinsics.append(intrinsics)
                sweepBytes.append(image.jpeg.count)
                sweepQualities.append(image.quality)
                sweepFrameCount = sweepFrames.count
            }
        }
        completeSweepIfIdle()
    }

    private func completeSweepIfIdle() {
        guard sweepEnding, !encoding, step == .sweeping else { return }
        let count = sweepFrames.count
        guard count >= SweepSampler.minGoodFrames else {
            resetSweepData()
            step = .walkingToVantage
            message = "Only \(count) usable frames (need \(SweepSampler.minGoodFrames)). Turn more slowly, about 10 to 12° per second, keep the walls in view, and sweep again."
            return
        }
        let intrinsics = Self.medianIntrinsics(sweepIntrinsics)
        guard let vantage = chosenTile else { return }
        pendingSweep = SweepUpload(vantage: Tile(x: vantage.x, y: vantage.y), intrinsics: intrinsics, frames: sweepFrames)
        hasPendingSweep = true
        report = makeSweepReport(median: intrinsics)
        message = nil
        startSweepUpload()
    }

    private func abortSweep(_ text: String) {
        resetSweepData()
        step = .walkingToVantage
        message = text
    }

    /// Abandon the turn in progress and go back to the vantage tile.
    func cancelSweep() {
        guard step == .sweeping else { return }
        resetSweepData()
        message = nil
        step = .walkingToVantage
    }

    func retrySweepUpload() {
        guard step == .walkingToVantage, pendingSweep != nil else { return }
        startSweepUpload()
    }

    /// Discard the captured frames and turn again.
    func redoSweep() {
        guard step == .walkingToVantage else { return }
        resetSweepData()
        message = nil
    }

    private func startSweepUpload() {
        guard let upload = pendingSweep else { return }
        step = .uploadingSweep
        message = nil
        let megabytes = Double(upload.frames.reduce(0) { $0 + $1.jpeg.utf8.count }) / 1_048_576
        detail = String(format: "Uploading %d frames (%.1f MB)…", upload.frames.count, megabytes)
        launch { [self] epoch in await runSweepUpload(upload, epoch: epoch) }
    }

    private func runSweepUpload(_ upload: SweepUpload, epoch: Int) async {
        do {
            let result = try await backend.uploadSweep(vantage: upload.vantage, intrinsics: upload.intrinsics, frames: upload.frames)
            guard alive(epoch), step == .uploadingSweep else { return }
            sweepResult = result
            pendingSweep = nil
            hasPendingSweep = false
            await saveMap(epoch: epoch)
        } catch {
            guard alive(epoch), step == .uploadingSweep else { return }
            let failure = Self.describe(error)
            if failure.code == "SETUP_MISSING" {
                // The server lost the perimeter (restart). The poses in this sweep no longer belong to any grid.
                resetCaptureData()
                step = .idle
                message = failure.message + " Start the scan again from the perimeter walk."
            } else {
                step = .walkingToVantage
                message = failure.message
            }
        }
    }

    // MARK: Step 4: world map

    func retryMap() {
        guard step == .savingMap, mapFailed else { return }
        launch { [self] epoch in await saveMap(epoch: epoch) }
    }

    private func saveMap(epoch: Int) async {
        step = .savingMap
        mapFailed = false
        message = nil
        mapNote = "Preparing the AR world map…"
        do {
            let data = try await backend.captureWorldMap { [weak self] note in self?.mapNote = note }
            guard alive(epoch) else { return }
            guard data.count <= Self.maxMapBytes else {
                throw ScanFlowError.map("The AR world map is \(data.count / 1_048_576) MiB, over the server's \(Self.maxMapBytes / 1_048_576) MiB limit.")
            }
            mapNote = String(format: "Uploading the world map (%.1f MB)…", Double(data.count) / 1_048_576)
            try await backend.uploadWorldMap(data)
            guard alive(epoch) else { return }
            mapBytes = data.count
            mapQuality = backend.lastWorldMapQuality
            report = makeFinalReport()
            step = .done
            mapNote = ""
        } catch {
            guard alive(epoch) else { return }
            mapFailed = true
            message = Self.describe(error).message
        }
    }

    // MARK: Lifecycle

    /// The AR session was interrupted or failed. Poses taken before and after would not share one frame.
    func sessionInterrupted() {
        guard step != .idle, step != .done else { return }
        cancelWork()
        resetCaptureData()
        step = .idle
        message = "AR tracking was interrupted, so the scan has to start over. Keep the app open and the camera uncovered."
    }

    func cancel() {
        cancelWork()
        resetCaptureData()
        step = .idle
        message = nil
    }

    private func launch(_ body: @escaping @MainActor (Int) async -> Void) {
        task?.cancel()
        let epoch = generation
        task = Task { await body(epoch) }
    }

    private func alive(_ epoch: Int) -> Bool { epoch == generation && !Task.isCancelled }

    private func cancelWork() {
        generation += 1
        task?.cancel()
        task = nil
        encoding = false
    }

    private func resetCaptureData() {
        recorder = PerimeterRecorder()
        perimeterSamples = 0
        perimeterElapsed = 0
        perimeterPath = 0
        perimeterGap = nil
        perimeterClosed = false
        grid = nil
        chosenTile = nil
        pendingSweep = nil
        hasPendingSweep = false
        sweepResult = nil
        mapFailed = false
        mapNote = ""
        mapQuality = nil
        report = []
        resetSweepData()
    }

    private func resetSweepData() {
        generation += 1   // drops any encode still in flight
        sampler = SweepSampler()
        encoding = false
        sweepEnding = false
        sweepFrames = []
        sweepIntrinsics = []
        sweepBytes = []
        sweepQualities = []
        encodeFailures = 0
        sweepStart = nil
        sweepProgress = 0
        sweepDegrees = 0
        sweepElapsed = 0
        sweepFrameCount = 0
        sweepTurnRate = nil
        sweepDrifted = false
        pendingSweep = nil
        hasPendingSweep = false
    }

    // MARK: Reports and helpers

    static func medianIntrinsics(_ all: [CameraIntrinsics]) -> CameraIntrinsics {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        return CameraIntrinsics(fx: median(all.map(\.fx)), fy: median(all.map(\.fy)),
                                cx: median(all.map(\.cx)), cy: median(all.map(\.cy)),
                                width: all.first?.width ?? 0, height: all.first?.height ?? 0)
    }

    private func makeSweepReport(median: CameraIntrinsics) -> [ReportLine] {
        let kib = sweepBytes.map { Double($0) / 1024 }
        let totalMB = Double(sweepBytes.reduce(0, +)) / 1_048_576
        let spreadFx = (sweepIntrinsics.map(\.fx).max() ?? 0) - (sweepIntrinsics.map(\.fx).min() ?? 0)
        let spreadC = max((sweepIntrinsics.map(\.cx).max() ?? 0) - (sweepIntrinsics.map(\.cx).min() ?? 0),
                          (sweepIntrinsics.map(\.cy).max() ?? 0) - (sweepIntrinsics.map(\.cy).min() ?? 0))
        var lines = [
            ReportLine(label: "Sweep frames", value: "\(sweepFrames.count) (need ≥ \(SweepSampler.minGoodFrames))"),
            ReportLine(label: "JPEG size", value: "\(median.width)×\(median.height) px, \(Int(kib.min() ?? 0))–\(Int(kib.max() ?? 0)) KiB each, \(String(format: "%.1f", totalMB)) MB total",
                       warn: (kib.max() ?? 0) > 600),
            ReportLine(label: "JPEG quality", value: String(format: "%.1f–%.1f", sweepQualities.min() ?? 0, sweepQualities.max() ?? 0)),
            ReportLine(label: "Intrinsics", value: String(format: "fx %.1f fy %.1f cx %.1f cy %.1f", median.fx, median.fy, median.cx, median.cy)),
            ReportLine(label: "Intrinsics drift", value: String(format: "fx %.2f px, principal point %.2f px across frames", spreadFx, spreadC),
                       warn: spreadFx > median.fx * 0.02 || spreadC > 4),
            ReportLine(label: "Turn", value: String(format: "%.0f° in %.0f s", sampler.yawDegrees, sampler.elapsed)),
        ]
        if let selfCheckError {
            lines.append(ReportLine(label: "Projection check", value: String(format: "documented math vs ARKit: %.2f px", selfCheckError),
                                    warn: selfCheckError > 3))
        }
        if encodeFailures > 0 {
            lines.append(ReportLine(label: "Dropped frames", value: "\(encodeFailures) could not be encoded", warn: true))
        }
        return lines
    }

    private func makeFinalReport() -> [ReportLine] {
        var lines = report
        if let result = sweepResult {
            lines.append(ReportLine(label: "Server notes found", value: "\(result.notesFound) (goal ≥ 4)", warn: result.notesFound < 4))
            lines.append(ReportLine(label: "Server stations", value: "\(result.stations)"))
            for warning in result.warnings { lines.append(ReportLine(label: "Server warning", value: warning, warn: true)) }
        }
        lines.append(ReportLine(label: "World map", value: String(format: "%.1f MB uploaded", Double(mapBytes) / 1_048_576)))
        if let quality = mapQuality {
            lines.append(ReportLine(label: "Map quality", value: quality.label, warn: !quality.isComplete))
            if let warning = quality.warning { lines.append(ReportLine(label: "Map warning", value: warning, warn: true)) }
        }
        return lines
    }

    struct Failure: Equatable {
        let message: String
        let code: String?
    }

    static func describe(_ error: Error) -> Failure {
        if let scan = error as? ScanClient.ScanError {
            switch scan {
            case .notInRoom: return Failure(message: "You are not in a room. Create the room first.", code: nil)
            case .badAddress: return Failure(message: "Check the server address in Settings.", code: nil)
            case let .invalid(text): return Failure(message: text, code: nil)
            case let .server(status, code, message): return Failure(message: "\(message) (\(code), HTTP \(status))", code: code)
            case .badResponse: return Failure(message: "The server answered in a format the app does not understand.", code: nil)
            }
        }
        if let map = error as? GameClient.MapError {
            switch map {
            case .notInRoom: return Failure(message: "You are not in a room.", code: nil)
            case .badURL: return Failure(message: "Check the server address in Settings.", code: nil)
            case let .http(status): return Failure(message: "The server rejected the world map (HTTP \(status)). Only the host can upload it, in the lobby.", code: "HTTP_\(status)")
            }
        }
        if let flow = error as? ScanFlowError, case let .map(text) = flow { return Failure(message: text, code: nil) }
        return Failure(message: error.localizedDescription, code: nil)
    }
}

enum ScanFlowError: Error, Equatable {
    case map(String)
}

/// `CVPixelBuffer` is thread safe for reading but not marked Sendable. The encoder only reads it.
nonisolated struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
