# Integration notes (Owner D)

The contract source of truth is `docs/architecture.md` plus `server/CLIENT_INTEGRATION.md`. This file replaces the earlier Phase 0 notes, whose conflicts are resolved (the two-pass video pipeline is the selected design; `playable`/`edge` grids, `editStation`, `confirmSetup` and the configured emergency station are in the contract). The Swift code below was written on Windows and has **never been compiled or run by the author**. First action on a Mac: build the app, then run the round-trip script.

## What exists
| Piece | Path | State |
|---|---|---|
| Codable models | `MyApp/Models/GameModels.swift` | matches the server: nullable grid, `setupConfirmed`, no `blocked` |
| Wire messages + codec | `MyApp/Models/Messages.swift` | `setRoom` removed; `editStation`/`confirmSetup` added |
| Server address parsing | `MyApp/Net/ServerConfig.swift` | reads the Settings address |
| WebSocket client | `MyApp/Net/GameClient.swift` | connected to the real server from an iPhone and received `lobby`; reconnect untested |
| UI adapter | `MyApp/Net/LiveConnection.swift` | new, untested: maps `ClientIntent` to wire messages and wire messages to `ServerEvent` |
| App wiring | `MyApp/ContentView.swift` | mounts `RootView(session: live.session)`; mock only with a launch flag |
| Debug screen | `MyApp/Net/NetDebugView.swift` | not mounted; show it from `ContentView` temporarily if needed |
| Round-trip script | `Tests/ModelsRoundTrip/main.swift` | never run; also decodes `docs/fixtures` and `server/fixtures` |

Checked on Windows: all 42 server tests pass; `docs/fixtures/setup.json` and `server/fixtures/manual-setup.json` pass the server's own setup validator; a real four-client game against the server produced frames that contain every field the Swift decoders require (joined, lobby, setup, role, state, error).

## Run it (Mac)
1. Start the server: `cd server && npm install && npm run start:manual`. `start:manual` seeds each new room with the developer fixture so setup can be confirmed without a scan. Plain `npm start` rooms have no grid until the scan pipeline exists.
2. Info settings (MyApp target, Info tab): Local Network Usage Description, and App Transport Security > Allow Arbitrary Loads = YES.
3. Run the app on a phone or the Simulator. Settings > server address `<laptop-ip>:8080` (Simulator: leave blank for localhost).
4. To use the mock UI instead of the server (Debug builds): add the launch argument `-useMock YES`, or any `-mockScenario <name>`.
5. Model check, from the repo root: `swiftc MyApp/Models/*.swift Tests/ModelsRoundTrip/main.swift -o /tmp/rt && /tmp/rt`.

Flow to test with four devices: host creates a room; others join by code; host reviews and confirms setup; all four connected; host starts.

## Changes made to B's files (additive, please review)
- `SessionModels.swift`: `PlayerInfo` gains `ready` and `connected` (defaulted). `ClientIntent` gains `.ready(Bool)`. `ServerEvent` gains `.setupStatus(confirmed:)`.
- `GameSession.swift`: handles `.setupStatus`; new `setReady(_:)`; `lobbyStatus` counts connected players only.
- Not changed: no UI shows `ready` or `connected` yet, and nothing calls `setReady`. That is B's call.

## Still open
- **Scan pipeline:** the server routes exist. A real room still needs YOLOE installed on the server laptop (`server/README.md`) and an iPhone scan; `start:manual` rooms remain the quickest way to reach Start.
- **Host id:** the server now sends `lobby.hostId`. `LobbySnapshot.hostId` decodes it, the adapter emits `.host(id:)`, and `GameSession.hostID` prefers it (falls back to `players[0]`). Untested on a device.
- **Not in the contract yet:** server time on `state`, per-player completed stations, impostor id on `result`, `leave`. See "Open contract questions" in `docs/tasks.md`.
- **Reconnect loop risk:** the server closes a replaced socket with code 4000, and the client may try to reconnect after it. Untested.
- **A (AR):** done in `ContentView` (position provider and the Scan room button). Not device-verified. B should reword the lobby setup card, which still describes the old two-video scan.
- **Phase 4 (relocalization on a second phone)** is not covered by any test yet.

## Sticky-note scan integration (pivot)
The scan is a perimeter walk plus one 360-degree sweep, with yellow sticky notes on the walls. Contract: `docs/architecture.md` ("Sticky-note scan"). App-side spec for A: `docs/ar-capture.md`. Gemini prompt: `server/prompts/station-planning.md`.

| Piece | Owner | State |
|---|---|---|
| Upload models and `ScanClient` (`MyApp/Models/ScanModels.swift`, `MyApp/Net/ScanClient.swift`) | D | written; A's Mac checks compiled an earlier version; the off-main-actor encode is new and uncompiled |
| Reference geometry, synthetic sweep, `check-geometry.js`, `contract-check.js` (`docs/fixtures/postit/`) | D | pass in Node; the contract check passes against C's server |
| `POST /scan/:room/perimeter` and `/sweep`, polygon and grid, per-frame YOLOE, placement, selection | C | built; 76 server tests pass; `node server/tools/testSweep.js --fixture` gives 6 notes, 3 task + 1 fix + emergency. Real YOLOE and a real room not yet verified |
| Perimeter walk, vantage picker, sweep capture, ARWorldMap save, live tile reporting | A | built (`MyApp/AR/`), Mac checks written; not device-verified |
| Host setup review screen | B | exists; now talks to the real server through `LiveConnection` |
| Core Motion tasks: shake, balance, dial, steady, tilt pattern (`MyApp/Tasks/`) | B | merged from `feature/ios-gameplay`; not device-verified |

Integration order and status:
1. Perimeter endpoint against `docs/fixtures/poses.json`: **done** (contract check passes).
2. D debug buttons for perimeter and sweep in `NetDebugView`: **written**, untried on a device.
3. Sweep endpoint with detections injected: **done** (`testSweep.js --fixture`). The real YOLOE call needs the Python runtime: see `server/README.md`.
4. A's capture with real poses and frames: **built, awaiting the iPhone test** in `Tests/ARScanChecks/README.md`.
5. Real room: record the note size, distance and lighting that work. Main risk of the pivot, still open.

Server-side notes for C: when YOLOE is not installed, `POST /scan/:room/sweep` returns `SCAN_FAILED` (422) with the message "YOLOE is not ready". A distinct code such as `DETECTOR_UNAVAILABLE` (503) would let clients tell it apart from a bad scan. A frame with detections must be exactly the size the intrinsics describe or the server returns `SCAN_UPLOAD_INVALID`.

Risks: small notes at 3 to 4 m are only a few dozen pixels; the ARKit image orientation and intrinsics must match the JPEG; heading drift can move a note to a neighboring tile near tile boundaries (accepted, the host edits); fewer than 4 notes found means the host places the rest by hand.

## Demo checklist (draft)
Before: laptop on the phone hotspot, `npm run start:manual` (until scan exists), LAN IP in each phone's Settings, all phones on the hotspot, Info settings added.
1. Host creates a room; three phones join with the 4-letter code.
2. Host reviews setup on the map and confirms.
3. Host starts. Roles are revealed privately.
4. A crew player picks their tile, walks to a station, completes one task.
5. The impostor kills a player on the same tile; the victim sees the ghost screen.
6. Another player reports the body; the meeting opens; everyone votes; the result and winner show.
Target: under 3 minutes with no restart. Rehearse three times and note failures.
