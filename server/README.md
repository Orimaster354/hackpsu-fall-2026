# ROOMSHIFT multiplayer server

Requires Node.js 22 or newer. On Windows PowerShell, use `npm.cmd` if `npm.ps1` is blocked by the execution policy.

```powershell
cd server
npm.cmd install
npm.cmd test
npm.cmd start
```

The server listens on port 8080 by default and binds to `0.0.0.0` for LAN testing. Copy `.env.example` to `.env` to set another `PORT`; the Gemini key is unused by this skeleton. `GET /health` returns `{"ok":true}`. WebSocket clients connect to `/ws`.

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
