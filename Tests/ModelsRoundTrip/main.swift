import Foundation

// JSON round-trip checks for MyApp/Models. Not part of the Xcode project (no test target yet).
// Run from the repo root on a Mac:
//
//   swiftc MyApp/Models/*.swift Tests/ModelsRoundTrip/main.swift -o /tmp/models-roundtrip \
//     && /tmp/models-roundtrip
//
// Exits non-zero on the first failure. Server samples mirror what server/game.js and server/rooms.js emit.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
    if condition() { print("ok   \(name)") } else { print("FAIL \(name) (line \(line))"); failures += 1 }
}

/// Keys are sorted by `WireCodec.encode`, so expected strings list keys alphabetically.
func wire(_ message: ClientMessage) -> String {
    try! WireCodec.encode(message)
}

// MARK: Codable models round-trip

func roundTrip<T: Codable & Equatable>(_ value: T, _ name: String) {
    do {
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(T.self, from: data)
        check(back == value, "round-trip \(name)")
    } catch {
        print("FAIL round-trip \(name): \(error)"); failures += 1
    }
}

let tile = Tile(x: 2, y: 3)
let player = Player(id: "p1", name: "Ada", tile: tile, alive: true, tileSource: .manual, ready: true, connected: true)
let meeting = MeetingState(reason: .report, bodyOf: "p2", endsAt: 1_700_000_030_000, votes: ["p1": "p3", "p4": "skip"])
roundTrip(tile, "Tile")
let sampleGrid = Grid(cols: 5, rows: 5, tileSize: 1, originX: -2.5, originZ: 1.5, playable: [tile], edge: [tile])
roundTrip(sampleGrid, "Grid")
roundTrip(Station(id: "s1", name: "Sink", tile: tile, task: .shake, kind: .task), "Station")
roundTrip(player, "Player")
roundTrip(meeting, "MeetingState")
roundTrip(GameState(phase: .meeting, players: [player], tasksDone: 1, tasksTotal: 4, lightsOut: false,
                    killCooldownEndsAt: 1_700_000_000_000, meeting: meeting), "GameState")

roundTrip(LobbySnapshot(players: [player], grid: nil, stations: [], hasMap: false, setupConfirmed: false), "LobbySnapshot (null grid)")
roundTrip(LobbySnapshot(players: [player], grid: sampleGrid, stations: [], hasMap: true, setupConfirmed: true), "LobbySnapshot (setup)")

// MARK: Server messages (decode samples as the server sends them)

func decode(_ text: String) -> ServerMessage? { try? WireCodec.decode(text) }

let playersJSON = #"[{"id":"p1","name":"Ada","tile":null,"alive":true,"tileSource":"manual","ready":false,"connected":true}]"#
let gridJSON = #"{"cols":5,"rows":5,"tileSize":1,"originX":-2.5,"originZ":1.5,"playable":[{"x":0,"y":0}],"edge":[{"x":0,"y":0}]}"#

check(decode(#"{"t":"joined","playerId":"p1","room":"ABCD"}"#) == .joined(playerId: "p1", room: "ABCD"), "joined")

if case let .lobby(snapshot)? = decode(#"{"t":"lobby","players":\#(playersJSON),"grid":null,"stations":[],"hasMap":false,"setupConfirmed":false}"#) {
    check(snapshot.players.count == 1 && snapshot.players[0].tile == nil && !snapshot.hasMap && snapshot.grid == nil && !snapshot.setupConfirmed,
          "lobby with null grid")
} else { print("FAIL lobby with null grid"); failures += 1 }

if case let .lobby(snapshot)? = decode(#"{"t":"lobby","players":\#(playersJSON),"grid":\#(gridJSON),"stations":[],"hasMap":true,"setupConfirmed":true}"#) {
    check(snapshot.grid?.originX == -2.5 && snapshot.setupConfirmed && snapshot.hasMap, "lobby with confirmed setup")
} else { print("FAIL lobby with confirmed setup"); failures += 1 }

check(decode(#"{"t":"role","role":"impostor"}"#) == .role(.impostor), "role")
check(decode(#"{"t":"role"}"#) == .role(nil), "role without value (reconnect)")
check(decode(#"{"t":"killed"}"#) == .killed, "killed")

if case let .state(state)? = decode(#"{"t":"state","phase":"playing","players":\#(playersJSON),"tasksDone":0,"tasksTotal":8,"lightsOut":false,"killCooldownEndsAt":1700000025000,"meeting":null}"#) {
    check(state.phase == .playing && state.tasksTotal == 8 && state.meeting == nil && state.killCooldownEndsAt == 1_700_000_025_000, "state (flat fields, null meeting)")
} else { print("FAIL state"); failures += 1 }

if case let .state(state)? = decode(#"{"t":"state","phase":"meeting","players":[],"tasksDone":0,"tasksTotal":0,"lightsOut":true,"killCooldownEndsAt":null,"meeting":{"reason":"emergency","bodyOf":null,"endsAt":1700000030000,"votes":{"p1":"skip"}}}"#) {
    check(state.meeting?.reason == .emergency && state.meeting?.votes["p1"] == "skip" && state.killCooldownEndsAt == nil, "state with nested meeting")
} else { print("FAIL state with meeting"); failures += 1 }

check(decode(#"{"t":"meeting","reason":"report","bodyOf":"p2","endsAt":1700000030000,"votes":{}}"#)
      == .meeting(MeetingState(reason: .report, bodyOf: "p2", endsAt: 1_700_000_030_000, votes: [:])), "meeting (flat)")
check(decode(#"{"t":"result","ejected":"p3","role":"impostor","winner":"crew"}"#)
      == .result(GameResult(ejected: "p3", role: .impostor, winner: .crew)), "result with ejection")
check(decode(#"{"t":"result","ejected":null,"role":null,"winner":null}"#)
      == .result(GameResult(ejected: nil, role: nil, winner: nil)), "result with no ejection")
check(decode(#"{"t":"error","code":"ROOM_FULL","message":"This room already has four players."}"#)
      == .error(code: "ROOM_FULL", message: "This room already has four players."), "error")
check(decode(#"{"t":"suggestions","objects":[{"label":"sink","box":[0.1,0.2,0.3,0.4]}]}"#)
      == .suggestions(objects: [DetectedObject(label: "sink", box: [0.1, 0.2, 0.3, 0.4])]), "suggestions")
check(decode(#"{"t":"scan_status","state":"ready","maxFps":1,"maxFrameBytes":262144,"maxDurationMs":90000}"#)
      == .scanStatus(ScanStatus(state: .ready, reason: nil, maxFps: 1, maxFrameBytes: 262_144, maxDurationMs: 90_000)), "scan_status ready")
check(decode(#"{"t":"scan_status","state":"stopped","reason":"duration_limit"}"#)
      == .scanStatus(ScanStatus(state: .stopped, reason: "duration_limit", maxFps: nil, maxFrameBytes: nil, maxDurationMs: nil)), "scan_status stopped")
check(decode(#"{"t":"scan_detections","frameId":"f1","timestampMs":1200,"objects":[]}"#)
      == .scanDetections(frameId: "f1", timestampMs: 1200, objects: []), "scan_detections")
check(decode(#"{"t":"processing","step":"gemini"}"#) == .processing(step: "gemini"), "processing")
check(decode(#"{"t":"future_message","x":1}"#) == .unknown(type: "future_message"), "unknown type is tolerated")
check(decode("not json") == nil, "malformed frame fails to decode")
check(decode(#"{"t":"joined"}"#) == nil, "missing field fails to decode")

// MARK: Client messages (encode to the documented JSON)

check(wire(.create(name: "Ada")) == #"{"name":"Ada","t":"create"}"#, "create")
check(wire(.join(room: "ABCD", name: "Bo")) == #"{"name":"Bo","room":"ABCD","t":"join"}"#, "join (no playerId key)")
check(wire(.join(room: "ABCD", name: "Bo", playerId: "p2")) == #"{"name":"Bo","playerId":"p2","room":"ABCD","t":"join"}"#, "join reconnect")
check(wire(.ready(true)) == #"{"ready":true,"t":"ready"}"#, "ready")
check(wire(.start) == #"{"t":"start"}"#, "start")
check(wire(.tile(Tile(x: 1, y: 2), source: .ar)) == #"{"source":"ar","t":"tile","tile":{"x":1,"y":2}}"#, "tile")
check(wire(.taskDone(stationId: "s1")) == #"{"stationId":"s1","t":"taskDone"}"#, "taskDone")
check(wire(.kill(targetId: "p3")) == #"{"t":"kill","targetId":"p3"}"#, "kill")
check(wire(.report(bodyId: "p3")) == #"{"bodyId":"p3","t":"report"}"#, "report")
check(wire(.emergency) == #"{"t":"emergency"}"#, "emergency")
check(wire(.vote(target: MeetingState.skip)) == #"{"t":"vote","target":"skip"}"#, "vote skip")
check(wire(.sabotage) == #"{"t":"sabotage"}"#, "sabotage")
check(wire(.fix(stationId: "s9")) == #"{"stationId":"s9","t":"fix"}"#, "fix")
check(wire(.scanStart) == #"{"t":"scan_start"}"#, "scan_start")
check(wire(.scanStop) == #"{"t":"scan_stop"}"#, "scan_stop")
check(wire(.scanFrame(frameId: "f1", timestampMs: 0, jpeg: "AAAA")) == #"{"frameId":"f1","jpeg":"AAAA","t":"scan_frame","timestampMs":0}"#, "scan_frame")
check(wire(.suggest(photos: ["AAAA"])) == #"{"photos":["AAAA"],"t":"suggest"}"#, "suggest")
check(wire(.confirmSetup) == #"{"t":"confirmSetup"}"#, "confirmSetup")
check(wire(.deleteStation(id: "dial")) == #"{"delete":true,"id":"dial","t":"editStation"}"#, "editStation delete")
check(wire(.editStation(Station(id: "dial", name: "Door", tile: Tile(x: 0, y: 0), task: .dial, kind: .task))) ==
      #"{"station":{"id":"dial","kind":"task","name":"Door","task":"dial","tile":{"x":0,"y":0}},"t":"editStation"}"#, "editStation")

// MARK: Lobby host id and scan uploads

if case let .lobby(snapshot)? = decode(#"{"t":"lobby","hostId":"p1","players":#(playersJSON),"grid":null,"stations":[],"hasMap":false,"setupConfirmed":false}"#) {
    check(snapshot.hostId == "p1", "lobby hostId")
} else { print("FAIL lobby hostId"); failures += 1 }
if case let .lobby(snapshot)? = decode(#"{"t":"lobby","players":#(playersJSON),"grid":null,"stations":[],"hasMap":false,"setupConfirmed":false}"#) {
    check(snapshot.hostId == nil, "lobby without hostId (older server)")
} else { print("FAIL lobby without hostId"); failures += 1 }

let scanPose = CameraPose(x: 2, y: 1.4, z: 2, qx: 0, qy: 0, qz: 0, qw: 1)
let sortedEncoder = JSONEncoder()
sortedEncoder.outputFormatting = [.sortedKeys]
func json<T: Encodable>(_ value: T) -> String { String(data: try! sortedEncoder.encode(value), encoding: .utf8)! }

roundTrip(PoseSample(t: 0.1, pose: scanPose), "PoseSample")
roundTrip(CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 540, width: 1920, height: 1080), "CameraIntrinsics")
check(json(PerimeterUpload(poses: [PoseSample(t: 0.1, pose: scanPose)])) ==
      #"{"poses":[{"qw":1,"qx":0,"qy":0,"qz":0,"t":0.1,"x":2,"y":1.4,"z":2}]}"#, "perimeter upload body")
let frame = SweepFrame(index: 0, t: 0, pose: scanPose, jpegData: Data([0xFF, 0xD8]))
check(json(frame) == #"{"index":0,"jpeg":"/9g=","pose":{"qw":1,"qx":0,"qy":0,"qz":0,"x":2,"y":1.4,"z":2},"t":0}"#, "sweep frame body")
check(frame.jpegByteCount >= 2 && frame.jpegByteCount <= 3, "sweep frame size estimate")
check(json(SweepUpload(vantage: Tile(x: 2, y: 2), intrinsics: CameraIntrinsics(fx: 1, fy: 2, cx: 3, cy: 4, width: 5, height: 6), frames: [])) ==
      #"{"frames":[],"intrinsics":{"cx":3,"cy":4,"fx":1,"fy":2,"height":6,"width":5},"vantage":{"x":2,"y":2}}"#, "sweep upload body")
check((try? JSONDecoder().decode(PerimeterResult.self, from: Data(#"{"ok":true,"cols":5,"rows":5,"edgeTiles":16}"#.utf8))) ==
      PerimeterResult(ok: true, cols: 5, rows: 5, edgeTiles: 16), "perimeter result")
check((try? JSONDecoder().decode(SweepResult.self, from: Data(#"{"ok":true,"notesFound":6,"stations":4,"warnings":[]}"#.utf8))) ==
      SweepResult(ok: true, notesFound: 6, stations: 4, warnings: []), "sweep result")
if let data = try? Data(contentsOf: URL(fileURLWithPath: "docs/fixtures/poses.json")) {
    let samples = try? JSONDecoder().decode([PoseSample].self, from: data)
    check(samples?.count == 201 && samples?.first?.t == 0, "docs/fixtures/poses.json decodes as perimeter samples")
}

// MARK: Shared fixture

func fixture(_ path: String) -> ServerMessage? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("skip \(path) (run from the repo root)"); return nil
    }
    guard let message = try? WireCodec.decode(data) else {
        print("FAIL \(path) does not decode"); failures += 1; return nil
    }
    return message
}

for path in ["docs/fixtures/setup.json", "server/fixtures/manual-setup.json"] {
    if case let .setup(grid, stations, confirmed)? = fixture(path) {
        let edge = Set(grid.edge)
        check(grid.cols == 5 && grid.rows == 5 && edge.count == 16 && !confirmed, "\(path) grid")
        check(stations.filter { $0.kind == .task || $0.kind == .fix }.allSatisfy { edge.contains($0.tile) }, "\(path) task and fix stations are on edge tiles")
        check(stations.filter { $0.kind == .emergency }.count == 1, "\(path) has one emergency station")
    }
}
if case let .lobby(snapshot)? = fixture("server/fixtures/lobby-empty.json") {
    check(snapshot.grid == nil && snapshot.stations.isEmpty && !snapshot.setupConfirmed, "server/fixtures/lobby-empty.json")
}
if case let .state(state)? = fixture("server/fixtures/state-playing.json") {
    check(state.players.count == 4 && state.meeting == nil, "server/fixtures/state-playing.json")
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
