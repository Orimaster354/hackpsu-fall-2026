# Architecture

## Overview
Four iPhones connect over WebSocket to one authoritative Node server on a laptop (phone hotspot, LAN IP). The host scans the room in one ARKit session in two steps. First a perimeter walk logs camera poses, from which the server builds the room outline and the 1 m grid. Then the host stands on a chosen tile and slowly turns 360 degrees while the app uploads pose-tagged photos; the server finds yellow sticky notes on the walls, turns each into an edge tile, and picks 3 task stations and 1 sabotage (fix) station. The server also places the emergency tile. Other phones download everything, relocalize, and render the result as AR icons.

```
Host, one ARKit session:
  1. perimeter walk (poses only)  --> Server: room polygon, grid, edge tiles, emergency tile   --> setup (no stations yet)
  2. pick vantage tile, 360 spin  --> Server: YOLOE finds notes in each frame, geometry turns each into an edge tile,
     (pose-tagged JPEG frames)               Gemini ranks notes, rules pick 3 task + 1 fix          --> setup (draft stations)
  3. host reviews on the 2D map, edits, confirms
Players: download setup + worldmap --> relocalize --> AR icons on tiles
All phones <--> WebSocket JSON (tiles, intents, state) <--> Server (game state machine)
```

## Modules and boundaries
| Module | Path | Responsibility | Depends on |
|---|---|---|---|
| AR | `MyApp/AR/` | Perimeter pose log, vantage picker, sweep frame capture, ARWorldMap save/load, relocalize, current tile, AR icon overlay | Models |
| Net | `MyApp/Net/` | WebSocket client, encode/decode messages, reconnect | Models |
| Models | `MyApp/Models/` | Codable types below | none |
| UI | `MyApp/UI/` | Lobby, role reveal, map, meeting, vote, end screens, manual tile picker | Net, Models |
| Tasks | `MyApp/Tasks/` | Core Motion task views, each returns success/fail | none |
| Server | `server/` | Rooms, state machine, validation, scan processing (polygon, grid, note detection, station placement), Gemini proxy | none |

## Sticky-note scan
Players stick bright yellow sticky notes on the room walls before the scan. The notes are the only things the scan looks for. They sit on the room boundary, so every note maps to an edge tile. Put up more notes than the 4 needed (6 to 8 is good) so Gemini has a choice. App-side details are in `docs/ar-capture.md`.

### Capture (host, one ARKit session)
Both steps run in one world-tracking session, so every pose shares one frame (origin = where the session started) and matches the ARWorldMap. The app only records and uploads; it does no room geometry.
1. **Perimeter walk.** The host walks once around the room edge, close to the walls (about 0.3 to 0.5 m), and ends where they started. 30 to 60 s. The app logs camera poses at about 10 Hz. No video. A few tenths of a meter of error is acceptable. Upload `POST /scan/:room/perimeter`.
2. **Vantage choice.** The server answers with `setup` (grid and the emergency station). The app shows the 2D map, suggests the playable tile closest to the middle, and lets the host tap another. The host walks there while the app shows their live tile.
3. **Sweep.** On the vantage tile, holding the phone at chest height, the host turns slowly through 360 degrees in about 30 s, keeping the walls in view. The app saves about 2 frames per second (up to 60) as full-size JPEGs, each with the pose of the same ARFrame. Upload `POST /scan/:room/sweep`.
4. The app saves the ARWorldMap after the sweep and uploads it with `POST /map/:room`.

### Upload formats
All JSON, host only, lobby phase only, rejected after `confirmSetup`. Errors: HTTP status plus `{t:"error",code,message}`.

Backend status: both routes, perimeter/grid/emergency generation, sweep frame inference, reference note geometry, Gemini ordering and score fallback are implemented. `SCAN_BUSY` (409) rejects a concurrent scan in that room and setup edits/confirmation/start during processing. JPEGs over 600 KiB decoded return `SCAN_UPLOAD_TOO_LARGE` (413); detector/runtime failure returns `SCAN_FAILED` (422). Gemini failure is a warning on successful score-based setup. The six-note synthetic fixture and black-box HTTP/WebSocket checker pass; real ARKit capture acceptance remains pending. Recorded-video diagnostics do not replace this acceptance.
```
POST /scan/:room/perimeter          header X-Player-Id: <host id>      body <= 2 MiB
{ "poses": [ { "t": 0.0, "x": 0, "y": 1.4, "z": 0, "qx": 0, "qy": 0, "qz": 0, "qw": 1 }, ... ] }   // 100 to 3000 samples

POST /scan/:room/sweep              header X-Player-Id: <host id>      body <= 64 MiB
{ "vantage": { "x": 2, "y": 2 },                       // tile the host was told to stand on; a hint only
  "intrinsics": { "fx": 1450, "fy": 1450, "cx": 960, "cy": 540, "width": 1920, "height": 1080 },
  "frames": [ { "index": 0, "t": 0.0,
                "pose": { "x": 2, "y": 1.4, "z": 2, "qx": 0, "qy": 0, "qz": 0, "qw": 1 },
                "jpeg": "<base64>" }, ... ] }           // 8 to 60 frames, each JPEG <= 600 KiB decoded
```
- Pose = `ARFrame.camera.transform` position and rotation, meters, world frame, y up. `t` = seconds since the step started, strictly increasing.
- `intrinsics` describe the JPEG pixels exactly as sent, in ARKit's native landscape image orientation (do not rotate the JPEG). If the image is downscaled, scale `fx, fy, cx, cy, width, height` by the same factor.
- Success is `200 {"ok":true,...}`. Perimeter returns `{"ok":true,"cols":5,"rows":5,"edgeTiles":16}`. Sweep returns `{"ok":true,"notesFound":6,"stations":4,"warnings":[]}`.
- Result events over WebSocket: `processing` (`polygon` after the perimeter; `gemini` while detecting and ranking; `placing` for geometry), then `setup` and `lobby`.
- Errors: `HOST_ONLY` 403, `INVALID_PHASE` 409, `SETUP_LOCKED` 409, `SETUP_MISSING` 409 (sweep before perimeter), `SCAN_UPLOAD_INVALID` 400, `SCAN_UPLOAD_TOO_LARGE` 413, `SCAN_FAILED` 422 (open loop, under 4 m^2, no usable path). A sweep that finds no notes is not an error: it returns `notesFound:0` with a warning and a `setup` containing only the emergency station, and the host places stations by hand.

### Server scan processing
1. **Polygon.** Project the perimeter path to the floor (x, z), simplify (Douglas-Peucker, 0.15 m), require the endpoints within 0.75 m horizontal Euclidean distance (close the loop), require area >= 4 m^2, then offset outward by `WALL_OFFSET_M = 0.5` (tunable; the host walks about that far from the wall). A convex or mildly non-convex room is the target; a self-crossing path is `SCAN_FAILED`.
2. **Grid.** Origin = polygon bounding-box minimum corner. Tiles whose center is inside the polygon are `playable`. A playable tile whose square touches the polygon boundary, or has a non-playable neighbor, is `edge`.
3. **Emergency.** The playable tile closest to the polygon centroid. Immutable, one per room.
4. **Detect.** Run YOLOE (text prompt `yellow sticky note`) on every sweep frame. Default checkpoint is YOLOE-26 Large (`yoloe-26l-seg.pt`); `YOLOE_MODEL` can explicitly select Small, Medium, Large or Extra Large. Keep observations with score >= 0.55, with same-frame context (`label, box, confidence, imageGap`) as already implemented. Color is not independently verified. Larger capacity has not yet demonstrated better note recall in real-room acceptance; CPU processing is slower. See `server/README.md` for measured timings and the client timeout dependency.
5. **Place.** For each observation: box center to camera ray (intrinsics), rotate by the frame pose, project to the floor plane, intersect with the polygon boundary, step 1 cm back inside, floor to a tile, snap to the nearest edge tile. Ignore rays that are mostly vertical or farther than 15 m. Merge observations whose wall hits are within 0.75 m into one physical note; the strongest observation is its representative. Reference code and a test: `docs/fixtures/postit/postit-geometry.js`, `check-geometry.js`.
6. **Rank.** Gemini gets the deduplicated notes (ids `sweep:<n>`) as candidates and returns up to 3 task and 1 fix suggestions, most useful first. Prompt: `server/prompts/station-planning.md`. It sees no coordinates or tiles.
7. **Select.** Walk Gemini's suggestions in order and keep a pick only if its tile is at least 2 m (Euclidean, tile centers) from every kept pick and is not the emergency tile. Then backfill from the remaining notes by descending score until there are 3 task and 1 fix, or no notes remain. Backfilled and fallback task types rotate through `hold, tilt, dial, shake`. If Gemini is unavailable or invalid, skip step 6 and rank by score only; setup must never fail because of Gemini. The fix station is the last pick when Gemini gave none.
8. **Name.** Station id `note-<n>`; name `Note by <top context label>` or `Wall note`.
9. Broadcast `setup` (draft, `setupConfirmed=false`). The host reviews and can move, delete or add stations on edge tiles with `editStation`, then `confirmSetup`. Fewer than 4 stations is allowed; the host fills the gap or plays with fewer tasks.

### Setup tips for the real room
- Use large, bright yellow notes (7.5 cm square or bigger), at chest height (1.0 to 1.5 m), flat on the wall, at least 2 m apart, and no more than about 4 m from the vantage tile. Small or far notes become a few pixels and are missed.
- Avoid other yellow things on the walls. Even light matters more than resolution.
- Run one real sweep early and record what size, distance and light produced detections.

Approved geometry defaults: loop closure uses horizontal Euclidean distance in `(x,z)`, endpoints at most 0.75 m apart. Task and fix spacing uses Euclidean distance between tile centers, at least 2 m (not Manhattan); the emergency station is separate. Setup validation already enforces spacing for host edits.

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
- `POST /scan/:room/perimeter` and `POST /scan/:room/sweep`: JSON uploads, host only. Formats in "Sticky-note scan".
- `POST /map/:room` and `GET /map/:room`: ARWorldMap binary.
- Map uploads accept 1 byte to 64 MiB; the host client must use the same cap. The older `RoomScanFlow.maxMapBytes` value of 20 MiB rejects larger maps locally before any request; Owner A must update it and its error text.
- There is no separate process route: each upload starts its own processing, and results arrive as `processing` then `setup` over WebSocket.

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
| `lobby` | hostId: String, players, grid: Grid\|null, stations, hasMap, setupConfirmed: Bool |
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

## Detection and task reasoning
YOLOE is the detector. Only `sticky note` observations are task candidates; doors, windows, whiteboards, light switches, electrical outlets, clocks, posters, fire extinguishers and air vents are context. Gemini is a server-only ranker over metadata. It receives candidate ids, scores, boxes and same-frame context, and returns `{summary,suggestions:[{candidateId,kind,task,reason}]}`: at most three tasks and one fix, most useful first, or fewer. Only known note ids and supported phone tasks are accepted, and any `tile` or `position` field is rejected. It cannot rename detections, pick context objects, or choose the emergency location. The prompt is `server/prompts/station-planning.md`.

Preference: notes with distinctive objects in the same frame (furniture, plants, appliances, shelves, TVs, whiteboards, doors, windows) rank above notes on bare wall, and variety across the chosen notes is preferred. Context is image evidence, never a measured distance. Geometry, not Gemini, decides tiles, spacing, emergency placement and edge rules. Gemini failure retains the notes and falls back to score ranking. Wall attachment, access and accidental duplicates need host review.

## Developer video diagnostic

`/dashboard/videos` now opens a live laptop-only app-scan monitor. It polls `GET /api/dashboard/scans` once per second, following newly received perimeter/sweep uploads and validated per-frame YOLOE progress. It shows upload bytes, stage, raw observations versus geometrically merged notes, Gemini choices, warnings/errors, grid and final station tiles. Existing manual video comparison is in a collapsed section. This observes app batch uploads; it does not require or add a live camera streaming contract.

Diagnostic endpoints are loopback-only and read-only: `GET /api/dashboard/scans` returns bounded scan metadata; `GET /api/dashboard/scans/:runId/frames/:index` returns a retained JPEG preview. At most six scan records and six <=600 KiB original JPEG previews per record remain in server memory until eviction/restart. Notes shown are capped at 64, selected stations first. No images are written to disk for the monitor; the sweep worker still deletes its temporary files. Metadata excludes raw poses, player identities, credentials and hidden roles. Preview images themselves are available only on the laptop. Server restart is required to load this feature and resets its history.

This is a developer tool for tuning YOLOE and Gemini on room clips. The game scan is the perimeter walk plus sweep described in "Sticky-note scan"; the overview and edge-walk video pipeline below is not part of it.

Updated diagnostic input: one `overview` MP4/MOV is required; `edge` is optional for an additional view. The dashboard and both detector adapters accept either one or two videos and return only supplied passes. This removes the edge-walk requirement from the developer detector test. This diagnostic does not implement the gameplay perimeter-walk and sweep pipeline described above.

YOLOE note predictions in each decoded frame are suppressed before tracking and context association: keep the highest score when boxes overlap at IoU >=0.45 or overlap covers >=85% of the smaller box. Nearby non-overlapping notes remain separate. Each track can match at most one note per sampled timestamp. This resolves same-frame duplicate boxes; it does not identify the same physical note across camera gaps or different videos.

For nearby sampled frames, ORB scene features and a RANSAC homography may align active boxes before overlap matching. Alignment needs at least eight inliers and a 40% inlier ratio; unsupported alignment is skipped. Matches remain one-to-one within a timestamp and retain the strongest observation's original frame/box/context. YOLOE results add `observationCount` (1-120 sampled frames); dashboard cards show this count and a cropped note preview, with full-frame inspection still available. This image heuristic is not world tracking and can fail with parallax, blur, repetitive texture or longer gaps. Replay of the user's seven downloaded observations grouped the repeated pair into five candidates while preserving three distinct notes in the 10-second frame. Source frames/results remain local and ignored, not repository fixtures.

Developer diagnostic: `/dashboard/videos` on the server laptop accepts an overview MP4/MOV and an optional second clip (512 MiB / 120 s each), uses the selected detector and validates per-video timestamps and boxes. Its loopback-only `GET /api/dashboard/video-test` returns model/configuration status; `POST` accepts required multipart `overview` and optional `edge` video files with `X-Roomshift-Video-Test: 1`, streaming NDJSON progress/result/error records. Duration is read from the movie container on the server; browser-provided duration fields are no longer required. The explicit Gemini comparison analyzes each clip separately at 2 FPS / high visual detail, requesting at most six large landmarks per pass; the server assigns pass identity. These tuning settings are not live accuracy acceptance. Results retain pass identity and use `{label,t,box:[x,y,w,h]}` per pass. This diagnostic does not create gameplay setup or replace the documented host scan endpoints. Live two-video acceptance, pose association and geometry remain pending.

The diagnostic accepts multipart `detector=gemini|yoloe`, default `yoloe`. GET returns `defaultDetector`, `detectors` availability/model metadata and `reasoning:{configured,model}`. YOLOE uses `yoloe-26s-seg.pt` in an isolated Python worker, sampling at 1 FPS with 960 px CPU inference and a 0.35 acceptance threshold. It returns up to eight note observations per pass, without a two-per-class cap. Notes may occupy as little as 0.0001 of the image area; this tuning is not accuracy acceptance. Context uses a 0.001 minimum area. Results expose proposal/filter counts, including context classes.

Each note retains `{label:"sticky note",t,box,confidence,frameIndex}` and optional annotated `frameJpeg`, plus `context:[{label,box,confidence,imageGap}]`. Context comes from the note's exact decoded frame, including when a clearer track observation replaces an older one. `imageGap` is the shortest box-to-box gap in pixels divided by the image diagonal; retain at most six context elements with gap <=0.2. This is image evidence, never metric distance or proof of a shared wall. Image overlap and short temporal tracks do not establish physical note identities. The worker timeout is ten minutes; temporary media are removed after completion/cancel.

Optional multipart `reasoning=1` runs Gemini on metadata only after detection; no images or video are sent by the local YOLOE path. The result adds `planning` with validated suggestions, selection policy and pending-placement status. A reasoning failure returns `planning.status=unavailable` while retaining detections. This developer diagnostic does not implement gameplay scan uploads, geometry or real-room accuracy acceptance.

## AR view (players)

After relocalizing, each phone shows world-anchored icons at tile centers, visible from across the room:
- A question-mark icon on every not-yet-done task station tile (a dimmed icon for tasks the player already completed). The fix station shows a wrench icon only while lights are out.
- An "EMERGENCY" text icon on the emergency tile.
- Ghosts and dead players see no task icons.
- Icons are hidden until relocalization succeeds. In manual mode the same icons appear on the 2D map only.
The icon positions come straight from `Station.tile` and `Grid`; the app only converts tile to world position (`originX + (x + 0.5)`, `originZ + (y + 0.5)`).

## Failure handling
- Disconnect: server keeps the player; reconnect with `playerId` restores state.
- The creator's ID is `lobby.hostId`, including after reconnect; clients must use it for host UI rather than relying on player ordering. The host is not reassigned on disconnect.
- The newest successful reconnect replaces the old socket, which is closed with code `4000` and reason `Reconnected elsewhere`. The displaced client must stop automatic reconnect and require an explicit user Connect action; otherwise two clients sharing one identity can repeatedly replace each other. Normal network drops still use reconnect with the same room/name/playerId. Rejected reconnects do not replace the active socket.
- Keepalive uses WebSocket protocol ping/pong (not JSON). The server automatically answers pings, even before a client joins. Protocol errors use `{t:"error",code,message}` and normally leave the socket open; see `server/ERROR_CODES.md`.
- Relocalization failure: manual tile picker.
- Server restarts lose state (accepted for the hackathon).
