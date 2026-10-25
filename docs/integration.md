# Integration notes (Owners B, C and D)

Current audit: 2026-10-25. `docs/architecture.md` is the wire contract. This replaces the old Phase 0 conflict list: do not rebuild the retired client-owned `setRoom` pipeline.

## Owner C: decisions and verified behavior

| Integration item | Current status |
|---|---|
| Scan design | Decided: two recorded videos with poses/intrinsics; server owns geometry and placement. The image/live-frame tools are diagnostics. |
| Grid | Implemented validation: origins, playable/edge tiles, 1 m tiles. New rooms have `grid=null` until setup exists. |
| Station edits | Implemented: `{t:"editStation",station:{...}}`; deletion accepts `{t:"editStation",station:{id,delete:true}}` or top-level `{t:"editStation",id,delete:true}`. Host/lobby only, atomic, edge-only task/fix placement with 2 m Euclidean spacing. |
| Setup confirmation | Implemented: `confirmSetup` locks setup. Server broadcasts `setupConfirmed` on both lobby and setup; reconnect restores the flag. Start needs confirmation and four connected players. |
| Emergency station | Implemented schema and gameplay lookup: exactly one server-owned, immutable, playable emergency station. Its `task:"hold"` is ignored; it is not task progress. Actual centroid calculation is Phase 3 work. |
| Host identity | Approved and implemented: `lobby.hostId` is the creator's player ID. Stable on disconnect/reconnect; no host transfer. Use it instead of guessing from player order. |
| Ready / connected | Implemented server-owned player fields and `ready` event. Disconnect clears readiness; ready remains advisory rather than an extra start requirement. |
| Roles | Private `role` event; no role in public Player. Reconnect during play restores only the reconnecting player's role. |
| Keepalive | Standard WebSocket ping/pong; `ws` answers automatically, including before join. There is no JSON `ping` event. |
| Replacement connections | Newest successful reconnect owns the player. Old socket closes with code 4000, `Reconnected elsewhere`. Stale close callbacks cannot detach the replacement; rejected reconnects cannot evict the active connection. |
| Errors | See [backend error reference](../server/ERROR_CODES.md). Game protocol errors normally leave the connection open. |

The synthetic setup fixture in `docs/fixtures/setup.json` passes backend validation. `server/fixtures/` supplies current empty-lobby, manual-setup and public-state examples. Default startup invents no geometry; use `npm run start:manual` for app integration before scan processing exists.

## Active fixes for Owner D

These are client issues, not missing backend intents. They are not fixed by the backend test suite.

- Make `LobbySnapshot.grid` optional. A normal new room sends null; the current required `Grid` fails to decode that lobby.
- Decode `hostId` and `setupConfirmed` on lobby; retain `setupConfirmed` on setup and map it to UI state. Treat confirmation as acknowledged only after the server response. A reconnect must restore the lock.
- Wire one retained `GameClient` into B's `GameSession.send` / `receive`, then supply that session to `RootView`. The app's default `RootView()` creates a mock session, so visual success does not demonstrate laptop connectivity.
- Map wire ready/connected into lobby state and expose `ready`. Use `hostId` for host controls and `connected` when counting who can start.
- Remove obsolete `setRoom` use. Do not compute grid geometry or task placement on the phone.
- Stop automatic reconnect when this socket was replaced with code 4000. In the current client, receive errors trigger generic reconnect without distinguishing replacement; this can make two clients sharing one player ID repeatedly displace each other. Log socket ID/generation, close code and error domain/code. An explicit user Connect may take over again; ordinary network errors still retry.
- Ensure events/errors from an old socket generation cannot tear down a newer connection. Avoid repeated Connect calls cancelling the current connection. Main already separates the Form buttons to avoid firing Connect and Disconnect from the same row.
- For NetDebugView testing, temporarily mount it locally and add a host confirm-setup control before Start. B's full setup-review UI already has a confirmation action; it needs the real server acknowledgement wired back in.

Backend replacement tests prove ownership and close behavior, not the Swift retry fix. Do not claim that a server-only change eliminates a retry loop in an unchanged client.

## B/D adapter checklist

| UI intent/event | Wire mapping |
|---|---|
| Create / join | `create {name}`, `join {room,name,playerId?}`; remember the original name for reconnect |
| Joined | `joined {playerId,room}` |
| Lobby | Map `players`, nullable `grid`, `stations`, `hasMap`, `hostId`, `setupConfirmed` |
| Edit / delete / confirm | `editStation`, `confirmSetup`; wait for authoritative setup/lobby |
| Start | `start`; host + four connected players + confirmed setup |
| Position | `tile {tile,source}`; preserve the server's two-consecutive-report filter, including manual mode |
| Role | Private `role {role}`; wire enum is `crew` or `impostor` |
| State | Flat GameState beside `t`, not a nested `state` wrapper; nullable nested meeting |
| Meeting / vote | Flat `meeting`; vote target is a player ID or `skip` |
| Result / error | Nullable result fields; map `{code,message}` errors without automatically closing the socket |

Use epoch milliseconds for cooldown/meeting times. B's UI types have distinct names from wire models, so explicit conversions are needed. Per-player task history/emergency usage, clock synchronization and end-game impostor reveals are still open contract proposals in `docs/tasks.md`; do not invent fields while implementing the adapter. There is no leave intent: disconnect retains the seat for reconnect.

## Remaining Owner C implementation

1. Gameplay scan upload endpoints for overview/edge and in-memory pose/intrinsics storage; host authentication and limits must be documented with the implementation.
2. Polygon/grid generation, 0.75 m horizontal loop-closure check, minimum 4 m² area, and centroid emergency tile, tested against the shared synthetic fixture and then a recorded walk.
3. Connect the full-video detector to timestamped pose association, boundary ray intersections and edge station placement. The laptop-only two-video dashboard already sends full videos, but does not generate a gameplay setup.
4. Live room-video acceptance: useful labels, boxes and timestamps from both actual clips. Mocked provider tests are not that acceptance.

## Mac/device verification

Run from the repository root on the Mac:

```sh
swiftc MyApp/Models/*.swift Tests/ModelsRoundTrip/main.swift -o /tmp/models-roundtrip
/tmp/models-roundtrip
```

Extend those round-trips with the current `server/fixtures/` messages, especially null grid and host/confirmation fields. Build in Xcode on the Mac; the backend Windows audit does not compile Swift.

Start `npm run start:manual` on the laptop. Confirm Safari can reach `http://<laptop-IP>:8080/health`, then point the app at `ws://<laptop-IP>:8080/ws`. Connect/create with one phone, join three, verify identical lobby/ready status, confirm setup, start, receive private roles and complete a manual-tile round. Test a network drop/reconnect and a deliberate identity replacement; a replaced old client must stay stopped. Check the dashboard for actual joined players.

Demo acceptance stays open until the four-device run and the under-three-minute scan/task/kill/report/vote script are rehearsed three times without restart. Device reachability cannot be inferred from a simulator running on a different machine.
