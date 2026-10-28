# Backend errors and reconnect handling

WebSocket errors are JSON text: `{"t":"error","code":"HOST_ONLY","message":"Only the host can do this."}`. Match `code`, not human-readable message text. Validation errors normally keep the socket open; correct the action instead of reconnecting automatically. Unexpected failures use `SERVER_ERROR` without internal details.

| Codes | Client response |
|---|---|
| `INVALID_JSON`, `INVALID_MESSAGE`, `UNKNOWN_EVENT`, `MESSAGE_TOO_LARGE` | Fix encoding/event type/payload size. Send text JSON with top-level `t`; no JSON ping. |
| `INVALID_NAME`, `INVALID_ROOM` | Ask for a trimmed 1–24 character name and four uppercase room letters. |
| `ROOM_NOT_FOUND`, `PLAYER_NOT_FOUND` | Discard stale room/player reconnect identity and offer a fresh create/join. Reconnect requires the original room, name and playerId. |
| `ROOM_FULL`, `GAME_STARTED` | Explain that the room cannot accept a new player. Disconnect does not release a seat. |
| `NOT_JOINED`, `ALREADY_JOINED` | Create/join before actions; do not create/join twice on an already joined socket. |
| `CONNECTION_REPLACED` | Stop this displaced client. Do not automatically fight the replacement by reconnecting. |
| `HOST_ONLY`, `CREW_ONLY`, `IMPOSTOR_ONLY`, `PLAYER_DEAD`, `INVALID_PHASE` | Update controls from authoritative role/life/phase/host state. Never override server decisions locally. |
| `INVALID_READY` | Send a Boolean `ready` in lobby. |
| `SETUP_MISSING`, `SETUP_NOT_CONFIRMED`, `SETUP_LOCKED`, `NEED_FOUR_PLAYERS` | Wait for server setup, host confirmation and 4 to 10 connected players (the code keeps its old name). Confirmed setup cannot be edited. |
| `INVALID_GRID`, `INVALID_STATIONS`, `INVALID_EMERGENCY`, `INVALID_STATION` | Correct setup/station data or move to the valid action station. Grid generation is server-owned. |
| `STATION_NOT_EDGE`, `STATIONS_TOO_CLOSE`, `STATION_OVERLAP`, `EMERGENCY_LOCKED` | Keep task/fix edits on edge tiles, 2 m apart and off the immutable emergency tile. |
| `INVALID_TILE` | Send an integer playable tile and source `ar`/`manual`. Two consecutive matching reports are required. |
| `INVALID_TARGET`, `KILL_COOLDOWN`, `INVALID_BODY` | Wait/move/select an eligible target or reportable body. |
| `EMERGENCY_TILE`, `EMERGENCY_USED` | Move to the configured emergency station; respect per-player/room meeting limits. |
| `INVALID_VOTE`, `ALREADY_VOTED` | Vote once for a living player ID or `skip` during a meeting. |
| `TASK_ALREADY_DONE`, `LIGHTS_OUT` | Do not repeat a completed task; fix lights before more tasks. |
| `LIGHTS_ALREADY_OUT`, `SABOTAGE_COOLDOWN`, `INVALID_FIX` | Respect lights/cooldown state; living crew fixes only at the active sabotage's fix station. |
| `INVALID_SABOTAGE`, `SABOTAGE_ACTIVE`, `NO_FIX_STATION` | The kind must be `lights`, `jammer` or `meltdown`; only one sabotage runs at a time; the jammer and the meltdown need a fix station. |
| `SABOTAGE_BLOCKS_MEETING` | `report` and `emergency` are refused while the jammer or a meltdown is active. Repair it first. |
| `NO_ABILITY`, `ABILITY_USED`, `ABILITY_COOLDOWN` | Only the Medic and the Scout have a power: the Medic revives once, the Scout pings twice with a gap. A refused revive with `INVALID_BODY` leaves the Medic their one use. |
| `INVALID_ZONE`, `TOO_MANY_ZONES`, `ZONES_TOO_LARGE` | Rooms are `z1` to `z6`; at most 6 rooms; the rooms together must fit a 100 by 100 tile layout. |
| `INVALID_DOORS`, `ZONES_NOT_CONNECTED` | A door joins one edge tile in each of two different rooms; every room must be reachable from the first through doors before `confirmSetup`. |
| `TOO_MANY_TASKS` | At most 5 task stations in the whole game, across all rooms. |

## WebSocket closure is separate from JSON errors

Close code **4000**, reason **Reconnected elsewhere**, means a newer successful connection took over the same identity. The old client must stop retrying and wait for an explicit user Connect action. Normal network failures may retry with the same room/name/playerId. Only callbacks belonging to the current socket generation may change its state. The server does not expire/reassign the host when the host disconnects.

Ping/pong are protocol control frames handled by `ws`. A successful pong proves an open socket, not room membership; wait for `joined` and `lobby` after create/join. OS-specific transport errors such as URLSession cancellation are not server JSON error codes.

## HTTP map uploads

Map routes use HTTP status plus `{t:"error",code,message}`. Errors include `ROOM_NOT_FOUND`, `MAP_NOT_FOUND`, `HOST_ONLY`, `INVALID_PHASE`, `METHOD_NOT_ALLOWED`, `INVALID_CONTENT_TYPE`, `MAP_TOO_LARGE`, `EMPTY_MAP`, `UPLOAD_ABORTED` and generic `MAP_ERROR`. `POST /map/:room` requires `X-Player-Id`, raw octet-stream bytes and a lobby-phase host; successful uploads return 204. GET before upload returns 404.

## Gemini and developer diagnostics

Gemini/image errors: `GEMINI_NOT_CONFIGURED`, `GEMINI_UNAVAILABLE`, `GEMINI_TIMEOUT`, `GEMINI_INVALID_RESPONSE`, `INVALID_PHOTO`, `INVALID_METADATA`, `SUGGEST_BUSY`. Legacy scan helpers also use `SCAN_ACTIVE`, `SCAN_NOT_READY`, `INVALID_SCAN_FRAME`, `SCAN_RATE_LIMIT`, `SCAN_DETECTION_ERROR`, `SCAN_RESPONSE_TIMEOUT`, `SCAN_STOPPED`. Check limits/configuration, surface the error and allow an intentional retry. Do not invent detections or stations.

The video dashboard streams NDJSON records with `type:"error"` and `code`/`message`, rather than gameplay WebSocket frames. Additional codes include `LOCAL_ONLY`, `INVALID_REQUEST`, `INVALID_VIDEO`, `VIDEO_TOO_LARGE`, `VIDEO_TEST_BUSY`, `UPLOAD_ABORTED`, `GEMINI_QUOTA`, `GEMINI_VIDEO_FAILED`, `VIDEO_TEST_CANCELLED` and `VIDEO_TEST_FAILED`. The backend attempts provider file cleanup after success/failure/cancel. Retry manually after fixing the cause; do not continuously retry quota errors.

Sticky-note scan routes (`POST /scan/:room/perimeter`, `POST /scan/:room/sweep`, specified in `docs/architecture.md`) are implemented. Their codes: `SCAN_UPLOAD_INVALID` (400, bad JSON, pose, intrinsics or frame count), `SCAN_UPLOAD_TOO_LARGE` (413), `SCAN_FAILED` (422, open loop, under 4 m^2 or unusable path), `SETUP_MISSING` (409, sweep before perimeter), `SETUP_LOCKED` (409, after `confirmSetup`), plus the usual `HOST_ONLY` and `INVALID_PHASE`. A sweep with no notes found is a 200 with `notesFound:0`, not an error. `SCAN_BUSY` (409) rejects concurrent room scan uploads and setup editing/confirmation/start while processing. Detector/runtime failures use `SCAN_FAILED` (422); Gemini failures instead return a warning with score-based station selection.

Local YOLOE diagnostic errors: `INVALID_DETECTOR` (select Gemini or YOLOE), `YOLOE_NOT_READY` (install/warm up runtime), `YOLOE_INVALID_RESPONSE` (invalid worker result), `YOLOE_FAILED` (worker/decode/inference failure), `YOLOE_CANCELLED` (user stopped it), and `YOLOE_TIMEOUT` (ten-minute worker limit). These are developer NDJSON errors, not new gameplay events. Local mode needs no Gemini key and sends no video to Google.
