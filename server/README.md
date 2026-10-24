# ROOMSHIFT server — Phase 0 lobby skeleton

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

Game actions, tile updates, room scan upload, and Gemini suggestions are not implemented yet. The authoritative event and model contract is `../docs/architecture.md`.

## Local dashboard

With the server running, open `http://localhost:8080/dashboard` on the server laptop. The dashboard refreshes every second and displays room membership, ready/connection status, phases, grid details, open sockets, and uptime. Use **Launch 4 test players**, **Ready all**, and the disconnect/reconnect buttons to exercise the real WebSocket lobby without iPhones. Closing the page disconnects its test players; in-memory rooms remain visible until the server restarts.

`GET /api/dashboard` supplies an allowlisted monitor snapshot. Dashboard pages and data are restricted to loopback connections. They exclude hidden roles, full player IDs/reconnect credentials, and raw sockets. The activity list contains changes observed while the page is open. This developer view does not change the iPhone event protocol.
