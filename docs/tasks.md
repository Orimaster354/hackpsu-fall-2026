# Tasks

Owners: A = AR (Mac 1), B = UI/Tasks (Mac 2), C = Server (Windows), D = Contracts/Net/Integration. Cut order when behind: gesture task, sabotage, Gemini placement (fall back to host-placed stations on edge tiles).

## Phase 0: Contracts (D, first hour; blocks everything)
- [ ] D: `MyApp/Models/` Codable types matching `docs/architecture.md`. AC: compiles; sample JSON round-trips.
- [ ] D: `MyApp/Net/GameClient.swift` (connect, send, receive, reconnect with playerId). AC: connects to the server and prints `lobby`.
- [ ] C: `server/` skeleton (`ws`, rooms, `create`/`join`, `lobby`). AC: 4 fake clients join one room.

## Phase 1: Manual-tile game, end to end (no AR)
- [ ] C: state machine for start, roles, tile, kill, report, emergency, meeting, vote, win. Depends on Phase 0. AC: `npm test` covers each rule in architecture.md.
- [ ] C: `server/tools/fakeClient.js` bots. AC: bots can run a full round.
- [ ] B: Lobby, role reveal, room map with manual tile picker, kill swipe, report/emergency buttons, meeting + vote, end screens. Depends on D Net. AC: 4 simulators/phones play a round with manual tiles.
- [x] B: dead-player screen telling the ghost to leave the phone and may wander.

## Phase 2: Tasks and sabotage
- [ ] B: Tasks in `MyApp/Tasks/`: shake/tilt balance, hold-steady, rotate dial, each calls `taskDone`. AC: each succeeds in under 15 s on a device and fails when idle.
- [ ] C: task counting for living crew only; `taskDone` validation.
- [ ] B+C: lights out + fix station. AC: tasks blocked while lights out.
- [ ] B (cut first): gesture-pattern task.

## Phase 3: Scan capture and server grid
- [ ] A: two-pass capture in one ARKit session (overview, then edge walk): record 720p mp4 plus `poses.json` (about 10 Hz) and intrinsics; guided UI with a pass timer. AC: both uploads succeed over the hotspot in under 30 s total.
- [ ] A: save ARWorldMap after pass 2, upload via `POST /map/:room`.
- [ ] C: upload endpoints, in-memory storage, `GET /map/:room`, `POST /scan/:room/process`.
- [ ] C: polygon + grid from the edge-walk path; `scan_failed` on open loop or area under 4 m^2. AC: a 5x5 m test walk gives dims within 1 tile; test with a recorded `poses.json` fixture, no phone needed.
- [ ] C: emergency tile at the centroid.
- [ ] D: shared `poses.json` fixture and sample `setup` JSON committed to `docs/fixtures/` early so A, B and C can work in parallel.
- [x] B: host setup review screen (2D map, stations on edge tiles, move/delete/add, confirm).

## Phase 4: Relocalization and live tiles (A)
- [ ] A: load map, relocalize, 20 s timeout then manual mode. AC: 3 of 3 joiners relocalize in the real room, or fall back cleanly.
- [ ] A: compute tile and send at 2-4 Hz; server 2-report filter. AC: two phones standing together report the same tile 90 percent of the time.
- [ ] Decision gate (hour ~14): if relocalization fails in the real room, ship manual mode and remove AR from the demo path.

## Phase 5: Gemini stations and AR icons
- [ ] C: send both videos to Gemini Flash with JSON output; key from `.env`. AC: returns labeled, timestamped boxes for a test video.
- [ ] C: place stations: ray from pose at `t` through the box center, intersect the polygon, snap to the nearest edge tile, 2 tile spacing, label to task type. AC: on the fixture, at least 3 stations land on edge tiles.
- [ ] A: AR overlay: world-anchored question-mark icons on task tiles, EMERGENCY text icon on the emergency tile, wrench on the fix station during lights out, hidden for ghosts and until relocalized. AC: icons stay within one tile of the real spot on 2 phones.
- [x] B: icon assets and the 2D map equivalents for manual mode.

## Phase 6: Demo
- [ ] D: scripted run (scan, stations, one task, one kill, report, vote) rehearsed 3 times on hotspot. AC: under 3 minutes, no restarts.
- [ ] D: README setup verified on a clean machine.

## Open contract questions (from B)
The UI works around each of these today, see the gaps note at the top of `MyApp/UI/Session/SessionModels.swift`. Please settle them in `docs/architecture.md`.
- `lobby` has no host id. The UI treats `players[0]` as the host. Suggest `hostId`.
- Nothing says setup is confirmed. The host trusts its own `confirmSetup` until a new `setup` arrives. Suggest `setupConfirmed` on `lobby`.
- `state` has no server time, so cooldown and meeting countdowns compare `endsAt` with the phone clock. Suggest `now` (epoch ms) on `state`.
- `GameState` has no per-player task completion or emergency usage, so the UI tracks both on the phone.
- `result` does not name the impostor when the game ends by kills or tasks, so the end screen cannot reveal them. Suggest `impostorId` on the final `result`.
- `error` codes are not listed. There is also no `leave` or `ready` intent.
- For A: tile reporting is centralized. Conform one class to `PositionProvider` (`MyApp/UI/Position/PositionProvider.swift`: publish `tile` and `status`) and pass it to `RootView` as `PositionCoordinator(ar:)`. The coordinator sends `tile { tile, source }` at 2 Hz, so the AR module does not need to send it. `MapGrid.tile(atX:z:)` and `worldCenter(of:)` do the tile math, and `StationIcon(style: .world)` renders the AR icons through `ImageRenderer`.
