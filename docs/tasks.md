# Tasks

Owners: A = AR (Mac 1), B = UI/Tasks (Mac 2), C = Server (Windows), D = Contracts/Net/Integration. Cut order when behind: gesture task, sabotage, Gemini suggestions.

## Phase 0: Contracts (D, first hour; blocks everything)
- [ ] D: `MyApp/Models/` Codable types matching `docs/architecture.md`. AC: compiles; sample JSON round-trips.
- [ ] D: `MyApp/Net/GameClient.swift` (connect, send, receive, reconnect with playerId). AC: connects to the server and prints `lobby`.
- [x] C: `server/` skeleton (`ws`, rooms, `create`/`join`, `lobby`). AC: 4 fake clients join one room. Verified with automated tests and `npm run smoke`; all four clients receive identical lobby membership and ready state.

Backend/client coordination: the approved `ready` event and `Player.ready` / `Player.connected` fields are now in `docs/architecture.md`. D should include them in client models and networking. Disconnect clears ready status; reconnect preserves identity. The requested lobby milestone is complete; game phase transitions and private roles remain the next backend step.

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

## Phase 3: Scan and grid (A)
- [ ] A: RoomPlan scan, derive bounds, build Grid with 1 m tiles. AC: grid dims within 0.5 m of tape measure for a 5x5 m room.
- [ ] A: save ARWorldMap, upload via `POST /map/:room`; C stores in memory.
- [ ] A+D: `setRoom` upload with grid and stations; host UI to review.
- [ ] C: `GET /map/:room`.

## Phase 4: Relocalization and live tiles (A)
- [ ] A: load map, relocalize, 20 s timeout then manual mode. AC: 3 of 3 joiners relocalize in the real room, or fall back cleanly.
- [ ] A: compute tile and send at 2-4 Hz; server 2-report filter. AC: two phones standing together report the same tile 90 percent of the time.
- [ ] Decision gate (hour ~14): if relocalization fails in the real room, ship manual mode and remove AR from the demo path.

## Phase 5: Gemini stations
- [ ] C: `suggest` endpoint calling Gemini Flash with JSON output; key from `.env`. AC: returns labeled boxes for a test photo.
- [ ] A: capture frames, raycast box centers to tiles, map labels to task types.
- [ ] B: host accept/reject UI. AC: at least 3 stations placed in a scan.

## Phase 6: Demo
- [ ] D: scripted run (scan, stations, one task, one kill, report, vote) rehearsed 3 times on hotspot. AC: under 3 minutes, no restarts.
- [ ] D: README setup verified on a clean machine.
