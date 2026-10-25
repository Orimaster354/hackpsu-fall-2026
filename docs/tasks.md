# Tasks

Owners: A = AR (Mac 1), B = UI/Tasks (Mac 2), C = Server (Windows), D = Contracts/Net/Integration. Cut order when behind: gesture task, sabotage, Gemini placement (fall back to host-placed stations on edge tiles).

## Next acceptance priorities
1. **D — align and verify the phone client:** models and `GameClient` are now present from main. Make `LobbySnapshot.grid` nullable, retain `setupConfirmed` in lobby/setup models, and expose setup confirmation in the test UI. Verify lobby receive and reconnect against the running server. See `server/CLIENT_INTEGRATION.md`.
2. **B + D — play a complete manual-tile round on simulators/phones:** verify lobby/readiness, private role reveal, tile actions, task/kill/meeting/vote/end screens, and the ghost instructions. Server-side tests and bot round already pass; client integration is the remaining acceptance.
3. **B — finish and test task/sabotage UI on device:** confirm each motion task succeeds/fails as specified and lights-out blocks tasks until a crew member uses the fix station. Server rules are implemented and tested.
4. **A + C + D — establish scan-to-grid with a shared fixture before real-room AR:** capture/upload both passes, validate polygon/grid and emergency tile, then test host review and manual fallback. Gemini station placement and AR icons follow this foundation.

## Phase 0: Contracts (D, first hour; blocks everything)
- [ ] D: `MyApp/Models/` Codable types matching `docs/architecture.md`. AC: compiles; sample JSON round-trips.
- [ ] D: `MyApp/Net/GameClient.swift` (connect, send, receive, reconnect with playerId). AC: connects to the server and prints `lobby`.
- [x] C: `server/` skeleton (`ws`, rooms, `create`/`join`, `lobby`). AC: 4 fake clients join one room. Verified with `npm test` and `npm run smoke`; four clients receive the shared lobby and readiness state.

## Phase 1: Manual-tile game, end to end (no AR)
- [x] C: state machine for start, roles, tile, kill, report, emergency, meeting, vote, win. Depends on Phase 0. AC: `npm test` covers each rule in architecture.md. Verified by the game-rule and WebSocket tests.
- [x] C: `server/tools/fakeClient.js` bots. AC: bots can run a full round. Verified with `npm run round` reaching a synchronized crew victory.
- [ ] B: Lobby, role reveal, room map with manual tile picker, kill swipe, report/emergency buttons, meeting + vote, end screens. Depends on D Net. AC: 4 simulators/phones play a round with manual tiles.
- [ ] B: dead-player screen telling the ghost to leave the phone and may wander.

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
- [ ] D: shared `poses.json` fixture and sample `setup` JSON committed to `docs/fixtures/` early so A, B and C can work in parallel.
- [x] C: align backend lobby/game wire details with the approved architecture: retain ready/connected, add setupConfirmed, use nullable initial grid and flat state/meeting events. Handoff and sample lobby/setup/state JSON are in `server/CLIENT_INTEGRATION.md` and `server/fixtures/`. Four real WebSocket clients verify kill/report/vote and sabotage/fix/task synchronization; 37 automated tests pass.
- [ ] D: verify Codable models and GameClient against the backend handoff fixtures, then test on phones with B. Main now includes these paths, but nullable grid/setup confirmation alignment and device verification remain pending; backend tests do not satisfy this acceptance.
- [ ] B: host setup review screen (2D map, stations on edge tiles, move/delete/add, confirm).

## Phase 4: Relocalization and live tiles (A)
- [ ] A: load map, relocalize, 20 s timeout then manual mode. AC: 3 of 3 joiners relocalize in the real room, or fall back cleanly.
- [ ] A: compute tile and send at 2-4 Hz; server 2-report filter. AC: two phones standing together report the same tile 90 percent of the time.
- [ ] Decision gate (hour ~14): if relocalization fails in the real room, ship manual mode and remove AR from the demo path.

## Phase 5: Gemini stations and AR icons
- [x] C: host-only single-photo Gemini suggestions with normalized object boxes. Verified with mocked tests and a live public test photo; this does not satisfy two-video timestamped detection or place stations.
- [x] C: host-only continuous scan-frame WebSocket lifecycle, bounded buffering, frame-correlated private detections, and stop-on-game-start/disconnect. Automated tests and a browser sample-video run verified the server path; iOS camera/pose integration remains pending.
- [ ] C: send both videos to Gemini Flash with JSON output; key from `.env`. AC: returns labeled, timestamped boxes for a test video.
- [x] C: local two-video upload diagnostic at `/dashboard/videos`, using full MP4 uploads, timestamped per-pass boxes, progress, cancellation and provider file cleanup. Mocked adapter/HTTP tests pass; the live-video acceptance above remains open until actual room clips produce useful results.
- [ ] C: place stations: ray from pose at `t` through the box center, intersect the polygon, snap to the nearest edge tile, 2 tile spacing, label to task type. AC: on the fixture, at least 3 stations land on edge tiles.
- [ ] A: AR overlay: world-anchored question-mark icons on task tiles, EMERGENCY text icon on the emergency tile, wrench on the fix station during lights out, hidden for ghosts and until relocalized. AC: icons stay within one tile of the real spot on 2 phones.
- [ ] B: icon assets and the 2D map equivalents for manual mode.

## Phase 6: Demo
- [ ] D: scripted run (scan, stations, one task, one kill, report, vote) rehearsed 3 times on hotspot. AC: under 3 minutes, no restarts.
- [ ] D: README setup verified on a clean machine.
