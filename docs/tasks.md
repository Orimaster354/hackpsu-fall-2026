# Tasks

Owners: A = AR (Mac 1), B = UI/Tasks (Mac 2), C = Server (Windows), D = Contracts/Net/Integration. Cut order when behind: gesture task, sabotage, Gemini suggestions.

## Phase 0: Contracts (D, first hour; blocks everything)
- [ ] D: `MyApp/Models/` Codable types matching `docs/architecture.md`. AC: compiles; sample JSON round-trips.
- [ ] D: `MyApp/Net/GameClient.swift` (connect, send, receive, reconnect with playerId). AC: connects to the server and prints `lobby`.
- [x] C: `server/` skeleton (`ws`, rooms, `create`/`join`, `lobby`). AC: 4 fake clients join one room. Verified with automated tests and `npm run smoke`; all four clients receive identical lobby membership and ready state.

Backend/client coordination: approved wire details (ready/connected fields, flat state/meeting messages, emergency tile, two-report manual tiles, Gemini boxes and map upload ownership) are recorded in `docs/architecture.md`. D should align client models/networking with these details. Roles remain private; disconnect clears readiness and reconnect preserves identity.

Live-video coordination (user-approved): A+D should implement host/lobby-only `scan_start`, `scan_frame`, `scan_stop` and handle private `scan_status` / `scan_detections`, retaining each frame's AR pose/intrinsics by frameId. Backend limits are 1 FPS, 256 KiB/JPEG and 90 s per session. Intermediate frames can be dropped; boxes must use the matching captured frame, not the current camera pose. Camera capture must stop on game start/stopped status. See the updated architecture contract.

## Phase 1: Manual-tile game, end to end (no AR)
- [x] C: state machine for start, roles, tile, kill, report, emergency, meeting, vote, win. Depends on Phase 0. AC: `npm test` covers each rule in architecture.md. Verified server rules and WebSocket reconnect tests.
- [x] C: `server/tools/fakeClient.js` bots. AC: bots can run a full round. `npm run round` exercises four bots, private roles, a task, emergency meeting, voting, and victory.
- [ ] B: Lobby, role reveal, room map with manual tile picker, kill swipe, report/emergency buttons, meeting + vote, end screens. Depends on D Net. AC: 4 simulators/phones play a round with manual tiles.
- [ ] B: dead-player screen telling the ghost to leave the phone and may wander.

## Phase 2: Tasks and sabotage
- [ ] B: Tasks in `MyApp/Tasks/`: shake/tilt balance, hold-steady, rotate dial, each calls `taskDone`. AC: each succeeds in under 15 s on a device and fails when idle.
- [x] C: task counting for living crew only; `taskDone` validation. Tests cover location, role, duplicates, dead crew progress, and task victory.
- [ ] B+C: lights out + fix station. AC: tasks blocked while lights out. C server portion is implemented/tested, including 45 s cooldown and crew-only station fixes; B device UI integration remains pending.
- [ ] B (cut first): gesture-pattern task.

## Phase 3: Scan and grid (A)
- [ ] A: RoomPlan scan, derive bounds, build Grid with 1 m tiles. AC: grid dims within 0.5 m of tape measure for a 5x5 m room.
- [ ] A: save ARWorldMap, upload via `POST /map/:room`; C stores in memory. C's binary upload/store is implemented and tested; A's actual ARWorldMap upload remains pending.
- [ ] A+D: `setRoom` upload with grid and stations; host UI to review. Server-side host validation and setup handling are implemented/tested; A+D client integration remains pending.
- [x] C: `GET /map/:room`. Verified exact binary round-trip, room isolation, missing-map errors, host-only/size-limited uploads, and lobby-only writes.

## Phase 4: Relocalization and live tiles (A)
- [ ] A: load map, relocalize, 20 s timeout then manual mode. AC: 3 of 3 joiners relocalize in the real room, or fall back cleanly.
- [ ] A: compute tile and send at 2-4 Hz; server 2-report filter. AC: two phones standing together report the same tile 90 percent of the time.
- [ ] Decision gate (hour ~14): if relocalization fails in the real room, ship manual mode and remove AR from the demo path.

C dependency complete: server accepts validated tile reports with the two-consecutive-report filter for both `ar` and `manual` sources. Physical relocalization/accuracy acceptance criteria remain owned by A.

## Phase 5: Gemini stations
- [x] C: user-approved host/lobby continuous video interface (`scan_start`, `scan_frame`, `scan_stop`, private `scan_status`/`scan_detections`). Browser test streamed 6 sampled frames from a public 5-second MP4; Flash-Lite returned 2 frame-matched results with sensible labels (trees, bench, vehicles, fence). Latest capture-to-result latency was 18.8 s including queue time, so 1 FPS input is not a 1 FPS inference guarantee. All 30 automated tests pass. Native Gemini Live transport was tested but its labels were inaccurate; the user approved stateless Flash-Lite analysis behind the continuous feed. A+D iOS camera/pose integration and real room validation remain pending.
- [x] C: `suggest` endpoint calling Gemini Flash with JSON output; key from `.env`. AC: returns labeled boxes for a test photo. Verified with mocked provider/error tests and live end-to-end `npm run test:gemini` requests using Google's public scones JPEG. The tuned Flash-Lite configuration returned 12 concrete labels (including coffee mug, bowl, and spoon) with valid normalized boxes in about 3 seconds using the saved key. Generic labels are filtered. All 23 automated backend tests pass. Real room detection quality and station suitability still need host review during A/B integration. Keys remain in ignored `.env` only.
- [ ] A: capture frames, raycast box centers to tiles, map labels to task types.
- [ ] B: host accept/reject UI. AC: at least 3 stations placed in a scan.

## Phase 6: Demo
- [ ] D: scripted run (scan, stations, one task, one kill, report, vote) rehearsed 3 times on hotspot. AC: under 3 minutes, no restarts.
- [ ] D: README setup verified on a clean machine.
