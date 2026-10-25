import Foundation
import simd
import AVFoundation
import CoreImage

nonisolated struct TrackedPose: Equatable {
    var position: SIMD3<Float>
    var quality: TrackingQuality
    /// Same monotonic timebase as ARFrame.timestamp.
    var timestamp: TimeInterval
}

protocol PlayerTracking: AnyObject {
    var pose: TrackedPose? { get }
    var quality: TrackingQuality { get }
}

extension PlayerTracking {
    static var maxPoseAge: TimeInterval { 0.5 }
    var reliablePosition: SIMD3<Float>? {
        reliablePosition(at: ProcessInfo.processInfo.systemUptime)
    }
    func reliablePosition(at uptime: TimeInterval) -> SIMD3<Float>? {
        guard quality.isReliable, let pose, pose.quality.isReliable,
              (0...Self.maxPoseAge).contains(uptime - pose.timestamp),
              pose.position.x.isFinite, pose.position.y.isFinite, pose.position.z.isFinite else { return nil }
        return pose.position
    }
}

// Capture-file schemas from architecture.md. These are capture artifacts, not gameplay models.
nonisolated struct CapturePose: Codable, Equatable {
    let t, x, y, z, qx, qy, qz, qw: Double
}

nonisolated struct CaptureIntrinsics: Codable, Equatable {
    let fx, fy, cx, cy: Double
    let width, height: Int
}

nonisolated enum CapturePass: String {
    case overview, edge
}

nonisolated struct CaptureArtifact {
    let directory: URL
    let duration: TimeInterval
    let poseCount: Int
    var videoURL: URL { directory.appendingPathComponent("video.mp4") }
    var posesURL: URL { directory.appendingPathComponent("poses.json") }
    var intrinsicsURL: URL { directory.appendingPathComponent("intrinsics.json") }
}

nonisolated enum ARCaptureError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Center-crop the native sensor image to 1280x720 without rotating it. Apply the
/// identical scale/crop to intrinsics, so Gemini boxes and poses share that image basis.
nonisolated struct CaptureVideoGeometry {
    let scale, offsetX, offsetY: Double
    let intrinsics: CaptureIntrinsics
    init(sourceWidth: Int, sourceHeight: Int, matrix: simd_float3x3) throws {
        guard sourceWidth > 0, sourceHeight > 0 else { throw ARCaptureError.invalid("Invalid camera dimensions.") }
        scale = max(1280.0 / Double(sourceWidth), 720.0 / Double(sourceHeight))
        offsetX = (1280 - Double(sourceWidth) * scale) / 2
        offsetY = (720 - Double(sourceHeight) * scale) / 2
        intrinsics = CaptureIntrinsics(fx: Double(matrix[0, 0]) * scale,
                                       fy: Double(matrix[1, 1]) * scale,
                                       cx: Double(matrix[2, 0]) * scale + offsetX,
                                       cy: Double(matrix[2, 1]) * scale + offsetY,
                                       width: 1280, height: 720)
        guard intrinsics.fx.isFinite, intrinsics.fy.isFinite, intrinsics.cx.isFinite,
              intrinsics.cy.isFinite, intrinsics.fx > 0, intrinsics.fy > 0 else {
            throw ARCaptureError.invalid("Invalid camera intrinsics.")
        }
    }
}

/// All access is serialized by ARTrackingSession on the main actor. No microphone is recorded.
@MainActor
final class CaptureRecorder {
    let directory: URL
    let geometry: CaptureVideoGeometry
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let receiver: AVAssetWriterInput.PixelBufferReceiver
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var startTimestamp: TimeInterval?
    private var lastVideoTime: TimeInterval = -.infinity
    private var poses: [CapturePose] = []
    private var finishing = false

    init(sourceWidth: Int, sourceHeight: Int, intrinsics: simd_float3x3) throws {
        geometry = try CaptureVideoGeometry(sourceWidth: sourceWidth, sourceHeight: sourceHeight, matrix: intrinsics)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ARCapture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("video.mp4"), fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000,
                                              AVVideoExpectedSourceFrameRateKey: 30,
                                              AVVideoMaxKeyFrameIntervalKey: 60]
        ])
        receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: .init(
            pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: 1280, height: 720)))
        try writer.start()
        writer.startSession(atSourceTime: .zero)
    }

    func append(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, transform: simd_float4x4) throws {
        guard !finishing, timestamp.isFinite else { return }
        guard writer.status == .writing else { throw writer.error ?? ARCaptureError.invalid("Video encoder stopped.") }
        let elapsed = startTimestamp.map { timestamp - $0 } ?? 0
        guard elapsed >= 0, elapsed - lastVideoTime >= 1.0 / 30.0 - 0.001 else { return }
        guard let pool = receiver.pixelBufferPool else { throw ARCaptureError.invalid("Video pixel buffer pool is unavailable.") }
        let output = try pool.makeMutablePixelBuffer()
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: geometry.scale, y: geometry.scale))
            .transformed(by: CGAffineTransform(translationX: geometry.offsetX, y: geometry.offsetY))
        output.withUnsafeBuffer {
            context.render(image, to: $0, bounds: CGRect(x: 0, y: 0, width: 1280, height: 720), colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let q = simd_quatf(transform)
        let position = transform.columns.3
        let numbers = [Double(position.x), Double(position.y), Double(position.z),
                       Double(q.imag.x), Double(q.imag.y), Double(q.imag.z), Double(q.real)]
        guard numbers.allSatisfy({ $0.isFinite }) else { throw ARCaptureError.invalid("Invalid camera pose. Retry the pass.") }
        guard try receiver.appendImmediately(CVReadOnlyPixelBuffer(output), with: CMTime(seconds: elapsed, preferredTimescale: 60000)) else {
            if lastVideoTime.isFinite, elapsed - lastVideoTime > 0.5 {
                throw ARCaptureError.invalid("Video encoder fell behind. Stop and retry the pass.")
            }
            return
        }
        if startTimestamp == nil { startTimestamp = timestamp }
        lastVideoTime = elapsed
        if poses.last.map({ elapsed - $0.t >= 0.1 - 0.001 }) ?? true {
            poses.append(CapturePose(t: elapsed, x: numbers[0], y: numbers[1], z: numbers[2],
                                     qx: numbers[3], qy: numbers[4], qz: numbers[5], qw: numbers[6]))
        }
    }

    func finish() async throws -> CaptureArtifact {
        guard !finishing, poses.count >= 2 else { throw ARCaptureError.invalid("Record a longer pass before finishing.") }
        finishing = true
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ARCaptureError.invalid("Video recording did not finish.") }
        let encoder = JSONEncoder()
        try encoder.encode(poses).write(to: directory.appendingPathComponent("poses.json"), options: .atomic)
        try encoder.encode(geometry.intrinsics).write(to: directory.appendingPathComponent("intrinsics.json"), options: .atomic)
        return CaptureArtifact(directory: directory, duration: lastVideoTime, poseCount: poses.count)
    }

    func cancel() {
        finishing = true
        if writer.status == .writing { writer.cancelWriting() }
    }
}

/// Performs the documented binary/multipart HTTP transfers only. WebSocket gameplay
/// and setup messages remain owned by GameClient. Session injection supports integration tests.
nonisolated struct ARCaptureTransport {
    let baseURL: URL
    let room: String
    var session: URLSession = .shared

    func endpoint(_ components: [String]) throws -> URL {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              room.count == 4, room.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw ARCaptureError.invalid("Enter an HTTP(S) server URL and a four-letter room code.")
        }
        return components.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    func upload(_ artifact: CaptureArtifact, pass: CapturePass) async throws {
        var request = URLRequest(url: try endpoint(["scan", room, pass.rawValue]))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let boundary = "ARCapture-" + UUID().uuidString
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let body = try Self.multipart(artifact: artifact, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }
        let (data, response) = try await session.upload(for: request, fromFile: body)
        try Self.validate(response, data: data)
    }

    func uploadMap(_ file: URL) async throws {
        var request = URLRequest(url: try endpoint(["map", room]))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (data, response) = try await session.upload(for: request, fromFile: file)
        try Self.validate(response, data: data)
    }

    func downloadMap() async throws -> Data {
        let (data, response) = try await session.data(from: endpoint(["map", room]))
        try Self.validate(response, data: data)
        return data
    }

    func process() async throws {
        var request = URLRequest(url: try endpoint(["scan", room, "process"]))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
    }

    static func validate(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw ARCaptureError.invalid("Invalid server response.") }
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw ARCaptureError.invalid("Server returned HTTP \(response.statusCode): \(message)")
        }
    }

    static func multipart(artifact: CaptureArtifact, boundary: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        do {
            for (name, file, mime) in [("video", artifact.videoURL, "video/mp4"),
                                       ("poses", artifact.posesURL, "application/json"),
                                       ("intrinsics", artifact.intrinsicsURL, "application/json")] {
                let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n"
                try output.write(contentsOf: Data(header.utf8))
                let source = try FileHandle(forReadingFrom: file)
                do {
                    while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                        try output.write(contentsOf: chunk)
                    }
                    try source.close()
                } catch { try? source.close(); throw error }
                try output.write(contentsOf: Data("\r\n".utf8))
            }
            try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
            try output.close()
            return url
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// No rasterization or placement: this adapter only converts a server-provided Grid
/// into tile coordinates. D can pass Grid fields here without importing ARKit into Net.
nonisolated struct ServerGridTracking: Equatable {
    let cols, rows: Int
    let tileSize, originX, originZ: Double
    let playable: Set<SIMD2<Int>>

    init(cols: Int, rows: Int, tileSize: Double, originX: Double, originZ: Double, playable: [SIMD2<Int>]) throws {
        guard cols > 0, rows > 0, tileSize == 1, originX.isFinite, originZ.isFinite,
              playable.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x < cols && $0.y < rows }) else {
            throw ARCaptureError.invalid("Invalid grid received from the server.")
        }
        self.cols = cols; self.rows = rows; self.tileSize = tileSize
        self.originX = originX; self.originZ = originZ; self.playable = Set(playable)
    }

    func tile(at position: SIMD3<Float>) -> SIMD2<Int>? {
        let x = floor((Double(position.x) - originX) / tileSize)
        let y = floor((Double(position.z) - originZ) / tileSize)
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(cols), y < Double(rows),
              x < Double(Int.max), y < Double(Int.max) else { return nil }
        let tile = SIMD2(Int(x), Int(y))
        return playable.contains(tile) ? tile : nil
    }

    func worldCenter(x: Int, y: Int, elevation: Float) -> SIMD3<Float>? {
        guard playable.contains(SIMD2(x, y)), elevation.isFinite else { return nil }
        let center = SIMD3(Float(originX + (Double(x) + 0.5) * tileSize), elevation,
                           Float(originZ + (Double(y) + 0.5) * tileSize))
        return center.x.isFinite && center.z.isFinite ? center : nil
    }
}
