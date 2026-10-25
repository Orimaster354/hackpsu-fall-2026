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
- [ ] B: dead-player screen telling the ghost to leave the phone and may wander.

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
- [ ] B: host setup review screen (2D map, stations on edge tiles, move/delete/add, confirm).

## Phase 4: Relocalization and live tiles (A)
- [ ] A: load map, relocalize, 20 s timeout then manual mode. AC: 3 of 3 joiners relocalize in the real room, or fall back cleanly.
- [ ] A: compute tile and send at 2-4 Hz; server 2-report filter. AC: two phones standing together report the same tile 90 percent of the time.
- [ ] Decision gate (hour ~14): if relocalization fails in the real room, ship manual mode and remove AR from the demo path.

## Phase 5: Gemini stations and AR icons
- [ ] C: send both videos to Gemini Flash with JSON output; key from `.env`. AC: returns labeled, timestamped boxes for a test video.
- [ ] C: place stations: ray from pose at `t` through the box center, intersect the polygon, snap to the nearest edge tile, 2 tile spacing, label to task type. AC: on the fixture, at least 3 stations land on edge tiles.
- [ ] A: AR overlay: world-anchored question-mark icons on task tiles, EMERGENCY text icon on the emergency tile, wrench on the fix station during lights out, hidden for ghosts and until relocalized. AC: icons stay within one tile of the real spot on 2 phones.
- [ ] B: icon assets and the 2D map equivalents for manual mode.

## Phase 6: Demo
- [ ] D: scripted run (scan, stations, one task, one kill, report, vote) rehearsed 3 times on hotspot. AC: under 3 minutes, no restarts.
- [ ] D: README setup verified on a clean machine.

## AR integration notes (2026-10-24)
- The AR branch follows the new capture-only contract: local RoomPlan geometry, grid generation and rectangular-room completion have been removed. Physical acceptance criteria remain unchecked.
- D/B: `ARTrackingSession.configureGrid(...)` accepts the documented server Grid fields; map `Tile` values to `SIMD2<Int>`. Connect `onTileReport(x, y, source)` to GameClient's `tile` message and `onManualModeRequested` to B's manual picker. Configure the grid and icon presentation inputs after loading the world map; loading a new map clears old setup to prevent cross-room rendering.
- D/B: translate Stations into `ARStationIcon` presentation inputs and call `setStationIcons(_:alive:lightsOut:)` on setup/state changes. Per-player completed station IDs are needed to dim individual icons, but are absent from the current GameState contract. Agree how they are supplied; AR does not infer completion from tasksDone.
- D/C: capture JSON matches the documented fields. Video is center-cropped to 1280x720 in native sensor orientation (no display rotation); intrinsics are transformed to that encoded image. Pose quaternions are camera-to-world, scalar-last, in the shared ARKit frame; camera forward is local -z. Each pass's time zero is its first encoded frame.
- C/D: HTTP host identification is not specified. AR currently sends only the documented multipart/binary fields and routes; agree host validation before calling these end-to-end verified.
- App owner/D: inspect local-network privacy and ATS settings for HTTP LAN/hotspot use (`NSLocalNetworkUsageDescription`, scoped `NSAppTransportSecurity`/`NSAllowsLocalNetworking` as appropriate). AR has not changed the app plist or weakened transport policy.
- D/B: icon elevation is unspecified. The initial overlay uses world y=0 (host session's starting camera height); agree a floor/height reference if needed. No new field was added to Grid or Station.
- D: Models, GameClient and docs/fixtures are still absent from this checkout. Primitive adapters and a local HTTP test server permit AR work without creating competing gameplay models; real server setup/WebSocket integration remains pending.
