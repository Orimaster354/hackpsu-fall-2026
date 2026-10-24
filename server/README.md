# ROOMSHIFT server — Phase 0 lobby skeleton

Requires Node.js 22 or newer. On Windows PowerShell, use `npm.cmd` if `npm.ps1` is blocked by the execution policy.

```powershell
cd server
npm.cmd install
npm.cmd test
npm.cmd start
```

The server listens on port 8080 by default and binds to `0.0.0.0` for LAN testing. Copy `.env.example` to `.env` to set another `PORT`; the Gemini key is unused by this skeleton. `GET /health` returns `{"ok":true}`. WebSocket clients connect to `/ws`.

In another terminal, run `npm.cmd run smoke`. This opens four fake clients, creates one room, joins the other three, and checks that each receives a four-player lobby.

## Implemented messages

- Client: `{"t":"create","name":"Host"}`
- Client: `{"t":"join","room":"ABCD","name":"Player"}`
- Reconnect: send `join` with the same `room`, `name`, and previously received `playerId`.
- Server: `{"t":"joined","playerId":"...","room":"ABCD"}`
- Server: `{"t":"lobby","players":[...],"grid":{...},"stations":[],"hasMap":false}`
- Server error: `{"t":"error","code":"...","message":"..."}`

Room codes are four uppercase letters. A room holds four players; disconnected players remain in the room for reconnect. The initial grid is 5×5 with 1 m tiles. No roles or private game data are sent in lobby messages.

Game actions, tile updates, room scan upload, and Gemini suggestions are not implemented yet. The authoritative event and model contract is `../docs/architecture.md`.
