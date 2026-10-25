# Architecture

## Overview
Four iPhones connect over WebSocket to one authoritative Node server on a laptop (phone hotspot, LAN IP). The host phone records two videos with a camera pose log; the server builds the grid, stations and emergency tile from them and stores them with the ARWorldMap. Other phones download everything, relocalize, and render the result as AR icons.

```
Host: pass 1 (overview) + pass 2 (edge walk)  = video + pose log each
   --> Server: room polygon, grid, Gemini objects, station + emergency tiles --> ARWorldMap + setup
Players: download setup + worldmap --> relocalize --> AR icons on tiles
All phones <--> WebSocket JSON (tiles, intents, state) <--> Server (game state machine)
```

## Modules and boundaries
| Module | Path | Responsibility | Depends on |
|---|---|---|---|
| AR | `MyApp/AR/` | Record video + timestamped pose log (two passes), save/load ARWorldMap, relocalize, current tile, AR icon overlay | Models |
| Net | `MyApp/Net/` | WebSocket client, encode/decode messages, reconnect | Models |
| Models | `MyApp/Models/` | Codable types below | none |
| UI | `MyApp/UI/` | Lobby, role reveal, map, meeting, vote, end screens, manual tile picker | Net, Models |
| Tasks | `MyApp/Tasks/` | Core Motion task views, each returns success/fail | none |
| Server | `server/` | Rooms, state machine, validation, scan processing (polygon, grid, station placement), Gemini proxy | none |

## Scan capture (host)
Both passes run in one ARKit world-tracking session, so all poses share one frame (origin = where the host starts). The app only records; it does no geometry.
- Pass 1, overview: walk through the room showing every object, about 30-60 s.
- Pass 2, edge walk: walk once around the room with the camera on the walls and the floor line, about 30-60 s. Close the loop at the start point.
- Each pass uploads `video.mp4` (720p) and `poses.json`: `[{t, x, y, z, qx, qy, qz, qw}]` at about 10 Hz (t in seconds from video start) plus camera intrinsics `{fx, fy, cx, cy, width, height}` once.
- After pass 2 the app saves the ARWorldMap and uploads it.

## Server scan processing
1. Room polygon: take the pass-2 path projected to the floor (x, z), simplify, and close it. The wall line is the path offset outward by 0.5 m (the host walks about half a meter from the wall; tune on a real room).
2. Grid: rasterize the polygon into 1.0 m tiles. Tiles inside are playable; tiles touching the polygon boundary are `edge`.
3. Objects: send both videos to Gemini Flash; it returns `[{label, t, box:[x,y,w,h]}]` with timestamps.
4. Station placement: for each object, take the pose at `t`, cast a ray from the camera through the box center (using intrinsics), and intersect it with the polygon boundary. Snap to the nearest edge tile. Stations must be on edge tiles, with a minimum of 2 tiles between stations.
5. Emergency tile: the playable tile closest to the polygon centroid.
6. The host reviews and can move, delete or add stations by tapping edge tiles on the 2D map.
If the polygon is not closed or the area is under 4 m^2 the server returns `error: scan_failed` and the host rescans.

Approved geometry defaults for Phase 3: loop closure uses horizontal Euclidean distance in `(x,z)`, with endpoints at most 0.75 m apart. Task/fix station spacing uses Euclidean distance between tile centers, at least 2 m (not Manhattan distance); the emergency station is separate. These geometry calculations remain pending; setup validation already enforces station spacing.

## Positioning model
- Grid: `cols x rows` of 1.0 m tiles on the floor plane (x, z); origin at the polygon's min corner, in the host's ARKit world frame, so it matches the ARWorldMap.
- Phone computes `tile = floor((pos - origin) / 1.0)` from ARKit and sends it at 2-4 Hz.
- Server accepts a tile change only after 2 consecutive identical reports (drift filter).
- Fallback: `tileSource = "manual"`, player taps a tile on the 2D map. Same message.
- Relocalization has a 20 s timeout, then the app offers manual mode.

## Shared models (Swift Codable / JSON)
```
Tile        { x: Int, y: Int }
Grid        { cols: Int, rows: Int, tileSize: Double (1.0), originX: Double, originZ: Double,
              playable: [Tile], edge: [Tile] }
Station     { id: String, name: String, tile: Tile, task: TaskType, kind: "task"|"fix"|"emergency" }
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
The emergency station's required `task` uses `hold` as an ignored placeholder; clients branch on `kind` and never launch a task for it.

## Protocol
JSON text frames, `{ "t": "<type>", ...fields }`. Large files use HTTP, not WebSocket:
- `POST /scan/:room/overview` and `POST /scan/:room/edge`: multipart with `video` (mp4), `poses` (JSON), `intrinsics` (JSON). Host only.
- `POST /map/:room` and `GET /map/:room`: ARWorldMap binary.
- `POST /scan/:room/process`: starts server processing after both passes and the map are uploaded. Result arrives as `setup` over WebSocket.

### Client to server
| t | fields | notes |
|---|---|---|
| `create` | name | returns `room` code (4 letters), host |
| `join` | room, name, playerId? | returns `playerId`; send the same room/name/playerId on reconnect |
| `ready` | ready: Bool | lobby only; server updates sender; advisory, not an extra start requirement |
| `editStation` | station (full object or `{id, delete: true}`) | host only, lobby phase; task/fix edge tiles only; emergency immutable |
| `confirmSetup` | | host only; locks grid and stations; retries are idempotent |
| `start` | | host only, needs 4 players and confirmed setup |
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
| `lobby` | players, grid: Grid\|null, stations, hasMap, setupConfirmed: Bool |
| `processing` | step: "polygon"\|"gemini"\|"placing" |
| `setup` | grid, stations, setupConfirmed: Bool (draft until confirmed) |
| `role` | role (private) |
| `state` | full GameState (broadcast on every change) |
| `killed` | no extra fields; sent only to victim, no killer identity |
| `meeting` | MeetingState |
| `result` | ejected: id\|null, role: Role\|null, winner: Role\|null |
| `error` | code, message |

`state` and `meeting` event fields sit directly beside `t`; GameState also has a nested nullable `meeting`. A new room has `grid=null`, empty stations and `setupConfirmed=false` until the server produces setup. Only internal scan processing (or an explicit developer fixture) supplies grid geometry; the obsolete client `setRoom` event is not accepted. Station edits broadcast both `setup` and `lobby`; confirmation broadcasts both with `setupConfirmed=true`. The deletion shorthand `{t:"editStation",id,delete:true}` is also accepted.

On join/reconnect the server sends `joined`, `setup` if available, and the current lobby; during play it also restores only that player's private role and public state. Disconnection retains membership, sets `connected=false`, and clears ready. Reconnect requires readying again. Public snapshots never contain roles. Backend JSON fixtures and the client checklist are in `server/CLIENT_INTEGRATION.md`; Swift decoding/device acceptance remains pending alignment and verification of Owner D's existing implementation.

## Rules enforced by the server
- Kill: impostor alive, victim alive and crew, same tile, cooldown 25 s from last kill (and from game start).
- Dead player: phone stays at the body tile; `alive=false`; cannot vote, kill or do tasks.
- Report: reporter alive and on same tile as the body. Emergency: once per player, 3 total.
- Meeting: 30 s vote; more than half of all living players must vote for a player to eject them; ties, skips and minority votes eject no one.
- Win: crew when `tasksDone >= tasksTotal` or impostor ejected; impostor when alive crew <= alive impostors.
- Lights out: `lightsOut=true`, crew tasks rejected until `fix` on the fix station; sabotage cooldown 45 s.
- Roles: random, 1 impostor for 4 players (count is a constant `IMPOSTORS`).

## Gemini flow
Server only. Input: the two videos. Output JSON: `[{label, t, box:[x,y,w,h]}]` (box normalized 0-1, `t` seconds in that video). The server maps each label to a task type (table/desk to hold, sofa to tilt, door to dial, and so on, with a default rotation of types) and places it per "Server scan processing". There is no canned fallback: if Gemini fails or returns nothing usable, the host places stations by hand on the 2D map.

## Developer video diagnostic

Developer diagnostic: `/dashboard/videos` on the server laptop accepts an overview and edge-walk MP4 (64 MiB / 120 s each), uploads both full clips to Gemini and validates per-video timestamps and boxes. Its loopback-only `GET /api/dashboard/video-test` returns model/configuration status; `POST` accepts multipart `overview`, `edge`, `overviewDuration`, `edgeDuration` with `X-Roomshift-Video-Test: 1`, streaming NDJSON progress/result/error records. Results retain pass identity and use `{label,t,box:[x,y,w,h]}` per pass. This diagnostic does not create gameplay setup or replace the documented host scan endpoints. Live two-video acceptance, pose association and geometry remain pending.

## AR view (players)

After relocalizing, each phone shows world-anchored icons at tile centers, visible from across the room:
- A question-mark icon on every not-yet-done task station tile (a dimmed icon for tasks the player already completed). The fix station shows a wrench icon only while lights are out.
- An "EMERGENCY" text icon on the emergency tile.
- Ghosts and dead players see no task icons.
- Icons are hidden until relocalization succeeds. In manual mode the same icons appear on the 2D map only.
The icon positions come straight from `Station.tile` and `Grid`; the app only converts tile to world position (`originX + (x + 0.5)`, `originZ + (y + 0.5)`).

## Failure handling
- Disconnect: server keeps the player; reconnect with `playerId` restores state.
- Relocalization failure: manual tile picker.
- Server restarts lose state (accepted for the hackathon).
