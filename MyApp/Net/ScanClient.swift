import Foundation

/// Uploads the host's room scan (docs/architecture.md, "Sticky-note scan"). Host only, lobby only.
/// The result of each upload also arrives over the WebSocket as `processing` then `setup`, which the
/// session already handles; the HTTP result is only for progress and errors.
final class ScanClient {
    enum ScanError: Error, Equatable {
        case notInRoom
        case badAddress
        case invalid(String)
        /// A non-2xx answer. `code` is the server's error code, such as `SCAN_FAILED` or `HOST_ONLY`.
        case server(status: Int, code: String, message: String)
        case badResponse
    }

    private let client: GameClient
    private let session: URLSession
    private let endpoint: ServerConfig.Endpoint?
    private let defaults: UserDefaults

    /// `client` supplies the room code and the host's player id.
    init(client: GameClient, session: URLSession = .shared, endpoint: ServerConfig.Endpoint? = nil,
         defaults: UserDefaults = .standard) {
        self.client = client
        self.session = session
        self.endpoint = endpoint
        self.defaults = defaults
    }

    /// `POST /scan/:room/perimeter`
    func uploadPerimeter(poses: [PoseSample], zone: String = "z1", name: String? = nil) async throws -> PerimeterResult {
        guard (PerimeterUpload.minSamples...PerimeterUpload.maxSamples).contains(poses.count) else {
            throw ScanError.invalid("Perimeter needs \(PerimeterUpload.minSamples) to \(PerimeterUpload.maxSamples) samples, got \(poses.count).")
        }
        return try await post("perimeter", body: PerimeterUpload(poses: poses, zone: zone, name: name), timeout: 30)
    }

    /// `POST /scan/:room/sweep`
    func uploadSweep(vantage: Tile, intrinsics: CameraIntrinsics, frames: [SweepFrame], zone: String = "z1") async throws -> SweepResult {
        guard (SweepUpload.minFrames...SweepUpload.maxFrames).contains(frames.count) else {
            throw ScanError.invalid("Sweep needs \(SweepUpload.minFrames) to \(SweepUpload.maxFrames) frames, got \(frames.count).")
        }
        if let big = frames.first(where: { $0.jpegByteCount > SweepFrame.maxJPEGBytes }) {
            throw ScanError.invalid("Frame \(big.index) is over \(SweepFrame.maxJPEGBytes / 1024) KiB. Lower the JPEG quality.")
        }
        return try await post("sweep", body: SweepUpload(vantage: vantage, intrinsics: intrinsics, frames: frames, zone: zone), timeout: 180)
    }

    private func post<Body: Encodable & Sendable, Output: Decodable>(_ route: String, body: Body, timeout: TimeInterval) async throws -> Output {
        guard let room = client.roomCode, let playerId = client.playerId else { throw ScanError.notInRoom }
        guard let base = endpoint ?? ServerConfig.current(defaults: defaults),
              let url = URL(string: "\(base.httpBase)/scan/\(room)/\(route)") else { throw ScanError.badAddress }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(playerId, forHTTPHeaderField: "X-Player-Id")
        // A sweep is tens of megabytes of base64. Encode it off the main actor so the screen keeps animating.
        let payload = try await Task.detached(priority: .userInitiated) { try JSONEncoder().encode(body) }.value

        let (data, response) = try await session.upload(for: request, from: payload)
        guard let http = response as? HTTPURLResponse else { throw ScanError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
            throw ScanError.server(status: http.statusCode, code: error?.code ?? "HTTP_\(http.statusCode)",
                                   message: error?.message ?? "The server rejected the upload.")
        }
        do { return try JSONDecoder().decode(Output.self, from: data) }
        catch { throw ScanError.badResponse }
    }

    private struct ServerErrorBody: Decodable {
        var code: String
        var message: String
    }
}
