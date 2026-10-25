import Foundation

/// Connects the UI's `GameSession` to the real server through `GameClient`.
///
/// Intents from the session become wire messages (`message(for:)`), and wire messages become the session's
/// events (`events(for:)`). Neither mapping decides a rule: the server is authoritative. The mappings are
/// static so they can be tested without a socket.
///
/// The connection opens on the first `create` or `join`, using the address saved in Settings.
final class LiveConnection {
    let client: GameClient
    let session: GameSession

    init(client: GameClient = GameClient(), session: GameSession = GameSession()) {
        self.client = client
        self.session = session
        session.transportName = "Game server (WebSocket)"
        session.send = { [weak self] intent in self?.send(intent) }
        session.disconnect = { [weak self] in self?.client.disconnect() }
        client.onMessage = { [weak self] message in
            for event in Self.events(for: message) { self?.session.receive(event) }
        }
        client.onStatusChange = { [weak self] status in
            // Surface a dead connection now instead of waiting for the request timeout.
            if case let .failed(reason) = status {
                self?.session.receive(.error(SessionError(code: "connection", message: reason)))
            }
        }
    }

    private func send(_ intent: ClientIntent) {
        switch intent {
        case .create, .join:
            switch client.status {
            case .connected, .connecting, .reconnecting: break
            case .disconnected, .failed: client.connect()
            }
        default:
            break
        }
        client.send(Self.message(for: intent))
    }

    // MARK: Intent to wire

    static func message(for intent: ClientIntent) -> ClientMessage {
        switch intent {
        case let .create(name): return .create(name: name)
        case let .join(room, name): return .join(room: room, name: name)
        case let .ready(ready): return .ready(ready)
        case let .editStation(station): return .editStation(Station(station))
        case let .deleteStation(id): return .deleteStation(id: id)
        case .confirmSetup: return .confirmSetup
        case .start: return .start
        case let .tile(tile, source): return .tile(Tile(x: tile.x, y: tile.y), source: source)
        case let .taskDone(stationID): return .taskDone(stationId: stationID)
        case let .kill(targetID): return .kill(targetId: targetID)
        case let .report(bodyID): return .report(bodyId: bodyID)
        case .emergency: return .emergency
        case let .vote(vote):
            switch vote {
            case let .player(id): return .vote(target: id)
            case .skip: return .vote(target: MeetingState.skip)
            }
        case .sabotage: return .sabotage
        case let .fix(stationID): return .fix(stationId: stationID)
        }
    }

    // MARK: Wire to events

    /// One wire message can produce several events. `lobby` and `setup` are followed by `setupStatus`
    /// because the session keeps the confirmed flag separately.
    static func events(for message: ServerMessage) -> [ServerEvent] {
        switch message {
        case let .joined(playerId, room):
            return [.joined(playerID: playerId, room: room)]
        case let .lobby(snapshot):
            return [
                .lobby(players: snapshot.players.map(PlayerInfo.init),
                       grid: snapshot.grid.map(MapGrid.init),
                       stations: snapshot.stations.map(MapStation.init),
                       hasMap: snapshot.hasMap),
                .setupStatus(confirmed: snapshot.setupConfirmed),
            ]
        case let .processing(step):
            return SetupStep(rawValue: step).map { [.processing($0)] } ?? []
        case let .setup(grid, stations, confirmed):
            return [
                .setup(grid: MapGrid(grid), stations: stations.map(MapStation.init)),
                .setupStatus(confirmed: confirmed),
            ]
        case let .role(role):
            return role.map { [.role(PlayerRole(rawValue: $0.rawValue) ?? .crew)] } ?? []
        case let .state(state):
            return [.state(GameSnapshot(state))]
        case .killed:
            return [.killed]
        case let .meeting(meeting):
            return [.meeting(MeetingInfo(meeting))]
        case let .result(result):
            return [.result(MeetingResult(ejected: result.ejected,
                                          role: result.role.flatMap { PlayerRole(rawValue: $0.rawValue) },
                                          winner: result.winner))]
        case let .error(code, message):
            return [.error(SessionError(code: code, message: message))]
        case .suggestions, .scanStatus, .scanDetections, .unknown:
            return []
        }
    }
}

// MARK: - Wire model to UI model

private func date(fromMillis ms: Int) -> Date {
    Date(timeIntervalSince1970: Double(ms) / 1000)
}

extension MapTile {
    init(_ tile: Tile) { self.init(x: tile.x, y: tile.y) }
}

extension PlayerInfo {
    init(_ player: Player) {
        self.init(id: player.id, name: player.name, tile: player.tile.map(MapTile.init), alive: player.alive,
                  tileSource: player.tileSource, ready: player.ready, connected: player.connected)
    }
}

extension MapGrid {
    init(_ grid: Grid) {
        self.init(cols: grid.cols, rows: grid.rows, tileSize: grid.tileSize,
                  originX: grid.originX, originZ: grid.originZ,
                  playable: Set(grid.playable.map(MapTile.init)), edge: Set(grid.edge.map(MapTile.init)))
    }
}

extension MapStation {
    init(_ station: Station) {
        self.init(id: station.id, name: station.name, tile: MapTile(station.tile),
                  task: TaskKind(rawValue: station.task.rawValue) ?? .hold, kind: station.kind)
    }
}

extension Station {
    init(_ station: MapStation) {
        self.init(id: station.id, name: station.name, tile: Tile(x: station.tile.x, y: station.tile.y),
                  task: TaskType(rawValue: station.task.rawValue) ?? .hold, kind: station.kind)
    }
}

extension MeetingInfo {
    init(_ meeting: MeetingState) {
        self.init(reason: meeting.reason, bodyOf: meeting.bodyOf, endsAt: date(fromMillis: meeting.endsAt),
                  votes: meeting.votes.mapValues { $0 == MeetingState.skip ? Vote.skip : Vote.player($0) })
    }
}

extension GameSnapshot {
    init(_ state: GameState) {
        self.init(phase: GamePhase(rawValue: state.phase.rawValue) ?? .lobby,
                  players: state.players.map(PlayerInfo.init),
                  tasksDone: state.tasksDone, tasksTotal: state.tasksTotal, lightsOut: state.lightsOut,
                  killCooldownEndsAt: state.killCooldownEndsAt.map(date(fromMillis:)),
                  meeting: state.meeting.map(MeetingInfo.init))
    }
}
