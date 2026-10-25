# Fixtures

A 5 x 5 m room, edge walk, generated to match `docs/architecture.md`.

- `poses.json`: `[{t, x, y, z, qx, qy, qz, qw}]` at 10 Hz, 201 samples over about 20 s. ARKit world frame: y up, camera forward is -z, origin is the start point. The path is the square (0,0) to (4,4), 0.5 m inside the walls, one lap, closing back at (0,0). Camera yaw faces the nearest wall (segments 1 to 4: 0, -90, 180, +90 degrees about y). Yaw changes instantly at corners; real data will be smoother.
- `intrinsics.json`: `{fx, fy, cx, cy, width, height}` for a 1920 x 1080 frame.
- `setup.json`: the expected server output for that walk, as a `setup` message. `originX/originZ` is -0.5, so the walls bound tiles (0,0) to (4,4). Four task stations on edge tiles at least 2 apart, one fix station, one emergency station at the center (2,2).

Server (C): feeding `poses.json` should produce a 5 x 5 grid with 16 edge tiles. Station tiles depend on Gemini and will differ.
UI and AR (A, B): render `setup.json` directly to build the map and icons without a scan.

These are synthetic, not recorded from a phone. Replace `poses.json` with a real walk once A can capture one.

## Sticky-note scan (`postit/`)
- `poses.json` (above) is the perimeter walk: upload body is `{ "poses": <this array> }`.
- `postit/sweep-observations.json`: a synthetic sweep from tile (2,2) of the same room. 36 frames 10 degrees apart, 6 sticky notes on the walls, 40 detections with boxes (no JPEGs). `expectedNotes` lists the tile each note must map to; `noteId` inside detections is ground truth for the checker only.
- `postit/postit-geometry.js`: dependency-free reference for pixel to ray to wall to edge tile, merge, and 2 m spacing. Port it to `server/`.
- `postit/check-geometry.js`: `node docs/fixtures/postit/check-geometry.js` must print `OK`. `make-sweep-fixture.js` regenerates the fixture.
- `postit/contract-check.js`: black-box test for C. Start a plain `npm start` server and run `node docs/fixtures/postit/contract-check.js [http://127.0.0.1:8080]`; it checks the perimeter and sweep status codes, error codes and response shapes, the `setup` broadcast, edge tiles, 2 m spacing and the confirm lock. It fails with 404s until the endpoints exist. `postit/tiny-frame.jpg` is the JPEG it sends.
Synthetic data proves the math, not that the detector finds real notes.
