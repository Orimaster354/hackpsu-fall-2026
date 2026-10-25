# Integration notes (Owner D)

Status as of the Phase 0 pass on `feature/integration`. Swift code here was written on Windows and has **not been compiled or run**. First action on a Mac: run the round-trip script (see below) and build the app.

## What exists
| Piece | Path | State |
|---|---|---|
| Codable models | `MyApp/Models/GameModels.swift` | written, uncompiled |
| Wire messages + codec | `MyApp/Models/Messages.swift` | written, uncompiled |
| Server address parsing | `MyApp/Net/ServerConfig.swift` | written, uncompiled |
| WebSocket client | `MyApp/Net/GameClient.swift` | written, uncompiled, no device test |
| Round-trip script | `Tests/ModelsRoundTrip/main.swift` | written, never run |
| Fixtures | `docs/fixtures/` | generated and checked with Node |

Run on a Mac from the repo root:
```
swiftc MyApp/Models/*.swift Tests/ModelsRoundTrip/main.swift -o /tmp/models-roundtrip && /tmp/models-roundtrip
```
New Swift files need no `project.pbxproj` edit: the project uses a file-system-synchronized group on `MyApp/`.

## Contract conflicts to resolve (needs a decision)
`origin/feature/backend` implements and documents a different scan design than `main`'s `docs/architecture.md`.

| Topic | `main` docs | `feature/backend` (implemented) |
|---|---|---|
| Scan upload | two videos + pose logs over HTTP (`/scan/:room/...`), server builds the grid | host streams `scan_frame` JPEGs at <= 1 FPS over WebSocket, app raycasts, host submits `setRoom` |
| Setup messages | `processing`, `setup`, `editStation`, `confirmSetup` | not implemented; uses `setRoom`, `suggest`/`suggestions`, `scan_*` |
| Emergency tile | station with `kind: "emergency"` near the room center | fixed at tile (0,0), must stay unblocked |
| Station kinds | `task`, `fix`, `emergency` | server rejects anything but `task`, `fix` |
| Grid | `originX/originZ/playable/edge`, no `blocked` | `cols/rows/tileSize/blocked` only; `tileSize` must be 1 |
| Player | no `ready`/`connected` | has both (documented as approved) |

How the models handle it: every field from both designs is present. Backend-only fields are required, scan-design fields (`originX`, `originZ`, `playable`, `edge`) are optional, and both message sets exist in `ClientMessage`/`ServerMessage`. Nothing is dropped, but the game cannot use the `main` scan flow until C implements it, or the docs are changed to the backend flow. Owners A and C should not both build against different flows.

Smaller gaps:
- `editStation` is documented as either a full station or `{id, delete: true}`. The client sends `{station: {...}}` for edits and `{id, delete: true}` for deletes. Confirm with C.
- The `emergency` station in `docs/fixtures/setup.json` carries a placeholder `task: "hold"` because `Station.task` is required.
- `lobby` has no host id. The server's player list is insertion-ordered, so the host is `players[0]`; B's UI already assumes this.
- `role` can be absent on reconnect before the game starts; the client decodes that as `.role(nil)`.
- Reconnect needs the same `name` as the original join (server returns `PLAYER_NOT_FOUND` otherwise).

## For Owner B (UI on `feature/ios-gameplay`)
B's `GameSession` takes `ClientIntent`/`ServerEvent`. Mapping onto the wire types:

| B | Wire |
|---|---|
| `ClientIntent.create(name:)` | `ClientMessage.create(name:)` |
| `.join(room:name:)` | `.join(room:name:playerId: nil)` |
| `.start` | `.start` |
| `ServerEvent.joined(playerID:room:)` | `.joined(playerId:room:)` |
| `.lobby(players:)` | `.lobby(LobbySnapshot)`, map `players` to `LobbyPlayer(id:name:)` |
| `.role(PlayerRole)` | `.role(Role?)` |
| `.state(phase:)` | `.state(GameState)`, use `.phase` |
| `.error(SessionError)` | `.error(code:message:)` |

Things B should change: the lobby now has `ready` and `connected` per player; the server needs the host plus four **connected** players to start, so `players.count` alone over-counts disconnected players. The adapter lives on B's side or after both branches merge. D has not written it, to avoid touching B's files.

Wiring: `GameClient().onMessage = { session.receive(map($0)) }` and `session.send = { client.send(map($0)) }`. The Settings screen already stores the address under `serverAddress`, which `ServerConfig` reads.

## For Owner C (server)
- Decide the scan flow (above).
- Confirm `editStation` shape and whether `confirmSetup` is wanted.
- The client sends `ping` frames every 10 s (WebSocket protocol-level, not JSON); `ws` answers automatically.
- Reconnect sends `join` with `playerId`; the server closes the old socket with code 4000, which the client treats as a drop and may try to reconnect again. If that loops, tell D.

## Demo checklist (draft, to rehearse once the flow is settled)
Setup (before judges): laptop on phone hotspot, `cd server && npm start`, note LAN IP, enter it in each phone's Settings, all four phones on the hotspot, camera permission granted, a rehearsed room with good light.
1. Host creates a room; three phones join with the 4-letter code. Everyone taps ready.
2. Host scans the room; stations appear on edge tiles; host confirms.
3. Players relocalize (or use the manual tile picker). Roles are revealed privately.
4. A crew player walks to a station and completes one task.
5. The impostor kills a player on the same tile; the victim's phone shows the ghost screen.
6. Another player reports the body; the meeting opens.
7. Everyone votes; the result screen shows the ejection and the winner.
Target: under 3 minutes without restart. Rehearse three times; note the time and every failure.
