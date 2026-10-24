# Architecture

## Overview
Four iPhones connect over WebSocket to one authoritative Node server on a laptop (phone hotspot, LAN IP). During lobby setup, the host scans the room and continuously streams sampled camera frames to the backend. Flash-Lite analyzes the latest available frame. The server stores the grid, stations and ARWorldMap; all other phones download them and relocalize. Camera streaming stops when play starts.

```
iPhone (host) --scan--> grid + worldmap + live video frames --> Server --> Flash-Lite frame detector
iPhone x3  <--- room, stations, worldmap ---  Server
All phones <--> WebSocket JSON (tiles, intents, state) <--> Server (game state machine)
```

## Modules and boundaries
| Module | Path | Responsibility | Depends on |
|---|---|---|---|
| AR | `MyApp/AR/` | RoomPlan scan, grid build, ARWorldMap save/load, relocalize, current tile, photo raycast | Models |
| Net | `MyApp/Net/` | WebSocket client, encode/decode messages, reconnect | Models |
| Models | `MyApp/Models/` | Codable types below | none |
| UI | `MyApp/UI/` | Lobby, role reveal, map, meeting, vote, end screens, manual tile picker | Net, Models |
| Tasks | `MyApp/Tasks/` | Core Motion task views, each returns success/fail | none |
| Server | `server/` | Rooms, state machine, validation, Gemini proxy | none |

## Positioning model
- Grid: `cols x rows` of 1.0 m tiles; origin at the scan bounds' min corner; axes follow the world map.
- Phone computes `tile = floor((pos - origin) / 1.0)` from ARKit and sends it at 2-4 Hz.
- Server accepts a tile change only after 2 consecutive identical reports (drift filter).
- Fallback: `tileSource = "manual"`, player taps a tile on the 2D map. Same message.
- Relocalization has a 20 s timeout, then the app offers manual mode.

## Shared models (Swift Codable / JSON)
```
Tile        { x: Int, y: Int }
Grid        { cols: Int, rows: Int, tileSize: Double (1.0), blocked: [Tile] }
Station     { id: String, name: String, tile: Tile, task: TaskType, kind: "task"|"fix" }
TaskType    "shake" | "tilt" | "dial" | "hold" | "gesture"
Role        "crew" | "impostor"
Phase       "lobby" | "playing" | "meeting" | "ended"
Player      { id, name, tile: Tile?, alive: Bool, tileSource: "ar"|"manual",
              ready: Bool, connected: Bool }
GameState   { phase, players: [Player], tasksDone: Int, tasksTotal: Int,
              lightsOut: Bool, killCooldownEndsAt: Int?, meeting: MeetingState? }
MeetingState{ reason: "report"|"emergency", bodyOf: String?, endsAt: Int, votes: { [id]: id|"skip" } }
```
`tasksTotal` counts tasks for living crew only. Ghosts do not do tasks. Times are epoch ms.

## Protocol
JSON text frames, `{ "t": "<type>", ...fields }`. HTTP: `POST /map/:room` and `GET /map/:room` for the ARWorldMap binary (not over WebSocket).

### Client to server
| t | fields | notes |
|---|---|---|
| `create` | name | returns `room` code (4 letters), host |
| `join` | room, name, playerId? | `playerId` is supplied only for reconnect; returns the same identity |
| `ready` | ready: Bool | lobby only; updates the sender's ready status |
| `setRoom` | grid, stations | host only; uploads scan result |
| `suggest` | photos (base64 jpeg), boxes metadata | host only; server calls Gemini, replies `suggestions` |
| `scan_start` | | host/lobby only; starts a continuous sampled-camera scan |
| `scan_frame` | frameId: String, timestampMs: Int, jpeg: String | continuous sampled video; at most 1 FPS; unique ID and capture timestamp |
| `scan_stop` | | host/lobby only; closes the live scan |
| `start` | | host only, needs 4 players |
| `tile` | tile, source | position report |
| `taskDone` | stationId | server checks player is on that tile and alive |
| `kill` | targetId | impostor swipe; server checks same tile, cooldown, alive |
| `report` | bodyId | reporter on body's tile |
| `emergency` | | must be on emergency tile, once per player |
| `vote` | target (id or "skip") | |
| `sabotage` | | impostor; starts lights out |
| `fix` | stationId | crew on fix tile |

### Server to client
| t | fields |
|---|---|
| `joined` | playerId, room |
| `lobby` | players, grid, stations, hasMap |
| `suggestions` | objects: [{label, box: [x,y,w,h]}] (0–1 normalized image coordinates) |
| `scan_status` | state: "connecting"\|"ready"\|"stopped", reason?; ready also includes maxFps, maxFrameBytes, maxDurationMs |
| `scan_detections` | frameId, timestampMs, objects: [{label, box: [x,y,w,h]}] (private to scanning host) |
| `role` | role (private) |
| `state` | full GameState (broadcast on every change) |
| `killed` | by hidden; sent only to victim |
| `meeting` | MeetingState |
| `result` | ejected: id\|null, role, winner |
| `error` | code, message |

## Rules enforced by the server
- Kill: impostor alive, victim alive and crew, same tile, cooldown 25 s from last kill (and from game start).
- Dead player: phone stays at the body tile; `alive=false`; cannot vote, kill or do tasks.
- Report: reporter alive and on same tile as the body. Emergency: once per player, 3 total.
- Meeting: 30 s vote; majority ejects; tie or skip majority ejects no one.
- Win: crew when `tasksDone >= tasksTotal` or impostor ejected; impostor when alive crew <= alive impostors.
- Lights out: `lightsOut=true`, crew tasks rejected until `fix` on the fix station; sabotage cooldown 45 s.
- Roles: random, 1 impostor for 4 players (count is a constant `IMPOSTORS`).

## Gemini flow
1. In the lobby, the host sends `scan_start` and waits for `scan_status` ready. The host maintains its WebSocket stream to the backend; the key stays server-side.
2. Host samples its live camera at up to 1 FPS into JPEG frames (longest edge <=768 px recommended; max 256 KiB each), sending `scan_frame` with a unique string frameId and a strictly increasing, nonnegative timestampMs relative to scan start. The host retains each corresponding AR camera transform/intrinsics/frame reference locally.
3. The backend sends the current frame to the existing Flash-Lite JSON detector, validates labels/boxes, and sends private `scan_detections`. Frame ID and capture timestamp come from that exact request, not the model. There is no audio or model free-text in the iOS protocol.
4. App uses the matching captured frame/pose to raycast each box center against the scan (mesh or planes), converts to a tile, and chooses a task type. Host accepts or rejects stations before submitting `setRoom`. A detection is not a verified position or a stable tracked object ID; do not apply delayed boxes to the currently moving camera frame.
5. Only one frame is analyzed at a time; only the newest pending frame is retained. Older pending frames may receive no result. A result may contain an empty object list. Stop with `scan_stop`; scans also stop at 90 seconds, host disconnect/reconnect, game start, provider failure, or server shutdown. Reconnect does not automatically resume a camera feed. The user approved this Flash-Lite engine after a native Gemini Live test produced incorrect labels; it is continuous video transport with stateless frame analysis, not temporal video reasoning or object tracking.
The existing one-shot `suggest`/`suggestions` photo helper remains compatible for development; the continuous scan is the primary host workflow. Native iOS capture/streaming is owned by A+D.
There is no canned fallback: if Gemini fails, the host places stations by hand on the 2D map.

## Approved backend integration details

- WebSocket endpoint: `/ws`. `state` and `meeting` fields are beside `t`, e.g. `{ "t":"state", "phase":"playing", "players":[], ... }`; `meeting` is also nested inside GameState. `result.winner` is `"crew"`, `"impostor"`, or null. `killed` has no killer identity.
- A start needs the host and four connected players. Ready status is shown in the lobby; it does not add a separate start requirement. New players cannot join after start; known players may reconnect and privately receive their own role, current state, and final winner if ended.
- Emergency tile is `(0,0)` and must remain unblocked. Meetings freeze tile changes. Votes are public in `MeetingState.votes`, one per living player. More than half of all living players must vote for the same target to eject; missing votes, ties, and skip majorities do not eject anyone. Meetings finish after 30 seconds or when all living players vote. Bodies cannot be reported again after a meeting.
- Each living crew member completes each task-kind station once. Both numerator and denominator exclude eliminated crew. A room with no task stations supports the manual kill/vote demo and has no task-based victory. First sabotage is immediately available; subsequent sabotage waits 45 seconds. Kill cooldown starts at game start and after each kill.
- Tile changes require two consecutive identical reports, including manual mode. The manual picker/network layer should send the same tile twice. Reconnect, invalid reports, and meetings reset pending reports.
- Gemini replies only to the requesting host, with object labels and image boxes. For the initial demo, `photos` contains one base64 JPEG (up to 4 MiB); optional `boxes` metadata is opaque context (up to 16,000 JSON characters) and cannot establish room coordinates. One request may be in flight per room. The client raycasts boxes to tiles and chooses tasks, then the host submits approved stations through `setRoom`. This replaces the former tiled-stations response, which conflicted with client-side raycasting. Missing keys, provider failures, and invalid responses produce `error`, with manual host placement as fallback.
- Individual stream frame analysis has a 20 s timeout. `scan_status` stopped reasons include host_stopped, duration_limit, game_started, host_disconnected, host_reconnected, server_stopped, and error. Hosts must stop camera capture on stopped status or when leaving the lobby. Keys and video frames are excluded from public game state and dashboard snapshots. This is continuous sampled camera video with per-frame Flash-Lite requests, not an uploaded MP4, native Gemini Live session, or 30 FPS AI processing. Stop aborts the in-flight request; quota/provider errors stop the session instead of generating automatic retries.
- Binary map upload uses `POST /map/:room` with `Content-Type: application/octet-stream` and `X-Player-Id` equal to the host ID. Uploads are lobby-only, 1 byte–20 MiB. `GET /map/:room` returns the same binary or 404 until a map exists. This is a demo ownership check, not an authentication system.

## Failure handling
- Disconnect: server keeps the player; reconnect with `playerId` restores state.
- Lobby connection status is server-owned. Players start unready; disconnecting clears ready status and broadcasts `connected=false`. Reconnecting broadcasts `connected=true`; the player must ready again. `ready` changes are broadcast in `lobby`. This extension was approved for backend/client integration; client models must include both player fields.
- Relocalization failure: manual tile picker.
- Server restarts lose state (accepted for the hackathon).
