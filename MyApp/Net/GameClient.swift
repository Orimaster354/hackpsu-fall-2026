import Foundation
import Observation

/// WebSocket client for the game server (docs/architecture.md, "Protocol").
///
/// Usage: `connect()`, then `send(.create(name:))` or `send(.join(room:name:))`. Incoming messages go to
/// `onMessage`. After the first `joined` the client remembers the room, name and `playerId`; if the socket
/// drops it reconnects with exponential backoff and re-sends `join` with that `playerId`.
@MainActor
@Observable
final class GameClient {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        /// Lost the socket; waiting to retry. `attempt` starts at 1.
        case reconnecting(attempt: Int)
        case failed(String)
    }

    private(set) var status: Status = .disconnected
    private(set) var playerId: String?
    private(set) var roomCode: String?
    /// The most recent non-fatal problem (malformed frame, send failure). For debug UI.
    private(set) var lastIssue: String?
    /// Last `lobby` snapshot, so late-appearing views can read it without waiting for a broadcast.
    private(set) var lobby: LobbySnapshot?

    /// Called on the main actor for every decoded server message, including `.error`.
    @ObservationIgnored var onMessage: ((ServerMessage) -> Void)?
    /// Called whenever `status` changes. For adapters that need to surface a failure immediately.
    @ObservationIgnored var onStatusChange: ((Status) -> Void)?
    /// Called when the socket is open again after a drop. `join` with the old `playerId` was already
    /// sent; the server answers with `joined`, `lobby`/`state` and the private `role`.
    @ObservationIgnored var onReconnected: (() -> Void)?

    @ObservationIgnored var maxReconnectAttempts = 6
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playerName: String?
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var endpointOverride: ServerConfig.Endpoint?

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatusChange?(new)
    }

    // MARK: Connection

    /// Opens the socket. `endpoint` overrides the address saved in Settings (useful in tests).
    func connect(to endpoint: ServerConfig.Endpoint? = nil) {
        endpointOverride = endpoint
        wantsConnection = true
        lastIssue = nil
        reconnectTask?.cancel()
        open(initial: true)
    }

    /// Closes the socket and forgets the session. No reconnect follows.
    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        teardown(closeCode: .normalClosure)
        playerId = nil
        roomCode = nil
        playerName = nil
        lobby = nil
        setStatus(.disconnected)
    }

    private func open(initial: Bool) {
        teardown(closeCode: .goingAway)
        guard let endpoint = endpointOverride ?? ServerConfig.current(defaults: defaults),
              let url = endpoint.webSocketURL else {
            setStatus(.failed("Invalid server address. Check Settings."))
            wantsConnection = false
            return
        }
        generation += 1
        let gen = generation
        let socket = session.webSocketTask(with: url)
        task = socket
        if initial { setStatus(.connecting) }
        socket.resume()
        // The server says nothing until it gets `create` or `join`, so a reconnect must send `join`
        // itself instead of waiting for a frame. URLSessionWebSocketTask queues the send until open.
        if !initial, let room = roomCode, let name = playerName {
            transmit(.join(room: room, name: name, playerId: playerId), on: socket, generation: gen)
        }
        // A pong proves the socket is open, which is how `.connected` is detected before any frame.
        socket.sendPing { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen, self.status != .connected else { return }
                self.markConnected()
            }
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket: socket, generation: gen) }
        pingTask = Task { [weak self] in await self?.pingLoop(socket: socket, generation: gen) }
    }

    private func teardown(closeCode: URLSessionWebSocketTask.CloseCode) {
        receiveTask?.cancel()
        pingTask?.cancel()
        receiveTask = nil
        pingTask = nil
        task?.cancel(with: closeCode, reason: nil)
        task = nil
        generation += 1
    }

    // MARK: Sending

    /// Sends a message. If the socket is down the message is dropped and `lastIssue` is set; callers
    /// should react to `status` rather than queue sends.
    func send(_ message: ClientMessage) {
        switch message {
        case let .create(name): playerName = name
        case let .join(_, name, _): playerName = name
        default: break
        }
        guard let socket = task, status == .connected || status == .connecting else {
            lastIssue = "Not connected; dropped \(message.type)."
            return
        }
        transmit(message, on: socket, generation: generation)
    }

    /// The server accepts a tile change only after two consecutive identical reports (including manual
    /// picks), so position updates go through here instead of `send(.tile(...))`.
    func reportTile(_ tile: Tile, source: TileSource) {
        send(.tile(tile, source: source))
        send(.tile(tile, source: source))
    }

    private func transmit(_ message: ClientMessage, on socket: URLSessionWebSocketTask, generation gen: Int) {
        let text: String
        do { text = try WireCodec.encode(message) }
        catch {
            lastIssue = "Could not encode \(message.type): \(error.localizedDescription)"
            return
        }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.lastIssue = "Send failed (\(message.type)): \(error.localizedDescription)"
                self.connectionLost(error.localizedDescription, generation: gen)
            }
        }
    }

    // MARK: Receiving

    private func receiveLoop(socket: URLSessionWebSocketTask, generation gen: Int) async {
        while !Task.isCancelled {
            do {
                let frame = try await socket.receive()
                guard gen == generation else { return }
                if status != .connected { markConnected() }
                switch frame {
                case let .string(text): handle(text: text)
                case let .data(data): handle(data: data)
                @unknown default: break
                }
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                connectionLost(error.localizedDescription, generation: gen)
                return
            }
        }
    }

    private func handle(text: String) {
        do { dispatch(try WireCodec.decode(text)) }
        catch { lastIssue = "Malformed server frame: \(error.localizedDescription)" }
    }

    private func handle(data: Data) {
        do { dispatch(try WireCodec.decode(data)) }
        catch { lastIssue = "Malformed server frame: \(error.localizedDescription)" }
    }

    private func dispatch(_ message: ServerMessage) {
        switch message {
        case let .joined(id, room):
            playerId = id
            roomCode = room
        case let .lobby(snapshot):
            lobby = snapshot
        case let .error(code, _):
            // A stale reconnect cannot be recovered; drop the identity so the UI can rejoin fresh.
            if code == "PLAYER_NOT_FOUND" || code == "ROOM_NOT_FOUND" {
                playerId = nil
                roomCode = nil
            }
        default:
            break
        }
        onMessage?(message)
    }

    private func markConnected() {
        let wasReconnect: Bool
        if case .reconnecting = status { wasReconnect = true } else { wasReconnect = false }
        setStatus(.connected)
        if wasReconnect { onReconnected?() }
    }

    // MARK: Keepalive and reconnect

    /// Detects half-open sockets on a hotspot, which otherwise stay "connected" until the next send.
    private func pingLoop(socket: URLSessionWebSocketTask, generation gen: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, gen == generation, status == .connected else { continue }
            socket.sendPing { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.connectionLost("Ping failed: \(error.localizedDescription)", generation: gen)
                }
            }
        }
    }

    private func connectionLost(_ reason: String, generation gen: Int) {
        guard gen == generation, wantsConnection else { return }
        teardown(closeCode: .abnormalClosure)
        // Without a remembered session there is nothing to restore; report the failure.
        guard roomCode != nil, playerId != nil, playerName != nil else {
            wantsConnection = false
            setStatus(.failed(reason))
            return
        }
        scheduleReconnect(attempt: 1, lastReason: reason)
    }

    private func scheduleReconnect(attempt: Int, lastReason: String) {
        guard wantsConnection else { return }
        guard attempt <= maxReconnectAttempts else {
            wantsConnection = false
            setStatus(.failed("Could not reconnect: \(lastReason)"))
            return
        }
        setStatus(.reconnecting(attempt: attempt))
        let delay = min(pow(2.0, Double(attempt - 1)), 8)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsConnection else { return }
            self.open(initial: false)
            // If the new socket never delivers a frame, try again.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self.wantsConnection, case .reconnecting = self.status else { return }
            self.teardown(closeCode: .abnormalClosure)
            self.scheduleReconnect(attempt: attempt + 1, lastReason: lastReason)
        }
    }

    // MARK: Map transfer

    enum MapError: Error { case notInRoom, badURL, http(Int) }

    /// `POST /map/:room`. Host only, lobby only, 1 byte to 20 MiB.
    func uploadMap(_ data: Data) async throws {
        guard let room = roomCode, let id = playerId else { throw MapError.notInRoom }
        guard let endpoint = endpointOverride ?? ServerConfig.current(defaults: defaults),
              let url = endpoint.mapURL(room: room) else { throw MapError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(id, forHTTPHeaderField: "X-Player-Id")
        let (_, response) = try await session.upload(for: request, from: data)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MapError.http(http.statusCode)
        }
    }

    /// `GET /map/:room`. Returns nil on 404 (no map uploaded yet).
    func downloadMap() async throws -> Data? {
        guard let room = roomCode else { throw MapError.notInRoom }
        guard let endpoint = endpointOverride ?? ServerConfig.current(defaults: defaults),
              let url = endpoint.mapURL(room: room) else { throw MapError.badURL }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw MapError.http(http.statusCode) }
        return data
    }
}
