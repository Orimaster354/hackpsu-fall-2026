# ROOMSHIFT multiplayer server

Requires Node.js 22 or newer. On Windows PowerShell use `npm.cmd` if execution policy blocks `npm.ps1`.

```powershell
cd server
npm.cmd install
npm.cmd test
npm.cmd run start:manual
```

In a second terminal in `server/`:

```powershell
npm.cmd run smoke
npm.cmd run round
```

The server listens on `0.0.0.0:8080`. `PORT` overrides the port; `WS_URL` overrides the tools' default `ws://127.0.0.1:8080/ws`. Copy `.env.example` to the ignored `.env` for optional settings. Manual tests need no Gemini key. For phones on the same LAN/hotspot, use `ws://<laptop-LAN-IP>:8080/ws`; `ipconfig` shows the laptop address. Allow Node through Windows Firewall on that network if prompted.

## Setup modes

`npm.cmd start` creates rooms with `grid=null`, empty stations and `setupConfirmed=false`. They wait for server-produced setup. Phase 3's two-pass scan uploads and geometry processor are not implemented yet.

`npm.cmd run start:manual` explicitly seeds each new room from [manual-setup.json](fixtures/manual-setup.json): a 5x5 playable grid with nonzero AR origins, three edge tasks, a fix station and an emergency station. The host must confirm it before starting. This enables client integration while scan processing is pending.

`smoke` connects four clients and verifies shared lobby/readiness. `round` requires manual fixture mode (or another available server setup), confirms setup, readies four clients, sends manual tiles, receives private roles, completes a task, calls an emergency meeting, votes and verifies crew victory. Every run creates a new room. `node tools/fakeClient.js ABCD` joins an existing lobby with one persistent bot.

## Endpoints and messages

- `GET /health`: `{"ok":true}`.
- `/ws`: JSON text WebSocket messages.
- `POST /map/:room`: host-only opaque ARWorldMap binary, `Content-Type: application/octet-stream`, `X-Player-Id: <host joined ID>`. Lobby only, 1 byte to 20 MiB, HTTP 204 on success; broadcasts `hasMap=true`.
- `GET /map/:room`: room-scoped binary download, 404 before upload. Maps live in memory.
- `GET /dashboard` and `GET /api/dashboard`: laptop-only connection/ready/phase monitor. `/dashboard/live` is the legacy sampled-frame detector tester.

Client events: `create`, `join`, `ready`, `editStation`, `confirmSetup`, `start`, `tile`, `taskDone`, `kill`, `report`, `emergency`, `vote`, `sabotage`, `fix`.

Server events: `joined`, `lobby`, `setup`, private `role` and `killed`, public `state`, `meeting`, `result`, and recoverable `error`. Lobby includes the approved `hostId`; clients compare it with their player ID instead of inferring host from ordering. Follow [architecture.md](../docs/architecture.md) and [the client handoff](CLIENT_INTEGRATION.md) for exact JSON and nullable fields. Public players never contain roles. `state`/`meeting` fields sit beside `t`. See [error codes and replacement handling](ERROR_CODES.md) for recoverable actions and terminal replacement close code 4000.

Four-letter codes hold four players. Disconnect retains membership, sets `connected=false` and clears ready. Reconnect sends `join` with the same room, name and playerId, restoring setup and authoritative state plus only that player's role. Ready is advisory; start requires the host, four connected players and confirmed setup.

The revised grid uses `originX`, `originZ`, `playable` and `edge`. Client `setRoom` and old `blocked` grids are no longer accepted. Host task/fix edits must be on edge tiles at least 2 m apart by Euclidean center distance. The server-owned emergency station is immutable. Confirmation locks setup and persists across reconnect. Read the emergency location from its station rather than assuming (0,0).

Send tiles twice consecutively, including manual mode. Server checks playable tiles; meetings and dead players freeze movement. Roles, kills, votes, task counts and lights are server-authoritative. Kill cooldown is 25 seconds; sabotage cooldown is 45 seconds. Tasks count once per station per living crew member. Lights-out blocks tasks until a valid fix. Meetings last 30 seconds or until all living players vote; ejection requires more than half the living players. Timestamps are epoch milliseconds.

## Verification and client handoff

`npm.cmd test` runs unit and local WebSocket integration tests, including four simultaneous players, connection/reconnect, setup edits/locking, role privacy, kill/report/vote and sabotage/fix/task synchronization. The latter scenarios use an injected server clock to avoid waiting for cooldowns; clients cannot set time.

[CLIENT_INTEGRATION.md](CLIENT_INTEGRATION.md) links example lobby, setup and state JSON for Owner D. Main now supplies `MyApp/Net` and `MyApp/Models`; nullable lobby grid and setup-confirmation alignment remain pending on the client. Swift Codable compilation and physical iPhone connectivity are not verified here. Backend tests do not satisfy phone acceptance.

Open `http://localhost:8080/dashboard` for connection status, room membership, readiness and phases. Its four-player controls use real WebSockets; closing the page disconnects its bots. The monitor excludes hidden roles, full player IDs and raw sockets. Rooms remain until server restart.

The dashboard shows available LAN WebSocket addresses, open sockets separately from joined players, and online counts in each room tab. New active rooms open automatically. All joined clients appear, including phones and bots; device type is not inferred. Updates arrive every second. An open socket needs a successful `create` or `join` before it appears as a player.

To check phone reachability, open `http://<laptop-LAN-IP>:8080/health` in Safari on the same Wi-Fi/hotspot; expect `{"ok":true}`. Then use `ws://<laptop-LAN-IP>:8080/ws` in the iOS networking client and create/join a room. Safari's health check alone does not join a player. If campus Wi-Fi blocks peer connections, use a shared phone hotspot and recheck the laptop's IP. The local dashboard stays on the laptop. App networking/models must be implemented by Owner D before the app's lobby can join.

## Internal producer/rule interface

The router resolves socket membership and calls `room.game.handle(player, message)`. `Game.state()` returns public state, `Game.publish()` broadcasts it, and `room.sendTo(player, event)` delivers privately. The future scan processor calls internal `room.game.applySetup({grid,stations})`; validation clones the supplied data and rejects replacement after confirmation. This is not a client event. Test-only clock/random/timer injection is available through `createAppServer(options)`.

## Two-video Gemini test dashboard

Start the backend with `npm.cmd start` and open `http://localhost:8080/dashboard/videos` on the laptop. Select the overview and edge-walk MP4 files, then click **Analyze both videos**. Each clip is limited to 512 MiB / 120 seconds; use H.264 MP4 if the browser cannot play a file. Full videos are uploaded to the Gemini Files API and supplied together in one generation request at 1 FPS sampling. The page shows progress, timestamped per-pass labels and normalized boxes; click a detection to seek its video and inspect the box. Download JSON saves validated results. This tests recorded-video detection, not geometry or station placement.

The ignored `.env` supplies `GEMINI_API_KEY`. Optional `GEMINI_VIDEO_MODEL` overrides `GEMINI_MODEL` for this test only. The dashboard shows the selected model and whether a key is present, never the key. The model must support video and structured JSON; provider access/quota errors are displayed without automatic retry. Google API documentation: [video understanding](https://ai.google.dev/gemini-api/docs/generate-content/video-understanding), [file uploads](https://ai.google.dev/api/files).

Developer-only `GET /api/dashboard/video-test` exposes non-secret configuration; `POST` accepts multipart `overview`, `edge`, `overviewDuration`, `edgeDuration` with `X-Roomshift-Video-Test: 1`, and streams NDJSON progress/result/error records. Loopback only, one run at a time, five-minute processing deadline; Cancel aborts active work. Input is bounded in memory and not saved locally. Provider files are deleted after each attempt when possible; cleanup failures are reported on successful results. Provider retention applies if cleanup fails. No gameplay rooms or shared iOS endpoints are changed. Actual two-video acceptance remains pending a successful run with the user's clips.

## Legacy sampled-frame/image helpers

Existing `suggest` and `scan_start`/`scan_frame`/`scan_stop` helpers remain for detector diagnostics. They are not the updated iOS capture pipeline and cannot set room geometry. All new scan work follows the architecture's two recorded videos, timestamped poses and intrinsics, with geometry and station placement on the server.

Set `GEMINI_API_KEY` only in ignored `server/.env`; `GEMINI_MODEL` selects the model (current adapter default: `gemini-3.1-flash-lite`). Restart after changes. `npm.cmd run test:gemini -- C:\path\to\photo.jpg` exercises the one-photo detector. Automated tests mock provider responses and make no external Gemini calls.

`http://localhost:8080/dashboard/live` samples a selected local MP4 into independent JPEG requests at up to 1 FPS. It keeps the latest queued frame, drops older waiting frames and correlates results by frame ID/timestamp; it provides no temporal video reasoning. Optional `LIVE_SCAN_TEST_VIDEO` supplies a fixed laptop-only MP4 (up to 10 MiB). This diagnostic is not acceptance for two-video timestamped detection, polygon generation, station placement or iPhone integration. Never commit keys or test media.
