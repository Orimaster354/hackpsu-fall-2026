# ARKit branch integration handoff

Inspected `origin/feature/arkit` at `f7f49a7` against the local backend scan implementation. No Swift or Xcode files were changed. This is a source/contract audit and backend verification, not an iPhone build or real-room acceptance.

## What is ready

- `ContentView` retains the real connection, passes `ARPositionProvider`, and opens `RoomScanView` from the lobby scan action.
- `RoomScanFlow` records the perimeter, waits for setup, chooses a vantage, captures the sweep, then saves/uploads the world map. The branch removed its stand-in scan server.
- `SweepFrameEncoder` preserves native image orientation, checks JPEG size/orientation and scales intrinsics to the encoded dimensions.
- `ScanClient` uses the correct JSON bodies, `X-Player-Id`, and `/scan/:room/perimeter` / `/scan/:room/sweep`. Its result types match the backend responses. Sweep timeout is 180 seconds.
- `LiveScanBackend` uses `GameClient.uploadMap`; map requests use the correct binary route/headers. `ARPositionProvider` downloads the map, relocalizes, and supplies tiles through the UI coordinator, with manual fallback.
- The branch models handle nullable lobby grid, hostId and setupConfirmed. Earlier main-checkout warnings about those missing fields do not describe this ARKit branch.

## Verification performed on Windows

- Both the ARKit branch's `Tests/ARScanChecks/contract.js` and the production backend validator accepted the same synthetic native-size upload: 24 JPEG frames, 1920x1440, about 45 KiB each, matching intrinsics and finite/unit poses.
- That synthetic payload completed against the live server in 30.2 seconds on this laptop, below the client's 180-second timeout. This is one measurement, not a worst-case latency guarantee. All frames reuse a painted yellow-marker image with synthetic camera yaw; its projected note count is not a physical-room count or accuracy result.
- A new four-WebSocket-client regression covers perimeter -> six-note fixture sweep -> opaque map byte round-trip -> confirm -> private roles -> AR tile reports -> synchronized task completion. Synthetic map bytes prove transport, not valid ARWorldMap decoding or relocalization.
- Repeating the same perimeter succeeds and broadcasts a fresh `setup` even when the grid values are unchanged.
- 76 backend tests pass. Existing six-note geometry acceptance is preserved.
- Mac Swift checks and device capture were not run here. No real ARKit perimeter/sweep export is present in the backend checkout or the checked Downloads files.

## Owner A/D issue to fix before relying on upload retries

`MyApp/AR/RoomScanFlow.swift`, `waitForGrid(result:before:epoch:)`, requires `grid != before`. A retry of identical poses legitimately produces an equal grid. The backend rebroadcasts setup, but this condition still times out after eight seconds. Use a client-side setup receipt generation/counter to acknowledge a new event, rather than comparing grid values. Keep the HTTP-success and matching dimensions checks. This requires no new wire field. The backend retry regression reproduces the equal-grid/fresh-event case.

`ScanClient.post` also calls `JSONEncoder().encode(body)` synchronously from the main-actor capture flow. Large sweep encoding can pause the screen; move encoding off the main actor if profiling confirms it. This was already noted by A in the branch task notes. No Swift files were edited from Owner C's branch.

## Next device run

1. Build the latest `feature/arkit` app on Owner A's Mac; run its `Tests/ARScanChecks/run_scan_checks.sh` there first. Device acceptance remains separate from those checks.
2. Keep the normal Windows backend running with `npm.cmd start` (not the manual fixture for this scan test). The currently advertised address is `104.39.23.109:8080`; recheck `/api/dashboard` or `ipconfig` if networks change.
3. Phone and laptop must be reachable on the same network. Open `http://104.39.23.109:8080/health` in Safari, then set the app's server address to `104.39.23.109:8080`. Avoid mock launch flags and localhost on a physical phone.
4. Create a fresh room and tap Scan room. Record the perimeter grid/origin and emergency tile; complete the vantage/sweep flow with 6-8 large yellow wall notes.
5. Record actual `notesFound`, final station tiles, upload duration, projection-check error, JPEG dimensions/intrinsics and world-map upload result. Compare against measured room size and known note locations.
6. Confirm setup, connect joiners, and check relocalization/tiles or manual fallback. The backend already supports the full flow; four-phone physical acceptance is still open.

The Mac does not need to run its older copy of `server/` to test the iOS branch against this Windows backend. The local backend implementation has not yet been pushed to GitHub; do not assume checking out the ARKit branch also installs these scan endpoints on another machine.
