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

## Wall Post-it detection and task reasoning

YOLOE-26 Small is the default detector. The detector targets yellow sticky notes using the text prompt `yellow sticky note`; canonical output stays `sticky note`. This prompt is not independent color verification. Only note observations are task candidates; doors, windows, whiteboards, switches, outlets, clocks, posters, extinguishers and vents are wall context. The worker samples 1 FPS at 960 px, accepts scores >=0.35 and returns up to eight note observations per pass. Small-note minimum area is 0.0001 of the frame, replacing the furniture filter. This is experimental open-vocabulary detection, not a trained/validated Post-it detector.

Record clear views of each wall note with its surrounding wall features. Multiple notes with the same label are retained. Short image-overlap tracks reduce repeated frames, but observation IDs are not physical identities: notes can repeat across passes. Neither wall attachment nor unique note identity is verified automatically.

Within each decoded frame, overlapping/nested note proposals are collapsed to the highest-scoring box before context is calculated (IoU >=0.45 or >=85% coverage of the smaller box). Nearby non-overlapping notes remain separate, and two same-timestamp detections cannot update the same track. Re-run analysis to replace previous duplicate results. Cross-gap or cross-video physical note identity is still unverified.

Nearby frames also use supported ORB/RANSAC scene alignment before matching image boxes, reducing repeated notes when the camera pans. At least eight inliers and a 40% inlier ratio are required; this is a heuristic, not physical identity tracking. The highest-score observation retains its original context. Cards show a close-up of each note and `observationCount`; multiple cards can share a timestamp because different notes are visible together. Clicking still shows the full frame. The downloaded seven-observation example replays as five candidates, with the distinct simultaneous notes preserved. Re-run the source video for fresh results; downloaded old JSON is not rewritten.

With **Ask Gemini to choose Post-it notes using nearby wall context** checked, only metadata goes to Gemini: IDs, labels, scores, timestamps, boxes and nearby same-frame wall detections. No video/frame images are sent by the local YOLOE path. Set `GEMINI_API_KEY` in ignored `.env`; optional `GEMINI_REASONING_MODEL` overrides `GEMINI_MODEL`. Restart after changes. Reasoning shortlists note scores >=0.55, preserving multiple notes. Weaker candidates remain available for manual review.

Context contains at most six elements from the note's exact decoded frame. `imageGap` is shortest 2D box gap divided by image diagonal, retained when <=0.2. It measures visual proximity, never meters or proof that objects share a wall. The dashboard shows note observation IDs, context cues/gaps, filtering counts and annotated frames. Context boxes use a different color. Missing context is explicitly unknown. The planner prefers notes near recognizable wall features, acknowledges overlap/duplicates and may return fewer suggestions or none. It cannot choose furniture/context objects as stations or invent missing notes.

Gemini returns at most three phone tasks and one fix using known note IDs. Physical tiles and 2 m spacing still require pose/grid geometry and host review. A reasoning failure retains detections; no furniture fallback is used. See the editable [prompt](prompts/station-planning.md). `GET /api/dashboard/video-test` reports `defaultDetector` and `reasoning:{configured,model}`. Multipart POST defaults to `detector=yoloe`; `reasoning=1` adds validated `planning`. Explicit `detector=gemini` compares cloud note detection with empty wall context; it is not a source of invented nearby features.

Verification: 58 Node tests and seven Python tests cover selection/validation and same-frame context. The real worker ran on the existing public room clip with no notes and returned zero note candidates. This verifies runtime plumbing and a negative example, not accuracy on actual Post-it footage. Real-note positive acceptance and physical placement remain pending.

## Two-video dashboard and optional Gemini comparison

Start the backend with `npm.cmd start` and open `http://localhost:8080/dashboard/videos` on the laptop. Select one overview MP4 or MOV, then click **Analyze video**. A second video is optional and can be removed with **Remove optional video**. Each clip is limited to 512 MiB / 120 seconds; MOV is sent as `video/quicktime`; MP4 uses `video/mp4`. A missing browser preview does not block analysis. The server reads duration from MP4/QuickTime movie atoms instead of requiring browser playback; files with missing/truncated duration metadata are rejected with an explanation. Use an H.264 export if preview is needed. When Gemini detection is explicitly selected, full videos are uploaded to the Gemini Files API and analyzed in separate generation requests at 2 FPS and high media resolution, with temperature 0 and at most six sticky-note observations per pass. This avoids asking the model to associate detections with multiple timelines; the server owns pass association. Each supplied video uses the configured model. Higher detail uses more tokens and may take longer. Result JSON records the analysis settings and per-pass token usage. These settings are tuning candidates, not evidence of improved label/box accuracy; compare against actual room frames before acceptance. The page shows progress, timestamped per-pass labels and normalized boxes; click a detection to seek its video and inspect the box. Download JSON saves validated results. This tests recorded-video note detection, not geometry or station placement.

The ignored `.env` supplies `GEMINI_API_KEY`. Optional `GEMINI_VIDEO_MODEL` overrides `GEMINI_MODEL` for this test only. The dashboard shows the selected model and whether a key is present, never the key. The model must support video and structured JSON; provider access/quota errors are displayed without automatic retry. Google API documentation: [video understanding](https://ai.google.dev/gemini-api/docs/generate-content/video-understanding), [file uploads](https://ai.google.dev/api/files).

Developer-only `GET /api/dashboard/video-test` exposes non-secret configuration; `POST` accepts required multipart `overview` and optional `edge` video files with `X-Roomshift-Video-Test: 1`, and streams NDJSON progress/result/error records. Loopback only, one run at a time, five-minute processing deadline; Cancel aborts active work. Input is bounded in memory and not saved locally. Provider files are deleted after each attempt when possible; cleanup failures are reported on successful results. Provider retention applies if cleanup fails. No gameplay rooms or shared iOS endpoints are changed. Actual two-video acceptance remains pending a successful run with the user's clips.

## Local YOLOE-26 Small setup

The dashboard uses `yoloe-26s-seg.pt` with sticky-note and wall-context text prompts. Decoded timestamps are preserved; frame-index/FPS fallback is explicitly reported. Short image tracks do not establish world identities, and scores are not calibrated correctness probabilities.

This detector needs Python for the supported Ultralytics inference runtime. It runs as one bounded subprocess per test; the multiplayer server remains Node/`ws`, without another HTTP service. Weights, text encoder and environment are ignored in Git. Tested on this laptop with Python 3.11.9, CPU Torch 2.14.1, torchvision 0.29.1, Ultralytics 8.4.188 and the pinned Ultralytics CLIP dependency.

From `server/` on Windows:

```powershell
py -3.11 -m venv .venv-yolo
.venv-yolo/Scripts/python.exe -m pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cpu
.venv-yolo/Scripts/python.exe -m pip install -r requirements-yoloe.txt
.venv-yolo/Scripts/python.exe tools/yoloe_worker.py --warmup
npm.cmd start
```

Warm-up downloads official weights and the MobileCLIP text encoder into `.cache/yoloe/`, then writes a ready marker after real inference. Installation/downloads need network access; normal YOLOE video inference stays on the laptop and needs no Gemini key. `YOLOE_PYTHON` overrides the isolated interpreter. Mac/Linux use `.venv-yolo/bin/python`. See upstream [YOLOE documentation](https://docs.ultralytics.com/models/yoloe/) and [license information](https://www.ultralytics.com/license).

Refresh `/dashboard/videos`, select a detector, and upload the same clips for comparison. YOLOE is selected by default. Temporary local copies are removed after success/failure/cancel, and a ten-minute timeout kills a stuck worker. Local detection invokes Gemini only when the separate metadata reasoning checkbox is enabled. YOLOE results add `confidence`, `frameIndex`, and an optional annotated `frameJpeg`; clicking a detection shows its exact decoded frame even when a MOV cannot preview in the browser. Download JSON records model/settings. The earlier furniture COCO smoke test is historical and does not validate the current note detector. Actual Post-it footage still needs positive acceptance.

`npm.cmd test` covers Node integration/validation/cancellation. `.venv-yolo/Scripts/python.exe tools/test_yoloe_worker.py` tests temporal grouping, multiple note retention, image-gap calculation and same-frame context association. Smoke media/results are in ignored `.cache/yoloe/`. No gameplay setup, geometry or iOS endpoints are changed.

## Legacy sampled-frame/image helpers

Existing `suggest` and `scan_start`/`scan_frame`/`scan_stop` helpers remain for detector diagnostics. They are not the updated iOS capture pipeline and cannot set room geometry. All new scan work follows the architecture's two recorded videos, timestamped poses and intrinsics, with geometry and station placement on the server.

Set `GEMINI_API_KEY` only in ignored `server/.env`; `GEMINI_MODEL` selects the model (current adapter default: `gemini-3.1-flash-lite`). Restart after changes. `npm.cmd run test:gemini -- C:\path\to\photo.jpg` exercises the one-photo detector. Automated tests mock provider responses and make no external Gemini calls.

`http://localhost:8080/dashboard/live` samples a selected local MP4 into independent JPEG requests at up to 1 FPS. It keeps the latest queued frame, drops older waiting frames and correlates results by frame ID/timestamp; it provides no temporal video reasoning. Optional `LIVE_SCAN_TEST_VIDEO` supplies a fixed laptop-only MP4 (up to 10 MiB). This diagnostic is not acceptance for two-video timestamped detection, polygon generation, station placement or iPhone integration. Never commit keys or test media.
