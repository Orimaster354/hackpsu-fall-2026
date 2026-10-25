import SwiftUI

/// Throwaway screen for checking GameClient against the real server on a physical iPhone.
/// Not the game UI. Show it by putting `NetDebugView()` in ContentView's body (locally).
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
                    Section("Lobby (\(lobby.players.count)/4)") {
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
            connectAction = "Invalid address — enter 104.39.241.215:8080"
            note(connectAction)
            return
        }

        client.onMessage = { message in note(describe(message)) }
        client.onReconnected = { note("reconnected") }
        client.connect(to: endpoint)
        connectAction = "Connecting to ws://\(endpoint.host):\(endpoint.port)/ws"
        note(connectAction)
    }

    private func note(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 40 { log.removeLast() }
    }

    private func describe(_ message: ServerMessage) -> String {
        switch message {
        case let .joined(id, room): return "joined \(room) as \(id.prefix(8))"
        case let .lobby(snapshot): return "lobby: \(snapshot.players.count) players"
        case let .role(role): return "role: \(role?.rawValue ?? "none")"
        case let .state(state): return "state: \(state.phase.rawValue)"
        case let .error(code, text): return "error \(code): \(text)"
        default: return String(describing: message).prefix(80).description
        }
    }
}

#Preview {
    NetDebugView()
}
