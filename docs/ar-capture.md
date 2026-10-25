# AR capture: perimeter walk and sticky-note sweep (for Owner A)

You record and upload. The server does all room geometry, note detection and station placement. Read `docs/architecture.md`, section "Sticky-note scan", for the contract. This file is the app-side checklist.

## What the host does
1. **Perimeter walk** (30 to 60 s): walk once around the room edge, close to the walls, and finish where you started. No video.
2. **Pick a vantage tile**: the app shows the 2D room map with a suggested tile near the middle. Tap another playable tile if you prefer. Walk to it; the map shows your live position.
3. **Sweep** (about 30 s): stand still on that tile, hold the phone at chest height, and turn slowly through a full circle (about 10 to 12 degrees per second), keeping the walls in view.
4. The app uploads, then shows the draft stations for review. Review and confirm already exist in `MyApp/UI/Setup/`.

All of this is one `ARSession` with `ARWorldTrackingConfiguration`. Do not restart or pause it between steps: the perimeter and the sweep must share one world frame, and the ARWorldMap saved at the end must describe that same frame.

## State machine
`idle -> perimeter -> uploadingPerimeter -> pickingVantage -> walkingToVantage -> sweeping -> uploadingSweep -> savingMap -> done`
Errors from any upload return to the step before it with the server's message. A `SCAN_FAILED` after the perimeter means walk again.

## Perimeter walk
- Log one sample about every 0.1 s from `session(_:didUpdate:)`: `{ t, x, y, z, qx, qy, qz, qw }` from `frame.camera.transform` (position = `columns.3`, rotation = `simd_quatf(transform)` as `ix, iy, iz, r`). `t` is seconds since you tapped Start.
- Only keep samples while `frame.camera.trackingState == .normal`. If tracking degrades, show "Move slower, point at the walls", and do not record until it recovers.
- Stop when the host taps Done. Warn if the end is more than about 0.75 m from the start ("walk back to where you started"). 100 to 3000 samples.
- Show elapsed time and a "walk close to the walls" hint. A few tenths of a meter of drift is fine.
- Upload with `ScanClient.uploadPerimeter(poses:)`. The server answers with `setup`, which carries the grid (`origin`, `playable`, `edge`). The map view already draws it.

## Vantage
- Suggest the playable tile closest to the grid center. Convert the live camera position to a tile with `MapGrid.tile(atX:z:)` from `MyApp/UI/Session/SessionModels.swift` (`floor((pos - origin) / 1.0)`, same ARKit frame as the walk).
- Enable "Start sweep" only when the live tile equals the chosen tile.

## Sweep
- Record yaw from the pose. Draw a progress ring from accumulated yaw. Finish at 340 to 360 degrees, or at 45 s, whichever comes first.
- Sample about 2 frames per second, up to 60 total. For each sampled `ARFrame` keep the pose, the JPEG and one set of intrinsics:
  - JPEG from `frame.capturedImage` (a `CVPixelBuffer`), **not rotated**: keep ARKit's native landscape orientation. Quality about 0.7. Each frame must stay under 600 KiB; if larger, lower the quality before reducing size. Do not reduce the long edge below 1280 px: a note is only a few dozen pixels wide and small images lose it.
  - Intrinsics from `frame.camera.intrinsics` (`fx = m[0][0]`, `fy = m[1][1]`, `cx = m[2][0]`, `cy = m[2][1]`) and `frame.camera.imageResolution` (`width`, `height`). If you resize the JPEG, multiply all six values by the same factor.
- Skip a frame if tracking is not `.normal` or if the yaw changed more than 30 degrees per second since the last sample (motion blur). Require at least 24 good frames; otherwise ask the host to redo the sweep more slowly.
- Remember the vantage tile you told the host to use and send it as `vantage`.
- Upload with `ScanClient.uploadSweep(vantage:intrinsics:frames:)`. Payloads reach tens of megabytes, so show progress and do not block the main thread while encoding.

## ARWorldMap
After the sweep upload succeeds, call `session.getCurrentWorldMap`, archive it, and send the bytes with `ScanClient.uploadMap(_:)` (this is `POST /map/:room`). Joiners download it and relocalize in Phase 4.

## Code you get from Owner D (on `main`)
- `MyApp/Models/ScanModels.swift`: `CameraPose`, `CameraIntrinsics`, `SweepFrame`, `PerimeterUpload`, `SweepUpload`.
- `MyApp/Net/ScanClient.swift`: `uploadPerimeter`, `uploadSweep`, and a server-error type. It reads the address from Settings, like `GameClient`.
- The host entry point: `RootView` already takes `startRoomScan: (() -> Void)?` and shows a "Scan room" button only when it is set. Present your capture flow from that closure in `ContentView`.

## Test it without a server
- Fixture: `docs/fixtures/poses.json` is a 5 x 5 m perimeter walk. `docs/fixtures/postit/sweep-observations.json` shows what a sweep looks like (it has boxes instead of JPEGs).
- Reference geometry and its check: `node docs/fixtures/postit/check-geometry.js`. If your poses and intrinsics are in the right frame, the same math recovers the note tiles. A systematic error in `yaw` or in the image orientation shows up here as notes landing on the wrong wall.
- With the server running (`cd server && npm run start:manual`), a perimeter upload should return 200 and trigger `setup`.

## Acceptance
- Perimeter: upload accepted, `setup` received, grid within one tile of a tape measure for a 5 x 5 m room.
- Sweep: 24 to 60 frames, each JPEG under 600 KiB, upload under 30 s on the hotspot.
- With 6 notes on the walls in a real room, the server reports `notesFound >= 4`. If not, record the note size, distance and light in `docs/tasks.md` so we can tune.
- Keep the AR session running throughout; the ARWorldMap saved after the sweep relocalizes on a second phone.

## Pitfalls
- Wrong image orientation or intrinsics is the most likely failure. The JPEG and intrinsics must describe the same pixels.
- Do not send frames while the host is walking to the vantage tile. Start the sweep timer only after they are on the tile.
- Poses must come from the same session as the perimeter. If the session restarts, start over.
- Notes more than about 4 m from the vantage tile get too small to detect. For a bigger room, say so: a second sweep from another tile is a possible extension, not part of this plan.
