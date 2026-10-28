import SwiftUI
import UIKit

/// Throwaway screen for checking GameClient against the real server on a physical iPhone.
/// Not the game UI. Not wired into the app. To use it, temporarily show `NetDebugView()` from ContentView (do not commit that).
struct NetDebugView: View {
    @State private var client = GameClient()
    @AppStorage(ServerConfig.defaultsKey) private var address = ""
    @State private var name = "Player"
    @State private var roomCode = ""
    @State private var connectAction = "Not tapped"
    @State private var log: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("192.168.1.20:8080", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status").font(.caption).foregroundStyle(.secondary)
                        Text(statusText).fixedSize(horizontal: false, vertical: true)
                        Text(connectAction).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Connect") {
                        connect()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Disconnect", role: .destructive) {
                        client.disconnect()
                        note("disconnected")
                    }
                }

                Section("Room") {
                    TextField("Name", text: $name)
                    Button("Create room") {
                        client.send(.create(name: name))
                    }
                    Button("Ready") {
                        client.send(.ready(true))
                    }
                    TextField("Room code", text: $roomCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: roomCode) { _, new in roomCode = String(new.uppercased().prefix(4)) }
                    Button("Join room") { client.send(.join(room: roomCode, name: name)) }
                    LabeledContent("Room", value: client.roomCode ?? "-")
                    LabeledContent("My id", value: client.playerId.map { String($0.prefix(8)) } ?? "-")
                }

                if let lobby = client.lobby {
                    Section("Lobby (\(lobby.players.count)/\(GameSession.maxPlayers))") {
                        ForEach(lobby.players) { player in
                            HStack {
                                Text(player.name)
                                Spacer()
                                Text("\(player.connected ? "online" : "offline")  \(player.ready ? "ready" : "not ready")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Start game") { client.send(.start) }
                    }
                }

                if client.roomCode != nil {
                    Section("Scan (host)") {
                        Button("Upload test perimeter (5x5 m)") { uploadTestPerimeter() }
                        Button("Upload test sweep (36 synthetic frames)") { uploadTestSweep() }
                    }
                }

                Section("Log") {
                    if let issue = client.lastIssue { Text("Issue: \(issue)").foregroundStyle(.orange) }
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Net debug")
            .onChange(of: client.status) { _, new in note("status: \(statusLabel(new))") }
        }
    }

    private var statusText: String { statusLabel(client.status) }

    private func statusLabel(_ status: GameClient.Status) -> String {
        switch status {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case let .reconnecting(attempt): return "reconnecting (\(attempt))"
        case let .failed(reason): return "failed: \(reason)"
        }
    }

    private func connect() {
        connectAction = "Connect tapped"
        guard let endpoint = ServerConfig.parse(address) else {
            connectAction = "Invalid address. Enter host:port, for example 192.168.1.20:8080"
            note(connectAction)
            return
        }

        client.onMessage = { message in note(describe(message)) }
        client.onReconnected = { note("reconnected") }
        client.connect(to: endpoint)
        connectAction = "Connecting to ws://\(endpoint.host):\(endpoint.port)/ws"
        note(connectAction)
    }

    /// Sends a synthetic one-lap walk around a 4 x 4 m square (the same shape as docs/fixtures/poses.json) through
    /// ScanClient. The server should answer with a 5 x 5 grid and 16 edge tiles, then broadcast `setup`.
    private func uploadTestPerimeter() {
        var samples: [PoseSample] = []
        let corners: [(x: Double, z: Double, yaw: Double)] = [(0, 0, 0), (4, 0, -.pi / 2), (4, 4, .pi), (0, 4, .pi / 2), (0, 0, 0)]
        var t = 0.0
        for i in 0..<4 {
            let (from, to) = (corners[i], corners[i + 1])
            for step in 0..<50 {
                let f = Double(step) / 50
                let pose = CameraPose(x: from.x + (to.x - from.x) * f, y: 1.4, z: from.z + (to.z - from.z) * f,
                                      qx: 0, qy: sin(from.yaw / 2), qz: 0, qw: cos(from.yaw / 2))
                samples.append(PoseSample(t: t, pose: pose))
                t += 0.1
            }
        }
        samples.append(PoseSample(t: t, pose: CameraPose(x: 0, y: 1.4, z: 0, qx: 0, qy: 0, qz: 0, qw: 1)))
        note("uploading \(samples.count) perimeter samples")
        let scan = ScanClient(client: client)
        Task {
            do {
                let result = try await scan.uploadPerimeter(poses: samples)
                note("perimeter ok: \(result.cols)x\(result.rows), \(result.edgeTiles) edge tiles")
            } catch {
                note("perimeter failed: \(error)")
            }
        }
    }

    /// 36 synthetic frames from tile (2,2), 10 degrees apart, each a plain gray JPEG with a yellow square. The poses
    /// match docs/fixtures/postit/sweep-observations.json. No real notes are in the pictures, so the server should
    /// accept the upload and report notesFound 0 (or whatever its detector stub returns).
    private func uploadTestSweep() {
        // The pixels must match the intrinsics below (the server rejects a mismatch when it finds notes).
        let size = CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.lightGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 940, y: 520, width: 40, height: 40))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            note("could not make a test JPEG")
            return
        }
        let frames = (0..<36).map { i -> SweepFrame in
            let yaw = Double(i) * 10 * .pi / 180
            let pose = CameraPose(x: 2, y: 1.4, z: 2, qx: 0, qy: sin(yaw / 2), qz: 0, qw: cos(yaw / 2))
            return SweepFrame(index: i, t: Double(i) * 0.4, pose: pose, jpegData: jpeg)
        }
        let intrinsics = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 540, width: 1920, height: 1080)
        note("uploading \(frames.count) sweep frames")
        let scan = ScanClient(client: client)
        Task {
            do {
                let result = try await scan.uploadSweep(vantage: Tile(x: 2, y: 2), intrinsics: intrinsics, frames: frames)
                note("sweep ok: \(result.notesFound) notes, \(result.stations) stations, warnings \(result.warnings)")
            } catch {
                note("sweep failed: (error)")
            }
        }
    }

    private func note(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 40 { log.removeLast() }
    }

    private func describe(_ message: ServerMessage) -> String {
        switch message {
        case let .joined(id, room): return "joined \(room) as \(id.prefix(8))"
        case let .lobby(snapshot): return "lobby: \(snapshot.players.count) players"
        case let .role(role, power, _): return "role: \(role?.rawValue ?? "none") power: \(power?.rawValue ?? "none")"
        case let .state(state): return "state: \(state.phase.rawValue)"
        case let .error(code, text): return "error \(code): \(text)"
        default: return String(describing: message).prefix(80).description
        }
    }
}

#Preview {
    NetDebugView()
}
