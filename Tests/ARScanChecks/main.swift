import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Observation
import simd

// Mac-side checks for the host scan (run MyApp/AR/Tests/run_scan_checks.sh). No ARKit, no device.
// These prove the logic and the image/intrinsics bookkeeping. They do NOT prove ARKit's real axis
// conventions or anything about a physical room; that needs the iPhone test in MyApp/AR/README.md.

var checks = 0
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok() { return }
    failures += 1
    print("FAIL: \(name) \(detail())")
}
func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

guard CommandLine.arguments.count >= 3 else {
    print("usage: ScanChecks <repo root> <output dir>")
    exit(2)
}
let repo = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: Fixtures and builders

struct FixturePose: Decodable { var t, x, y, z, qx, qy, qz, qw: Double }
struct SetupFixture: Decodable { var grid: Grid }

let walk = try JSONDecoder().decode([FixturePose].self, from: Data(contentsOf: repo.appending(path: "docs/fixtures/poses.json")))
let setupFixture = try JSONDecoder().decode(SetupFixture.self, from: Data(contentsOf: repo.appending(path: "docs/fixtures/setup.json")))
let fixtureGrid = MapGrid(cols: setupFixture.grid.cols, rows: setupFixture.grid.rows, tileSize: setupFixture.grid.tileSize,
                          originX: setupFixture.grid.originX, originZ: setupFixture.grid.originZ,
                          playable: Set(setupFixture.grid.playable.map { MapTile(x: $0.x, y: $0.y) }),
                          edge: Set(setupFixture.grid.edge.map { MapTile(x: $0.x, y: $0.y) }))

func transform(position: SIMD3<Float>, rotation: simd_quatf) -> simd_float4x4 {
    var m = simd_float4x4(rotation)
    m.columns.3 = SIMD4(position.x, position.y, position.z, 1)
    return m
}

/// Camera at `position` turned `degrees` about +Y (and tilted up by `pitch` degrees).
func look(_ position: SIMD3<Float>, turn degrees: Double, pitch: Double = 0) -> simd_float4x4 {
    let yaw = simd_quatf(angle: Float(degrees * .pi / 180), axis: SIMD3(0, 1, 0))
    let tilt = simd_quatf(angle: Float(pitch * .pi / 180), axis: SIMD3(1, 0, 0))
    return transform(position: position, rotation: yaw * tilt)
}

func intrinsicsMatrix(fx: Float, fy: Float, cx: Float, cy: Float) -> simd_float3x3 {
    simd_float3x3(columns: (SIMD3(fx, 0, 0), SIMD3(0, fy, 0), SIMD3(cx, cy, 1)))
}
// What ARKit reports for a 1920 x 1440 capturedImage (4:3 sensor image).
let k1440 = intrinsicsMatrix(fx: 1450, fy: 1450, cx: 960, cy: 720)
let k1080 = intrinsicsMatrix(fx: 1450, fy: 1450, cx: 960, cy: 540)

func sample(_ t: Double, _ m: simd_float4x4, tracking: Bool = true, k: simd_float3x3 = k1440,
            w: Double = 1920, h: Double = 1440) -> FrameSample {
    FrameSample(timestamp: 1000 + t, transform: m, intrinsics: k, imageWidth: w, imageHeight: h, isTracking: tracking)
}

/// The fixture perimeter walk resampled to 60 Hz.
func walkFrames(from startTime: Double = 0, dropout: ClosedRange<Double>? = nil) -> [FrameSample] {
    var frames: [FrameSample] = []
    let end = walk.last!.t
    var t = 0.0
    while t <= end {
        let i = min(Int(t / 0.1), walk.count - 2)
        let a = walk[i], b = walk[i + 1]
        let f = (t - a.t) / (b.t - a.t)
        let position = SIMD3<Float>(Float(a.x + (b.x - a.x) * f), Float(a.y), Float(a.z + (b.z - a.z) * f))
        let q = simd_quatf(ix: Float(a.qx), iy: Float(a.qy), iz: Float(a.qz), r: Float(a.qw)).normalized
        frames.append(sample(startTime + t, transform(position: position, rotation: q), tracking: !(dropout?.contains(t) ?? false)))
        t += 1.0 / 60
    }
    return frames
}

// MARK: 1. Heading, pitch, yaw accumulation

do {
    let identity = matrix_identity_float4x4
    check(simd_distance(CameraMath.forward(identity), SIMD3(0, 0, -1)) < 1e-6, "identity camera looks along -z")
    check(near(CameraMath.heading(identity) ?? 99, 0, 1e-6), "heading 0 looking along -z")
    let east = look(.zero, turn: -90)
    check(simd_distance(CameraMath.forward(east), SIMD3(1, 0, 0)) < 1e-5, "turning -90 deg about +Y faces +x")
    check(near(CameraMath.heading(east) ?? 99, .pi / 2, 1e-5), "heading grows toward +x")
    check(CameraMath.heading(look(.zero, turn: 0, pitch: 89)) == nil, "no heading when looking straight up")
    check(near(CameraMath.pitchDegrees(look(.zero, turn: 0, pitch: 30)), 30, 0.01), "pitch up 30 deg")
    check(near(CameraMath.horizontalDistance(SIMD3(0, 5, 0), SIMD3(3, -9, 4)), 5, 1e-6), "horizontal distance ignores height")

    var yaw = YawAccumulator()
    for degrees in stride(from: 170.0, through: 190.0, by: 2.0) {   // crosses the +-180 seam
        var h = degrees; if h > 180 { h -= 360 }
        yaw.add(h * .pi / 180)
    }
    check(near(yaw.degrees, 20, 0.01), "yaw accumulates across the +-180 seam", "got \(yaw.degrees)")
    var jitter = YawAccumulator()
    for i in 0..<100 { jitter.add((i % 2 == 0 ? 0.05 : -0.05)) }
    check(jitter.degrees < 6.5, "back and forth jitter nets one step, it does not accumulate", "got \(jitter.degrees)")
}

// MARK: 2. Sweep sampler

struct SweepRun { var sampler = SweepSampler(); var takes: [Double] = []; var skippedFast = 0; var skippedTracking = 0 }

func runSweep(rate: Double, seconds: Double, lossDuring: ClosedRange<Double>? = nil) -> SweepRun {
    var run = SweepRun()
    var t = 0.0
    while t <= seconds {
        let f = sample(t, look(SIMD3(2, 1.4, 2), turn: rate * t), tracking: !(lossDuring?.contains(t) ?? false))
        run.sampler.observe(f)
        if run.sampler.isComplete { break }
        switch run.sampler.verdict(for: f) {
        case .take: run.sampler.markTaken(); run.takes.append(run.sampler.elapsed)
        case .skipTooFast: run.skippedFast += 1
        case .skipTracking: run.skippedTracking += 1
        case .wait: break
        }
        t += 1.0 / 60
    }
    return run
}

do {
    let good = runSweep(rate: 12, seconds: 60)
    check(good.sampler.isComplete && good.sampler.yawDegrees >= 340, "12 deg/s sweep completes at 340 deg", "yaw \(good.sampler.yawDegrees)")
    check(near(good.sampler.elapsed, 340 / 12, 0.1), "12 deg/s sweep takes about 28 s", "got \(good.sampler.elapsed)")
    check((54...60).contains(good.takes.count), "about 2 frames/s over the turn", "got \(good.takes.count)")
    check(zip(good.takes, good.takes.dropFirst()).allSatisfy { $1 - $0 >= 0.48 }, "samples at least ~0.5 s apart")
    check(good.takes.count >= SweepSampler.minGoodFrames, "a good sweep clears the 24 frame minimum")
    check(good.skippedFast == 0, "no frame flagged as blurred at 12 deg/s")

    let fast = runSweep(rate: 90, seconds: 60)
    check(fast.skippedFast > 0, "a 90 deg/s spin is flagged as too fast")
    check(fast.takes.count < SweepSampler.minGoodFrames, "a fast spin yields too few frames", "got \(fast.takes.count)")

    let lost = runSweep(rate: 12, seconds: 60, lossDuring: 10...16)
    check(lost.skippedTracking > 0, "frames skipped while tracking is lost")
    check(lost.sampler.elapsed > good.sampler.elapsed + 5, "yaw does not advance while tracking is lost", "elapsed \(lost.sampler.elapsed)")

    let slow = runSweep(rate: 5, seconds: 120)
    check(slow.sampler.isComplete && near(slow.sampler.elapsed, SweepSampler.timeLimit, 0.1), "a slow turn ends at the 45 s limit", "elapsed \(slow.sampler.elapsed)")
    check(slow.sampler.yawDegrees < 340, "slow turn did not reach 340 deg")

    let reverse = runSweep(rate: -12, seconds: 60)
    check(reverse.sampler.isComplete && reverse.sampler.yawDegrees >= 340, "turning the other way also completes")
}

// MARK: 3. Perimeter recorder

do {
    var recorder = PerimeterRecorder()
    for frame in walkFrames() { recorder.add(frame) }
    check((199...203).contains(recorder.count), "60 Hz frames become about 10 Hz samples", "got \(recorder.count)")
    check(recorder.problem == nil, "the fixture lap passes the server's checks", "\(String(describing: recorder.problem))")
    check((recorder.endGap ?? 99) < 0.1, "lap closes (last 10 Hz sample is one step from the end)", "gap \(String(describing: recorder.endGap))")
    check(near(recorder.pathLength, 16, 0.3), "path length of the 4 m square", "got \(recorder.pathLength)")
    check(zip(recorder.samples, recorder.samples.dropFirst()).allSatisfy { $1.t > $0.t }, "t strictly increasing")
    check(near(recorder.samples.first?.t ?? 9, 0, 1e-9), "t starts at 0")
    check(recorder.jumps == 0, "no tracking jumps on a clean walk")

    // The upload body the server will see.
    let body = try JSONEncoder().encode(PerimeterUpload(poses: recorder.samples))
    try body.write(to: outDir.appending(path: "perimeter-upload.json"))
    check(body.count < 2 * 1024 * 1024, "perimeter body under the 2 MiB limit", "\(body.count) bytes")

    var dropped = PerimeterRecorder()
    for frame in walkFrames(dropout: 5...7) { dropped.add(frame) }
    check(dropped.count < recorder.count - 15, "no samples while tracking is not normal", "got \(dropped.count)")
    check(dropped.jumps == 1, "the position jump after a dropout is counted", "jumps \(dropped.jumps)")

    var straight = PerimeterRecorder()
    for i in 0..<720 { straight.add(sample(Double(i) / 60, transform(position: SIMD3(Float(i) / 120, 1.4, 0), rotation: .init(ix: 0, iy: 0, iz: 0, r: 1)))) }
    if case let .openLoop(gap)? = straight.problem { check(gap > 5, "open loop reports the gap", "gap \(gap)") } else { check(false, "a straight 6 m walk is an open loop") }

    var brief = PerimeterRecorder()
    for i in 0..<300 { brief.add(sample(Double(i) / 60, matrix_identity_float4x4)) }   // 5 s standing still
    if case let .tooShort(n)? = brief.problem { check((49...51).contains(n), "too short reports the count", "n \(n)") } else { check(false, "5 s is too short") }

    var long = PerimeterRecorder()
    for i in 0..<(60 * 400) { long.add(sample(Double(i) / 60, matrix_identity_float4x4)) }
    check(long.count == PerimeterUpload.maxSamples && long.isFull, "recording stops at 3000 samples", "got \(long.count)")

    var forced = PerimeterRecorder()
    forced.add(sample(0, matrix_identity_float4x4))
    forced.add(sample(0.03, matrix_identity_float4x4))
    check(forced.count == 1, "a sample inside the 0.1 s interval is skipped")
    forced.add(sample(0.01, matrix_identity_float4x4), force: true)
    check(forced.count == 1, "forced close still needs a later time (0.02 s minimum)")
    forced.add(sample(0.05, matrix_identity_float4x4), force: true)
    check(forced.count == 2, "forced close adds a closing sample")
}

// MARK: 4. Vantage suggestion

do {
    check(Vantage.suggested(in: fixtureGrid) == MapTile(x: 2, y: 2), "5x5 room suggests the middle tile")
    var even = fixtureGrid
    even.cols = 4; even.rows = 4
    even.playable = Set((0..<4).flatMap { y in (0..<4).map { MapTile(x: $0, y: y) } })
    check(Vantage.suggested(in: even) == MapTile(x: 1, y: 1), "ties break by row then column", "\(String(describing: Vantage.suggested(in: even)))")
    var ring = fixtureGrid
    ring.playable.remove(MapTile(x: 2, y: 2))
    check(Vantage.suggested(in: ring) == MapTile(x: 2, y: 1), "a blocked middle picks the next closest tile")
    var empty = fixtureGrid; empty.playable = []
    check(Vantage.suggested(in: empty) == nil, "no playable tile, no suggestion")
}

// MARK: 5. Pose and intrinsics representation (checked against the reference geometry in Node)

struct ConvertedFrame { var original: [String: Any] }
do {
    let data = try Data(contentsOf: repo.appending(path: "docs/fixtures/postit/sweep-observations.json"))
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var frames = json["frames"] as! [[String: Any]]
    var worst = 0.0
    for i in frames.indices {
        let p = frames[i]["pose"] as! [String: Double]
        let q = simd_quatf(ix: Float(p["qx"]!), iy: Float(p["qy"]!), iz: Float(p["qz"]!), r: Float(p["qw"]!)).normalized
        let m = transform(position: SIMD3(Float(p["x"]!), Float(p["y"]!), Float(p["z"]!)), rotation: q)
        let converted = CameraPose(transform: m)
        // Compare as rotations, since q and -q are the same orientation.
        let a = SIMD3<Float>(0, 0, -1)
        let before = simd_act(q, a)
        let after = simd_act(simd_quatf(ix: Float(converted.qx), iy: Float(converted.qy), iz: Float(converted.qz), r: Float(converted.qw)), a)
        worst = max(worst, Double(simd_distance(before, after)))
        check(near(converted.x, p["x"]!, 1e-5) && near(converted.y, p["y"]!, 1e-5) && near(converted.z, p["z"]!, 1e-5), "position survives the matrix round trip (frame \(i))")
        frames[i]["pose"] = ["x": converted.x, "y": converted.y, "z": converted.z, "qx": converted.qx, "qy": converted.qy, "qz": converted.qz, "qw": converted.qw]
    }
    check(worst < 1e-5, "rotation survives the matrix round trip", "worst \(worst)")
    json["frames"] = frames
    let fx = json["intrinsics"] as! [String: Double]
    let matrix = intrinsicsMatrix(fx: Float(fx["fx"]!), fy: Float(fx["fy"]!), cx: Float(fx["cx"]!), cy: Float(fx["cy"]!))
    // The same expressions RoomScanFlow uses, with scale 1.
    let rebuilt = CameraIntrinsics(fx: Double(matrix.columns.0.x), fy: Double(matrix.columns.1.y),
                                   cx: Double(matrix.columns.2.x), cy: Double(matrix.columns.2.y), width: 1920, height: 1080)
    check(rebuilt.fx == fx["fx"] && rebuilt.fy == fx["fy"] && rebuilt.cx == fx["cx"] && rebuilt.cy == fx["cy"], "intrinsics read from the matrix columns: fx,fy on the diagonal, cx,cy in column 2")
    let viaModel = CameraIntrinsics(intrinsics: matrix, imageWidth: 1920, imageHeight: 1080)
    check(viaModel == rebuilt, "D's CameraIntrinsics(intrinsics:) agrees with the flow's reading")
    json["intrinsics"] = ["fx": rebuilt.fx, "fy": rebuilt.fy, "cx": rebuilt.cx, "cy": rebuilt.cy, "width": rebuilt.width, "height": rebuilt.height]
    try JSONSerialization.data(withJSONObject: json).write(to: outDir.appending(path: "converted-sweep.json"))
}

// MARK: 6. JPEG encoder: pixels, size, orientation, scale

/// A 420 full-range buffer, the format ARKit delivers, with a bright square at (x, y, size).
func makeBuffer(width: Int, height: Int, marker: (x: Int, y: Int, size: Int)?, noise: Bool = false) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    precondition(status == kCVReturnSuccess, "pixel buffer")
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    var rng = SystemRandomNumberGenerator()
    for y in 0..<height {
        for x in 0..<width {
            var v = 40 + (x * 40 / width) + (y * 20 / height)
            if noise { v += Int(rng.next() % 90) }
            luma[y * lumaStride + x] = UInt8(min(v, 120))
        }
    }
    if let m = marker {
        for y in m.y..<(m.y + m.size) { for x in m.x..<(m.x + m.size) { luma[y * lumaStride + x] = 255 } }
    }
    let chroma = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    for y in 0..<(height / 2) { for x in 0..<width { chroma[y * chromaStride + x] = 128 } }
    return pb
}

/// Bounding box of the very bright pixels in a decoded JPEG, as a center point.
func markerCenter(in jpeg: Data) -> (x: Double, y: Double)? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4] > 215 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= 0 else { return nil }
    return (Double(minX + maxX + 1) / 2, Double(minY + maxY + 1) / 2)
}

do {
    // Deliberately off-center and asymmetric, so a rotation, flip or transpose cannot hide.
    let marker = (x: 300, y: 1000, size: 120)
    let buffer = makeBuffer(width: 1920, height: 1440, marker: marker)
    let image = try SweepFrameEncoder.encode(buffer)
    check(image.width == 1920 && image.height == 1440, "default path keeps the full 1920x1440 image", "\(image.width)x\(image.height)")
    check(image.jpeg.count <= SweepFrameEncoder.maxBytes, "JPEG is under 600 KiB", "\(image.jpeg.count) bytes")
    check(SweepFrameEncoder.maxBytes == SweepFrame.maxJPEGBytes, "encoder limit matches ScanModels")
    let seen = SweepFrameEncoder.inspect(image.jpeg)
    check(seen == .init(width: 1920, height: 1440, orientation: seen?.orientation) && seen?.isUpright == true, "decoder sees an upright landscape JPEG", "\(String(describing: seen))")
    check(seen?.orientation == nil || seen?.orientation == 1, "no EXIF rotation tag", "\(String(describing: seen?.orientation))")
    if let c = markerCenter(in: image.jpeg) {
        check(near(c.x, 360, 3) && near(c.y, 1060, 3), "marker lands at its original pixel (no rotation, flip or transpose)", "got \(c)")
    } else { check(false, "marker found in the JPEG") }

    // Tighten the limit step by step on a textured frame (like a real room): quality drops first, and the
    // image shrinks only after the lowest quality. A smooth image sits at the compression floor and hides this.
    let textured = makeBuffer(width: 1920, height: 1440, marker: marker, noise: true)
    var limit = try SweepFrameEncoder.encode(textured, maxBytes: 10_000_000).jpeg.count
    var seenQualities: [Double] = []
    var scaled: EncodedSweepImage?
    while limit > 5_000 {
        limit = Int(Double(limit) * 0.92)
        guard let attempt = try? SweepFrameEncoder.encode(textured, maxBytes: limit) else { break }
        if attempt.width < 1920 { scaled = attempt; break }
        seenQualities.append(attempt.quality)
    }
    check(Set(seenQualities).isSuperset(of: [0.6, 0.5, 0.4]) , "tighter limits walk the quality ladder 0.6, 0.5, 0.4", "\(seenQualities)")
    check(zip(seenQualities, seenQualities.dropFirst()).allSatisfy { $1 <= $0 }, "quality only goes down as the limit tightens", "\(seenQualities)")
    if let tiny = scaled {
        check(tiny.quality <= 0.4 + 1e-9, "the image shrinks only after the lowest quality fails", "q \(tiny.quality)")
        check(max(tiny.width, tiny.height) >= SweepFrameEncoder.minLongEdge, "never below a 1280 px long edge", "\(tiny.width)x\(tiny.height)")
        let tinySeen = SweepFrameEncoder.inspect(tiny.jpeg)
        check(tinySeen?.width == tiny.width && tinySeen?.height == tiny.height, "reported size equals decoded size after downscale", "\(String(describing: tinySeen))")
        if let c = markerCenter(in: tiny.jpeg) {
            check(near(c.x, 360 * tiny.scaleX, 4) && near(c.y, 1060 * tiny.scaleY, 4), "marker position scales with scaleX/scaleY", "got \(c) scale \(tiny.scaleX),\(tiny.scaleY)")
        } else { check(false, "marker found after downscale") }
        // The flow scales intrinsics by (JPEG pixels / camera pixels); that must equal what the encoder did.
        check(near(Double(tiny.width) / 1920, tiny.scaleX, 1e-9) && near(Double(tiny.height) / 1440, tiny.scaleY, 1e-9), "flow's intrinsics scale equals the encoder's")
    } else { check(false, "the downscale path was reached") }

    var threw = false
    do { _ = try SweepFrameEncoder.encode(makeBuffer(width: 1920, height: 1440, marker: nil, noise: true), maxBytes: 5_000) } catch { threw = true }
    check(threw, "an impossible size limit throws instead of sending an oversize frame")
}

// MARK: 7. The whole flow against a fake backend

final class FakeBackend: ScanBackend {
    var grid: MapGrid?
    var gridDelay: Duration = .milliseconds(120)
    var perimeter: [Result<PerimeterResult, Error>] = [.success(PerimeterResult(ok: true, cols: 5, rows: 5, edgeTiles: 16))]
    var sweeps: [Result<SweepResult, Error>] = [.success(SweepResult(ok: true, notesFound: 6, stations: 4, warnings: []))]
    var maps: [Result<Data, Error>] = [.success(Data(repeating: 7, count: 4096))]
    var mapUploads: [Result<Void, Error>] = [.success(())]
    var perimeterUploads: [[PoseSample]] = []
    var sweepUploads: [SweepUpload] = []
    var mapPayloads: [Data] = []
    var selfCheck: Double? = 0.4
    /// Counts setup events, like GameSession.setupRevision. It rises even when the grid is unchanged.
    var setupRevision = 0
    var lastWorldMapQuality: WorldMapQuality?
    /// true: the server sends setup even though this upload HTTP reply fails (the reply was lost).
    var setupBeforeError = false

    func uploadPerimeter(_ poses: [PoseSample]) async throws -> PerimeterResult {
        perimeterUploads.append(poses)
        let outcome = perimeter.count > 1 ? perimeter.removeFirst() : perimeter[0]
        let delay = gridDelay
        let announce = { Task { try? await Task.sleep(for: delay); self.grid = fixtureGrid; self.setupRevision += 1 } }   // setup arrives over the WebSocket
        if setupBeforeError { announce() }
        let result = try outcome.get()
        if !setupBeforeError { announce() }
        return result
    }
    func uploadSweep(vantage: Tile, intrinsics: CameraIntrinsics, frames: [SweepFrame]) async throws -> SweepResult {
        sweepUploads.append(SweepUpload(vantage: vantage, intrinsics: intrinsics, frames: frames))
        return try (sweeps.count > 1 ? sweeps.removeFirst() : sweeps[0]).get()
    }
    func captureWorldMap(progress: @escaping @MainActor (String) -> Void) async throws -> Data {
        progress("Mapping…")
        return try (maps.count > 1 ? maps.removeFirst() : maps[0]).get()
    }
    func uploadWorldMap(_ data: Data) async throws {
        mapPayloads.append(data)
        try (mapUploads.count > 1 ? mapUploads.removeFirst() : mapUploads[0]).get()
    }
    func projectionSelfCheck() -> Double? { selfCheck }
}

struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
let sweepBuffer = makeBuffer(width: 1920, height: 1440, marker: (x: 300, y: 1000, size: 120))
let vantagePosition = SIMD3<Float>(2, 1.4, 2)   // center of tile (2,2) of the fixture grid
let flatRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

func settle(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    check(condition(), "timed out waiting for: \(what)")
}

func feed(_ flow: RoomScanFlow, _ frames: [FrameSample], buffer: CVPixelBuffer? = nil) async {
    for frame in frames {
        flow.handle(FrameInput(sample: frame, pixelBuffer: flow.wantsPixelBuffer ? buffer : nil))
        // A real camera does not outrun the encoder; wait for it so simulated time stands still meanwhile.
        while flow.isEncodingFrame { try? await Task.sleep(for: .milliseconds(2)) }
    }
    await Task.yield()
}

func standStill(_ flow: RoomScanFlow, at position: SIMD3<Float>, from t: Double, seconds: Double = 0.5) async {
    await feed(flow, stride(from: 0, through: seconds, by: 1.0 / 60).map { sample(t + $0, look(position, turn: 0)) })
}

/// A steady turn at `rate` deg/s on the vantage tile.
func sweepFrames(rate: Double, seconds: Double, from t0: Double) -> [FrameSample] {
    stride(from: 0, through: seconds, by: 1.0 / 60).map { sample(t0 + $0, look(vantagePosition, turn: rate * $0)) }
}

/// perimeter walk -> upload -> vantage picker. Returns the simulated time after the last frame.
func reachVantage(_ flow: RoomScanFlow) async -> Double {
    await standStill(flow, at: SIMD3(0, 1.4, 0), from: 0)
    check(flow.isTracking && flow.canStartPerimeter, "ready to start the perimeter when tracking is healthy")
    flow.startPerimeter()
    check(flow.step == .perimeter, "perimeter started")
    await feed(flow, walkFrames(from: 1))
    check(flow.canFinishPerimeter, "Done enabled after a closed lap", "samples \(flow.perimeterSamples) gap \(String(describing: flow.perimeterGap))")
    flow.finishPerimeter()
    check(flow.step == .uploadingPerimeter, "uploading the perimeter")
    await settle("vantage picker") { flow.step == .pickingVantage }
    return 1 + (walk.last?.t ?? 0) + 0.1
}

/// Picks the suggested tile, walks onto it, and returns the new simulated time.
func goToVantage(_ flow: RoomScanFlow, clock: Double) async -> Double {
    flow.confirmVantage()
    await standStill(flow, at: vantagePosition, from: clock)
    return clock + 0.6
}

// Happy path, start to finish.
do {
    let backend = FakeBackend()
    let flow = RoomScanFlow(backend: backend)
    var clock = await reachVantage(flow)
    check(flow.chosenTile == MapTile(x: 2, y: 2), "suggested vantage is the middle tile", "\(String(describing: flow.chosenTile))")
    check(flow.grid == fixtureGrid, "the picker shows the server's grid")
    check(backend.perimeterUploads.count == 1 && (199...203).contains(backend.perimeterUploads[0].count), "perimeter upload carried the walk", "\(backend.perimeterUploads.first?.count ?? 0)")
    flow.confirmVantage()
    check(flow.step == .walkingToVantage, "walking to the vantage tile")
    check(!flow.canStartSweep, "sweep not allowed before reaching the tile")
    await standStill(flow, at: SIMD3(0, 1.4, 0), from: clock); clock += 0.6
    check(!flow.canStartSweep && !flow.isOnChosenTile, "start is disabled away from the chosen tile")
    await standStill(flow, at: vantagePosition, from: clock); clock += 0.6
    check(flow.liveTile == MapTile(x: 2, y: 2) && flow.canStartSweep, "start enabled on the chosen tile")
    flow.startSweep()
    check(flow.step == .sweeping, "sweeping")
    await feed(flow, sweepFrames(rate: 12, seconds: 30, from: clock), buffer: sweepBuffer)
    await settle("sweep upload and world map") { flow.step == .done }
    check(flow.step == .done, "flow finishes", "step \(flow.step) message \(flow.message ?? "-")")
    check(backend.sweepUploads.count == 1, "one sweep upload")
    if let upload = backend.sweepUploads.first {
        check(upload.vantage == Tile(x: 2, y: 2), "sweep carries the vantage tile")
        check((SweepSampler.minGoodFrames...SweepSampler.maxFrames).contains(upload.frames.count), "frame count within 24...60", "\(upload.frames.count)")
        check(upload.intrinsics.width == 1920 && upload.intrinsics.height == 1440, "intrinsics describe the JPEG size", "\(upload.intrinsics)")
        check(near(upload.intrinsics.fx, 1450, 0.01) && near(upload.intrinsics.cx, 960, 0.01) && near(upload.intrinsics.cy, 720, 0.01), "intrinsics copied unscaled when the image is unscaled")
        check(upload.frames.allSatisfy { $0.jpegByteCount <= SweepFrame.maxJPEGBytes }, "every frame under 600 KiB")
        check(zip(upload.frames, upload.frames.dropFirst()).allSatisfy { $1.t > $0.t && $1.index == $0.index + 1 }, "t strictly increasing, indices consecutive")
        check(upload.frames.allSatisfy { near($0.pose.x, 2, 1e-4) && near($0.pose.y, 1.4, 1e-4) && near($0.pose.z, 2, 1e-4) }, "pose taken from the same frame as the image")
        var badImages = 0
        for frame in upload.frames {
            guard let data = Data(base64Encoded: frame.jpeg), let seen = SweepFrameEncoder.inspect(data),
                  seen.width == upload.intrinsics.width, seen.height == upload.intrinsics.height, seen.isUpright else { badImages += 1; continue }
        }
        check(badImages == 0, "every JPEG decodes upright at exactly the intrinsics size", "bad \(badImages)")
        let body = try JSONEncoder().encode(upload)
        check(body.count < 64 * 1024 * 1024, "sweep body under 64 MiB", "\(body.count) bytes")
        try body.write(to: outDir.appending(path: "sweep-upload.json"))
    }
    check(backend.mapPayloads.count == 1 && backend.mapPayloads[0].count == 4096, "world map uploaded after the sweep")
    check(flow.report.contains { $0.label == "Server notes found" }, "final report includes the server's notes found")
}

// Perimeter: an open lap is refused locally; SCAN_FAILED from the server sends the host back to walk again.
do {
    let backend = FakeBackend()
    backend.perimeter = [.failure(ScanClient.ScanError.server(status: 422, code: "SCAN_FAILED", message: "The path does not enclose a room."))]
    let flow = RoomScanFlow(backend: backend)
    await standStill(flow, at: .zero, from: 0)
    flow.startPerimeter()
    await feed(flow, (0..<720).map { sample(1 + Double($0) / 60, transform(position: SIMD3(Float($0) / 120, 1.4, 0), rotation: flatRotation)) })
    check(!flow.canFinishPerimeter, "Done disabled when the lap is open", "gap \(String(describing: flow.perimeterGap))")
    flow.finishPerimeter()
    check(flow.step == .perimeter && flow.message?.contains("Walk back") == true, "open loop is refused with an instruction", flow.message ?? "-")
    check(backend.perimeterUploads.isEmpty, "nothing uploaded for an open loop")
    flow.restartPerimeter()
    flow.startPerimeter()
    await feed(flow, walkFrames(from: 20))
    flow.finishPerimeter()
    await settle("SCAN_FAILED back to idle") { flow.step == .idle && flow.message != nil }
    check(flow.step == .idle && flow.message?.contains("Walk the room again") == true, "SCAN_FAILED means walk again", flow.message ?? "-")
    check(flow.grid == nil && flow.perimeterSamples == 0, "walk data discarded after SCAN_FAILED")
}

// The server never sends the room map: reported, nothing invented.
do {
    let backend = FakeBackend()
    backend.gridDelay = .seconds(60)
    let flow = RoomScanFlow(backend: backend)
    await standStill(flow, at: .zero, from: 0)
    flow.startPerimeter()
    await feed(flow, walkFrames(from: 1))
    flow.finishPerimeter()
    await settle("no-grid timeout", timeout: 14) { flow.step == .perimeter && flow.message != nil }
    check(flow.message?.contains("did not send the room map") == true, "missing setup is reported", flow.message ?? "-")
}

// Sweep failures: a fast spin is refused; a server error keeps the frames for a retry.
do {
    let backend = FakeBackend()
    backend.sweeps = [.failure(ScanClient.ScanError.server(status: 400, code: "SCAN_UPLOAD_INVALID", message: "Bad frame.")),
                      .success(SweepResult(ok: true, notesFound: 2, stations: 2, warnings: ["Only 2 notes"]))]
    let flow = RoomScanFlow(backend: backend)
    var clock = await reachVantage(flow)
    clock = await goToVantage(flow, clock: clock)

    flow.startSweep()
    await feed(flow, sweepFrames(rate: 90, seconds: 10, from: clock), buffer: sweepBuffer); clock += 10.2
    await settle("fast sweep refused") { flow.step == .walkingToVantage }
    check(flow.message?.contains("Turn more slowly") == true, "a fast spin is refused with advice", flow.message ?? "-")
    check(backend.sweepUploads.isEmpty, "a refused sweep uploads nothing")
    check(flow.canStartSweep, "can sweep again after a refused one")

    flow.startSweep()
    await feed(flow, sweepFrames(rate: 12, seconds: 30, from: clock), buffer: sweepBuffer)
    await settle("first sweep upload fails") { flow.step == .walkingToVantage && flow.hasPendingSweep }
    check(flow.message?.contains("SCAN_UPLOAD_INVALID") == true, "server error shown", flow.message ?? "-")
    check(!flow.canStartSweep, "retry or redo must be chosen while frames are pending")
    flow.retrySweepUpload()
    await settle("retry succeeds") { flow.step == .done }
    check(backend.sweepUploads.count == 2 && backend.sweepUploads[0].frames.count == backend.sweepUploads[1].frames.count, "retry re-sent the same frames")
    check(flow.report.contains { $0.label == "Server warning" }, "server warnings surface in the report")
}

// World map failures: retried alone, the sweep is not re-sent; an oversize map never goes out.
do {
    let backend = FakeBackend()
    backend.maps = [.failure(Boom()), .success(Data(repeating: 1, count: 100))]
    let flow = RoomScanFlow(backend: backend)
    var clock = await reachVantage(flow)
    clock = await goToVantage(flow, clock: clock)
    flow.startSweep()
    await feed(flow, sweepFrames(rate: 12, seconds: 30, from: clock), buffer: sweepBuffer)
    await settle("map save fails") { flow.step == .savingMap && flow.mapFailed }
    check(flow.message == "boom", "map failure is shown", flow.message ?? "-")
    check(backend.sweepUploads.count == 1, "sweep is not re-sent when only the map failed")
    flow.retryMap()
    await settle("map retry") { flow.step == .done }
    check(backend.mapPayloads.count == 1, "retry uploads the map")
}

do {
    let backend = FakeBackend()
    backend.maps = [.success(Data(count: RoomScanFlow.maxMapBytes + 1))]
    let flow = RoomScanFlow(backend: backend)
    var clock = await reachVantage(flow)
    clock = await goToVantage(flow, clock: clock)
    flow.startSweep()
    await feed(flow, sweepFrames(rate: 12, seconds: 30, from: clock), buffer: sweepBuffer)
    await settle("oversize map refused") { flow.step == .savingMap && flow.mapFailed }
    check(flow.message?.contains("20 MiB") == true, "a map over 20 MiB is refused before upload", flow.message ?? "-")
    check(backend.mapPayloads.isEmpty, "oversize map never sent")
}

// An interruption discards everything, including encodes still in flight.
do {
    let backend = FakeBackend()
    let flow = RoomScanFlow(backend: backend)
    var clock = await reachVantage(flow)
    clock = await goToVantage(flow, clock: clock)
    flow.startSweep()
    await feed(flow, sweepFrames(rate: 12, seconds: 8, from: clock), buffer: sweepBuffer)
    check(flow.step == .sweeping && flow.sweepFrameCount > 5, "mid-sweep", "frames \(flow.sweepFrameCount)")
    flow.sessionInterrupted()
    check(flow.step == .idle && flow.grid == nil && flow.message?.contains("start over") == true, "an interruption discards the whole scan")
    try? await Task.sleep(for: .milliseconds(300))
    check(flow.step == .idle && flow.sweepFrameCount == 0, "stale encodes are ignored after an interruption")
}

// MARK: 8. Setup acknowledgement, map quality, and AR recovery (the retry path)

// A repeated perimeter produces an equal grid. The server still sends a fresh `setup`, and that must be enough.
do {
    let backend = FakeBackend()
    backend.setupBeforeError = true   // the first upload's reply is lost, but the server did send `setup`
    backend.perimeter = [.failure(Boom()), .success(PerimeterResult(ok: true, cols: 5, rows: 5, edgeTiles: 16))]
    let flow = RoomScanFlow(backend: backend)
    await standStill(flow, at: SIMD3(0, 1.4, 0), from: 0)
    flow.startPerimeter()
    await feed(flow, walkFrames(from: 1))
    flow.finishPerimeter()
    await settle("first upload failed") { flow.step == .perimeter && flow.message != nil }
    await settle("setup from the first upload arrived") { backend.grid == fixtureGrid }
    check(backend.grid == fixtureGrid, "the first setup is already in place, so a retry yields an equal grid")
    let revisionAfterFirst = backend.setupRevision
    backend.setupBeforeError = false
    flow.finishPerimeter()   // identical poses
    await settle("vantage picker after an identical retry") { flow.step == .pickingVantage }
    check(flow.step == .pickingVantage, "an identical perimeter retry reaches the vantage picker", "step \(flow.step) message \(flow.message ?? "-")")
    check(backend.setupRevision > revisionAfterFirst, "the retry produced a fresh setup event")
    check(backend.perimeterUploads.count == 2 && backend.perimeterUploads[0] == backend.perimeterUploads[1], "both uploads carried the same poses")
}

// The decision rule itself.
do {
    let grid = fixtureGrid
    check(RoomScanFlow.isFreshSetup(revision: 3, revisionBefore: 2, grid: grid, before: grid), "a new setup event is fresh even when the grid is equal")
    check(!RoomScanFlow.isFreshSetup(revision: 2, revisionBefore: 2, grid: grid, before: grid), "no new event and an equal grid is not fresh")
    check(!RoomScanFlow.isFreshSetup(revision: 2, revisionBefore: 2, grid: grid, before: nil), "counting backends do not fall back to grid comparison")
    check(RoomScanFlow.isFreshSetup(revision: 0, revisionBefore: 0, grid: grid, before: nil), "a backend that cannot count falls back to a changed grid")
    check(!RoomScanFlow.isFreshSetup(revision: 0, revisionBefore: 0, grid: grid, before: grid), "and an unchanged grid is not fresh there")
}

// World-map quality is reported, not hidden.
do {
    check(WorldMapQuality.mapped.warning == nil && WorldMapQuality.extending.warning == nil, "a mapped room has no warning")
    check(WorldMapQuality.limited.warning != nil && WorldMapQuality.notAvailable.warning != nil, "a limited or unavailable map warns")
    let backend = FakeBackend()
    backend.lastWorldMapQuality = .limited
    let flow = RoomScanFlow(backend: backend)
    var clock = await reachVantage(flow)
    clock = await goToVantage(flow, clock: clock)
    flow.startSweep()
    await feed(flow, sweepFrames(rate: 12, seconds: 30, from: clock), buffer: sweepBuffer)
    await settle("scan done with a limited map") { flow.step == .done }
    check(flow.mapQuality == .limited, "the flow remembers the map was limited")
    check(flow.report.contains { $0.label == "Map warning" && $0.warn }, "the final report carries a visible map warning")
    check(flow.report.contains { $0.label == "Map quality" && $0.warn }, "and flags the quality line")
}

// Attempt numbers make stale callbacks harmless.
do {
    var attempts = AttemptCounter()
    let first = attempts.next()
    check(attempts.isCurrent(first), "the newest attempt is current")
    let second = attempts.next()
    check(!attempts.isCurrent(first) && attempts.isCurrent(second), "starting a new attempt retires the old one")
    attempts.next()
    check(!attempts.isCurrent(second), "a cancel retires the attempt in flight")
}

// Every AR state maps to one precise status.
do {
    func resolve(_ map: PositionDetailResolver.MapState = .loaded, mode: PositionDetailResolver.Mode = .ar, interrupted: Bool = false,
                 failure: PositionDetailResolver.Failure? = nil, reliable: Bool = true, inside: Bool = true) -> PositionDetail {
        PositionDetailResolver.resolve(map: map, mode: mode, interrupted: interrupted, failure: failure,
                                       hasReliablePosition: reliable, insideGrid: inside)
    }
    check(resolve(.idle) == .idle, "idle")
    check(resolve(.downloading) == .downloadingMap, "downloading the map")
    check(resolve(.missing) == .mapMissing, "map missing")
    check(resolve(.downloadFailed("HTTP 500")) == .downloadFailed("HTTP 500"), "download failure keeps its reason")
    check(resolve(.decodeFailed("bad archive")) == .decodeFailed("bad archive"), "decode failure keeps its reason")
    check(resolve(mode: .relocalizing, reliable: false) == .relocalizing, "relocalizing")
    check(resolve(mode: .unlocalized, reliable: false) == .relocalizing, "not yet localized reads as relocalizing")
    check(resolve(mode: .manual, failure: .timedOut) == .timedOut, "timed out")
    check(resolve(mode: .manual, failure: .sessionFailed("camera denied")) == .sessionFailed("camera denied"), "session failure keeps its reason")
    check(resolve(mode: .relocalizing, interrupted: true, reliable: false) == .interrupted, "interrupted")
    check(resolve() == .tracking, "tracking")
    check(resolve(inside: false) == .outsideGrid, "outside the grid is its own state, not a failure")
    check(resolve(reliable: false) == .relocalizing, "degraded tracking reads as relocalizing")
    check(resolve(.missing, failure: .timedOut) == .mapMissing, "a missing map outranks an old timeout")
    check(PositionDetail.outsideGrid.status == .tracking && !PositionDetail.outsideGrid.isProblem, "outside the grid keeps AR tracking and is not a problem")
    for problem in [PositionDetail.mapMissing, .downloadFailed("x"), .decodeFailed("x"), .timedOut, .sessionFailed("x")] {
        check(problem.isProblem && problem.canRetry, "\(problem) offers a retry")
        if case .failed = problem.status {} else { check(false, "\(problem) reports failed status") }
    }
    for fine in [PositionDetail.idle, .downloadingMap, .relocalizing, .interrupted, .tracking, .outsideGrid] {
        check(!fine.isProblem && !fine.canRetry, "\(fine) is not a problem")
    }
    check(PositionDetail.timedOut.message.contains("Retry AR"), "the timed-out message points to Retry AR")
}

// Retry reaches the provider. A spy records what the coordinator asks for.
@Observable final class SpyAR: PositionProvider {
    let source = TileSource.ar
    var tile: MapTile?
    var status = PositionStatus.idle
    var detail = PositionDetail.idle
    var starts = 0
    var restarts = 0
    var stops = 0
    func start(on grid: MapGrid) { starts += 1 }
    func restart() { restarts += 1 }
    func stop() { stops += 1 }
}

do {
    let spy = SpyAR()
    let coordinator = PositionCoordinator(ar: spy)
    coordinator.reportInterval = .milliseconds(10)
    coordinator.begin(grid: fixtureGrid) { _, _ in }
    check(spy.starts == 1, "begin starts AR once")

    spy.detail = .tracking
    coordinator.useManual()
    coordinator.useAR()
    check(coordinator.mode == .ar && spy.restarts == 0, "switching back to a healthy AR does not restart it")

    spy.detail = .timedOut
    coordinator.useManual()
    coordinator.useAR()
    check(coordinator.mode == .ar && spy.restarts == 1, "switching to AR after it gave up starts a fresh attempt")

    coordinator.useManual()
    coordinator.retryAR()
    check(coordinator.mode == .ar && spy.restarts == 2 && !coordinator.offerManual, "Retry AR leaves manual mode and restarts AR")

    spy.detail = .tracking
    coordinator.retryAR()
    check(spy.restarts == 3, "Retry AR always restarts, even when AR looks healthy")

    coordinator.useManual()
    spy.detail = .timedOut
    coordinator.appBecameActive()
    check(spy.restarts == 3, "coming back to the app does not override a player's manual choice")
    coordinator.useAR()   // restarts (timed out)
    let before = spy.restarts
    coordinator.appBecameActive()
    check(spy.restarts == before + 1, "coming back to the app retries AR that gave up")
    spy.detail = .tracking
    coordinator.appBecameActive()
    check(spy.restarts == before + 1, "coming back to the app leaves working AR alone")
    check(coordinator.arDetail == .tracking, "the coordinator exposes AR's precise state")
    coordinator.end()
}

// The whole recovery with the mock: the first attempt times out, Retry AR recovers, tiles flow with source ar.
do {
    let mock = MockARProvider(failsToRelocalize: true, relocalizeAfter: .milliseconds(40))
    let coordinator = PositionCoordinator(ar: mock)
    coordinator.reportInterval = .milliseconds(10)
    var reports: [(MapTile, TileSource)] = []
    coordinator.begin(grid: fixtureGrid) { tile, source in reports.append((tile, source)) }
    await settle("first attempt times out") { mock.detail == .timedOut }
    await settle("the failed attempt is offered manual tiles") { coordinator.offerManual }
    check(coordinator.arDetail == .timedOut && coordinator.offerManual, "the failed attempt offers manual tiles and a retry")
    check(reports.isEmpty, "no tile is reported while AR has failed")

    coordinator.useManual()
    coordinator.pick(MapTile(x: 0, y: 0))
    await settle("manual tile reported") { reports.contains { $0.1 == .manual } }
    check(reports.contains { $0.0 == MapTile(x: 0, y: 0) && $0.1 == .manual }, "manual mode still reports its tile")

    coordinator.retryAR()
    check(mock.detail == .relocalizing && !coordinator.offerManual, "Retry AR starts a fresh attempt and clears the old error")
    await settle("retry recovers") { mock.detail == .tracking }
    await settle("AR tile reported") { reports.contains { $0.1 == .ar } }
    check(reports.contains { $0.1 == .ar }, "after the retry, tiles are reported with source ar")
    coordinator.end()
    check(mock.detail == .idle, "ending the game stops AR")
}

print(failures == 0 ? "OK: \(checks) checks passed" : "FAILED: \(failures) of \(checks) checks")
exit(failures == 0 ? 0 : 1)
