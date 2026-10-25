# Tasks

Owners: A = AR (Mac 1), B = UI/Tasks (Mac 2), C = Server (Windows), D = Contracts/Net/Integration. Cut order when behind: gesture task, sabotage, Gemini placement (fall back to host-placed stations on edge tiles).

## Merge audit (2026-10-25)
Latest main's UI and D networking/models are preserved alongside the backend. Backend acceptance is verified by 42 automated tests plus four-client lobby and complete-round simulations. B's checked UI items below are carried forward from main and have source implementations; this Windows audit does not claim a Mac build or device acceptance. Unchecked end-to-end criteria remain open. The normal app mounts `RootView()`, whose default initializer uses `MockServer`; it does not yet exercise the real backend.

## Next acceptance priorities
1. **D — connect the UI to the backend:** wire a retained `GameClient` into `GameSession.send` / `receive` and pass that session to `RootView` instead of its default mock. Make `LobbySnapshot.grid` nullable, decode `lobby.hostId`, retain server `setupConfirmed` in lobby/setup models, and map ready/connected and setup confirmation to UI state. Stop automatic reconnect on replacement close code 4000. Verify lobby receive and reconnect against the running server. See `server/CLIENT_INTEGRATION.md` and the rewritten current `docs/integration.md`.
2. **B + D — play a complete manual-tile round on simulators/phones:** verify lobby/readiness, private role reveal, tile actions, task/kill/meeting/vote/end screens, and the ghost instructions. Server-side tests and bot round already pass; client integration is the remaining acceptance.
3. **B — finish and test task/sabotage UI on device:** confirm each motion task succeeds/fails as specified and lights-out blocks tasks until a crew member uses the fix station. Server rules are implemented and tested.
4. **A + C + D — establish scan-to-grid with a shared fixture before real-room AR:** capture/upload both passes, validate polygon/grid and emergency tile, then test host review and manual fallback. Gemini station placement and AR icons follow this foundation.

## Phase 0: Contracts (D, first hour; blocks everything)
- [ ] D: `MyApp/Models/` Codable types matching `docs/architecture.md`. AC: compiles; sample JSON round-trips.
- [ ] D: `MyApp/Net/GameClient.swift` (connect, send, receive, reconnect with playerId). AC: connects to the server and prints `lobby`.
- [x] C: `server/` skeleton (`ws`, rooms, `create`/`join`, `lobby`). AC: 4 fake clients join one room. Verified with `npm test` and `npm run smoke`; four clients receive the shared lobby and readiness state.
- [x] C: integration contract audit, approved `lobby.hostId`, and client error/close-code reference (`server/ERROR_CODES.md`). All 45 backend tests pass, including explicit host identity, protocol ping/pong, replacement close code 4000, stale-close protection and rejected reconnects. Existing scan/setup decisions are consolidated in `docs/integration.md`; D's client retry fix remains pending.

## Phase 1: Manual-tile game, end to end (no AR)
- [x] C: state machine for start, roles, tile, kill, report, emergency, meeting, vote, win. Depends on Phase 0. AC: `npm test` covers each rule in architecture.md. Verified by the game-rule and WebSocket tests.
- [x] C: `server/tools/fakeClient.js` bots. AC: bots can run a full round. Verified with `npm run round` reaching a synchronized crew victory.
- [ ] B: Lobby, role reveal, room map with manual tile picker, kill swipe, report/emergency buttons, meeting + vote, end screens. Depends on D Net. AC: 4 simulators/phones play a round with manual tiles.
- [x] B: dead-player screen telling the ghost to leave the phone and may wander.

## Phase 2: Tasks and sabotage
- [ ] B: Tasks in `MyApp/Tasks/`: shake/tilt balance, hold-steady, rotate dial, each calls `taskDone`. AC: each succeeds in under 15 s on a device and fails when idle.
- [x] C: task counting for living crew only; `taskDone` validation. Tests cover location, role, duplicates, dead-crew progress, and task victory.
- [x] C: lights-out state, task blocking, fix-station validation, and sabotage cooldown. Verified by server tests; B's UI and device acceptance remain pending.
- [ ] B: lights-out + fix-station UI. AC: in the app, tasks are blocked while lights are out and resume after a valid crew fix.
- [ ] B (cut first): gesture-pattern task.

## Phase 3: Scan capture and server grid
- [ ] A: two-pass capture in one ARKit session (overview, then edge walk): record 720p mp4 plus `poses.json` (about 10 Hz) and intrinsics; guided UI with a pass timer. AC: both uploads succeed over the hotspot in under 30 s total.
- [ ] A: save ARWorldMap after pass 2 and upload it via `POST /map/:room`.
- [x] C: host-only in-memory ARWorldMap `POST /map/:room` and `GET /map/:room`. Verified binary round-trip, room isolation, authorization, size limits, and lobby-only uploads.
- [ ] C: scan-pass upload endpoints, in-memory pass storage, and `POST /scan/:room/process`.
- [x] C: server-produced setup validation and host-only `editStation` / `confirmSetup`. Verified nullable initial grid, playable/edge schema and origins, atomic edge edits, 2 m Euclidean spacing, immutable emergency, confirmation lock, reconnect and confirmed start. Developer fixture enables manual integration before scan processing; clients cannot send `setRoom`.
- [ ] C: polygon + grid from the edge-walk path; `scan_failed` on open loop or area under 4 m^2. AC: a 5x5 m test walk gives dims within 1 tile; test with a recorded `poses.json` fixture, no phone needed.
- [ ] C: emergency tile at the centroid.
- [x] D: shared synthetic `poses.json`, `intrinsics.json` and sample `setup` JSON committed to `docs/fixtures/`. JSON parses and setup passes backend validation. These are synthetic inputs, not proof of capture or geometry processing.
- [x] C: align backend lobby/game wire details with the approved architecture: retain ready/connected, add setupConfirmed, use nullable initial grid and flat state/meeting events. Handoff and sample lobby/setup/state JSON are in `server/CLIENT_INTEGRATION.md` and `server/fixtures/`. Four real WebSocket clients verify kill/report/vote and sabotage/fix/task synchronization; 42 automated tests pass including video-diagnostic mocks.
- [ ] D: verify Codable models and GameClient against the backend handoff fixtures, then test on phones with B. Main now includes these paths, but nullable grid/setup confirmation alignment and device verification remain pending; backend tests do not satisfy this acceptance.
- [x] B: host setup review screen (2D map, stations on edge tiles, move/delete/add, confirm). UI implementation present from main; server acknowledgement and real-phone integration remain D/B acceptance work.

## Phase 4: Relocalization and live tiles (A)
- [ ] A: load map, relocalize, 20 s timeout then manual mode. AC: 3 of 3 joiners relocalize in the real room, or fall back cleanly.
- [ ] A: compute tile and send at 2-4 Hz; server 2-report filter. AC: two phones standing together report the same tile 90 percent of the time.
- [ ] Decision gate (hour ~14): if relocalization fails in the real room, ship manual mode and remove AR from the demo path.

## Phase 5: Gemini stations and AR icons
- [x] C: host-only single-photo Gemini suggestions with normalized object boxes. Verified with mocked tests and a live public test photo; this does not satisfy two-video timestamped detection or place stations.
- [x] C: host-only continuous scan-frame WebSocket lifecycle, bounded buffering, frame-correlated private detections, and stop-on-game-start/disconnect. Automated tests and a browser sample-video run verified the server path; iOS camera/pose integration remains pending.
- [ ] C: useful timestamped detections on actual two-pass room clips. Updated pipeline: YOLOE detects, Gemini reasons over candidate metadata; key from `.env`. Public smoke clips do not satisfy real-room acceptance.
- [x] C: local two-video upload diagnostic at `/dashboard/videos`, using full MP4 uploads, timestamped per-pass boxes, progress, cancellation and provider file cleanup. Mocked adapter/HTTP tests pass; the live-video acceptance above remains open until actual room clips produce useful results.
- [x] C: optional local YOLOE-26 Small detector comparison with decoded-frame timestamps, scores and frame previews. Official checkpoint/text encoder warm-up and public COCO clip inference verified on the laptop; real moving-room comparison and station placement acceptance remain pending.
- [x] C: promote YOLOE to the diagnostic default; retain class diversity instead of allowing chairs to crowd out all other classes; expose per-class filtering counts. Add metadata-only Gemini landmark/task suggestions with validated candidate IDs, conservative score shortlist and explicit pending-geometry status. Verified with 58 Node tests, four Python tests and a live Gemini metadata planning call on public smoke detections. User room clips and physical placement remain unverified.
- [ ] C: place stations: ray from pose at `t` through the box center, intersect the polygon, snap to the nearest edge tile, 2 tile spacing, label to task type. AC: on the fixture, at least 3 stations land on edge tiles.
- [ ] A: AR overlay: world-anchored question-mark icons on task tiles, EMERGENCY text icon on the emergency tile, wrench on the fix station during lights out, hidden for ghosts and until relocalized. AC: icons stay within one tile of the real spot on 2 phones.
- [x] B: icon assets and the 2D map equivalents for manual mode.

## Phase 6: Demo
- [ ] D: scripted run (scan, stations, one task, one kill, report, vote) rehearsed 3 times on hotspot. AC: under 3 minutes, no restarts.
- [ ] D: README setup verified on a clean machine.

## Open contract questions (from B)
The source comments in `MyApp/UI/Session/SessionModels.swift` describe the older UI assumptions. Use the approved architecture and the status below; proposed new fields are not automatically approved or implemented.
- Resolved on the server: user approved `lobby.hostId`; it is now implemented and stable across reconnect. D/B must decode it and use it for host controls instead of player order.
- Resolved on the server: `setupConfirmed` is already approved and sent in `lobby` and `setup`. D must decode it and B's UI must use that acknowledgement rather than assuming local confirmation succeeded.
- `state` has no server time, so cooldown and meeting countdowns compare `endsAt` with the phone clock. Suggest `now` (epoch ms) on `state`.
- `GameState` has no per-player task completion or emergency usage, so the UI tracks both on the phone.
- `result` does not name the impostor when the game ends by kills or tasks, so the end screen cannot reveal them. Suggest `impostorId` on the final `result`.
- `ready` already exists in the server contract and D's `ClientMessage`; B's UI intent/state adapter still needs to expose it and connection status. `leave` is not implemented; disconnect retains the player's seat for reconnect. The current error-code and connection-close reference is `server/ERROR_CODES.md`.
- For A: tile reporting is centralized. Conform one class to `PositionProvider` (`MyApp/UI/Position/PositionProvider.swift`: publish `tile` and `status`) and pass it to `RootView` as `PositionCoordinator(ar:)`. The coordinator sends `tile { tile, source }` at 2 Hz, so the AR module does not need to send it. `MapGrid.tile(atX:z:)` and `worldCenter(of:)` do the tile math, and `StationIcon(style: .world)` renders the AR icons through `ImageRenderer`.
