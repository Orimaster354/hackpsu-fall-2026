# ROOMSHIFT multiplayer server

Requires Node.js 22 or newer. On Windows PowerShell, use `npm.cmd` if `npm.ps1` is blocked by the execution policy.

```powershell
cd server
npm.cmd install
npm.cmd test
npm.cmd start
```

The server listens on port 8080 by default and binds to `0.0.0.0` for LAN testing. Copy `.env.example` to `.env` to set another `PORT` or configure optional Gemini suggestions. `GET /health` returns `{"ok":true}`. WebSocket clients connect to `/ws`.

In another terminal, run `npm.cmd run smoke`. This opens four fake clients, creates one room, joins the other three, marks each ready, and verifies all four receive identical membership and ready status. Each run creates a new in-memory room.

For an iPhone on the same LAN/hotspot, use `ws://<laptop-LAN-IP>:8080/ws`. On Windows, `ipconfig` shows the laptop's IPv4 address. Allow Node through Windows Firewall on the demo network if prompted. Physical iPhone integration is a separate test from the local simulated clients.

## Implemented messages

- Client: `{"t":"create","name":"Host"}`
- Client: `{"t":"join","room":"ABCD","name":"Player"}`
- Client: `{"t":"ready","ready":true}` (or `false`), updates only the connected sender in the lobby.
- Reconnect: send `join` with the same `room`, `name`, and previously received `playerId`.
- Server: `{"t":"joined","playerId":"...","room":"ABCD"}`
- Server: `{"t":"lobby","players":[...],"grid":{...},"stations":[],"hasMap":false}`
- Server error: `{"t":"error","code":"...","message":"..."}`

Room codes are four uppercase letters. A room holds four players; disconnected players remain in the room for reconnect. The initial grid is 5×5 with 1 m tiles. No roles or private game data are sent in lobby messages.

Each public player includes server-owned `connected` and `ready` booleans. Disconnects broadcast `connected=false` and clear readiness. Reconnect preserves identity and membership, broadcasts `connected=true`, and requires readying again. These fields and the `ready` event are documented in the approved architecture extension; the iOS networking/models owner must include them in the client contract.

## Game loop and full-round simulation

`npm.cmd run round` connects four bots and plays a complete round: room setup, ready, two-report manual tiles, host start, private roles, task completion, emergency meeting, votes, and crew victory. To join an existing lobby with one persistent bot, use `node tools/fakeClient.js ABCD`. `WS_URL` selects another server (default `ws://127.0.0.1:8080/ws`).

Implemented game intents: `setRoom`, `start`, `tile`, `taskDone`, `kill`, `report`, `emergency`, `vote`, `sabotage`, and `fix`. Server events include private `role` / `killed`, public `state`, `meeting`, `result`, and validation `error`. `state` fields are flat beside `t`; private roles never appear in player snapshots. Only the host may start with four connected players. Game phases are lobby → playing → meeting → playing/ended. The emergency tile is (0,0).

Send each tile twice consecutively, including manual tiles. Tile validation rejects blocked/out-of-bounds cells, and meetings/ghosts freeze movement. Kills require a living impostor, same-tile crew target, and a 25 s cooldown. Tasks count once per station per living crew member. Lights-out blocks tasks until a living crew member fixes a fix station; sabotage cooldown is 45 s. Meeting timers use epoch milliseconds and expire after 30 s or all living votes; a strict majority is required for ejection. See `../docs/architecture.md` for the authoritative shared contract.

## Local dashboard

With the server running, open `http://localhost:8080/dashboard` on the server laptop. The dashboard refreshes every second and displays room membership, ready/connection status, phases, grid details, open sockets, and uptime. Use **Launch 4 test players**, **Ready all**, and the disconnect/reconnect buttons to exercise the real WebSocket lobby without iPhones. Closing the page disconnects its test players; in-memory rooms remain visible until the server restarts.

`GET /api/dashboard` supplies an allowlisted monitor snapshot. Dashboard pages and data are restricted to loopback connections. They exclude hidden roles, full player IDs/reconnect credentials, and raw sockets. The activity list contains changes observed while the page is open. This developer view does not change the iPhone event protocol.

## ARWorldMap storage

`POST /map/ABCD` accepts raw binary with `Content-Type: application/octet-stream` and `X-Player-Id` set to the host's joined ID. Uploads require lobby phase and 1 byte–20 MiB; success is HTTP 204 and broadcasts `lobby.hasMap=true`. `GET /map/ABCD` returns the same bytes as `application/octet-stream`; it returns 404 until a map is uploaded. The server treats ARWorldMap as opaque bytes and keeps it in memory. These routes are available over LAN for iOS; dashboard routes remain laptop-only.

## Gemini suggestions and live acceptance check

Set `GEMINI_API_KEY` in the ignored `server/.env`; optionally set `GEMINI_MODEL` (default `gemini-3.1-flash-lite`, a low-latency model with a free tier). Restart the server after changing environment settings. No provider SDK or new dependency is required. The adapter uses the [official generateContent REST API](https://ai.google.dev/api/generate-content) and [image detection format](https://ai.google.dev/gemini-api/docs/generate-content/image-understanding).

Detection asks for at most 12 prominent objects and concrete names such as coffee mug, bookshelf, or desk lamp. Generic labels are omitted rather than renamed; an empty result means the host should retake the photo or place stations manually. Examples in the prompt are naming guidance, not a list of objects to assume. For better room results, take a steady, well-lit photo that shows complete furniture/landmarks and avoids tiny, heavily occluded details. The host still reviews whether detected objects are suitable stations.

The host sends `{ "t":"suggest", "photos":["<base64 JPEG>"] }` in the lobby. Limits: one JPEG up to 4 MiB, one pending request per room, 45 s provider timeout. Response: `{ "t":"suggestions", "objects":[{"label":"Table","box":[0.2,0.1,0.6,0.3]}] }`. Boxes are normalized `[x,y,width,height]`, relative to the single image. They are not indoor positions; iOS must raycast them before the host uses `setRoom`. Provider failures return a recoverable `error`; the host places stations manually. Multiple keys in one project share its rate limits; this demo uses one configured key.

With the server running and a non-sensitive JPEG selected for sending to Gemini:

```powershell
npm.cmd run test:gemini -- C:\path\to\test-photo.jpg
```

This test creates a host room, sends the JPEG to Gemini, validates the returned labels/boxes, and exits. Gemini 3 models use low thinking; Gemini 2.5 Flash models disable thinking for this simple detection request, following the [provider's thinking settings](https://ai.google.dev/gemini-api/docs/generate-content/thinking). `npm test` uses mocked provider responses; it does not prove live image generation. The Phase 5 acceptance checkbox stays open until the live photo check passes.

## Internal rule interface

The WebSocket router resolves the socket's player and calls `room.game.handle(player, message)` for documented game intents. `Game.state()` returns the public GameState; `Game.publish()` broadcasts it using an explicit player allowlist. `room.sendTo(player, event)` is the private delivery path. Backend logic lives in `server/game.js` and `server/contracts.js`; integration changes should preserve `docs/architecture.md` and be coordinated with the client/game-rules owners. Test-only clock/random/timer injection is available through `createAppServer(options)` and cannot be set by client messages.

## Continuous host video scan

Start the server and open `http://localhost:8080/dashboard/live` for a laptop-only live-stream tester. Select a non-sensitive MP4 and click **Start live scan**. The video plays locally while JPEG frames continuously stream through `/ws` to the backend. Flash-Lite analyzes the latest available frame and results draw on the saved matching frame. The full MP4 is not uploaded. This tests the continuous path without needing an iPhone camera or FFmpeg.

For automation without local-file picker access, set the server environment variable `LIVE_SCAN_TEST_VIDEO` to a local MP4 path (up to 10 MiB), restart, and click **Use server test clip**. The configured file is served only on loopback at `/dashboard/demo-video`; no request can choose arbitrary server paths. Do not commit test media or keys.

The stream uses the existing `GEMINI_MODEL` (default `gemini-3.1-flash-lite`) and server-only `GEMINI_API_KEY`. It adds no dependencies. This is continuous sampled camera input with independent JSON detection requests, not temporal reasoning or stable object tracking. A native Gemini Live experiment streamed successfully but misidentified objects; the user approved the existing Flash-Lite detector behind the same continuous interface instead.

Client sequence: join/create a room as host, send `{"t":"scan_start"}`, wait for `scan_status` ready, then stream `{"t":"scan_frame","frameId":"frame-1","timestampMs":0,"jpeg":"<base64>"}` at up to 1 FPS. Frames are at most 256 KiB; scale the longest edge to 768 px. Each frame ID must be unique and timestamps strictly increase. A private reply is `{"t":"scan_detections","frameId":"frame-1","timestampMs":0,"objects":[{"label":"desk lamp","box":[0.2,0.1,0.3,0.4]}]}`. Boxes use normalized image x/y/width/height.

Send `{"t":"scan_stop"}` to finish. Sessions are limited to 90 s and close automatically on game start or host disconnect/reconnect. The server keeps one analyzed frame and only the latest waiting frame, so intermediate frames can be dropped. Each result is tied to the accepted frame ID/timestamp, but Gemini's box accuracy is approximate. A+D must retain AR poses/intrinsics for matching frames and stop camera capture on scan stop or game start. Gameplay position tracking remains tile-based.

Verification: the browser streamed six frames from [Samplelib's public five-second video](https://samplelib.com/sample-mp4.html), and Flash-Lite returned two matched frames with concrete labels (trees, bench, vehicles, fence). Latest measured capture-to-result delay was 18.8 s including queue time on the saved key. Model latency varies: 1 FPS capture does not promise 1 FPS detections. Real room suitability and the native iPhone camera/AR integration still need testing by A+D.
