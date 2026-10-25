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
- **Scan pipeline (Phase 3)** is not built on the server, so real rooms have no grid. Only `start:manual` rooms can reach Start.
- **Host id:** `lobby` has no `hostId`; the UI uses `players[0]`.
- **Not in the contract yet:** server time on `state`, per-player completed stations, impostor id on `result`, `leave`. See "Open contract questions" in `docs/tasks.md`.
- **Reconnect loop risk:** the server closes a replaced socket with code 4000, and the client may try to reconnect after it. Untested.
- **A (AR):** pass `position:` and `startRoomScan:` in `ContentView` when ready.

## Demo checklist (draft)
Before: laptop on the phone hotspot, `npm run start:manual` (until scan exists), LAN IP in each phone's Settings, all phones on the hotspot, Info settings added.
1. Host creates a room; three phones join with the 4-letter code.
2. Host reviews setup on the map and confirms.
3. Host starts. Roles are revealed privately.
4. A crew player picks their tile, walks to a station, completes one task.
5. The impostor kills a player on the same tile; the victim sees the ghost screen.
6. Another player reports the body; the meeting opens; everyone votes; the result and winner show.
Target: under 3 minutes with no restart. Rehearse three times and note failures.
