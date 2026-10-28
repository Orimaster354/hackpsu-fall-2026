# Owner D backend handoff

Latest branch-specific scan audit: [ARKIT_HANDOFF.md](ARKIT_HANDOFF.md). `feature/arkit` at `f7f49a7` implements capture/upload and fixes several older client gaps described below. The local backend implements both scan endpoints; source inspection and 76 backend tests pass, but device acceptance remains pending. The older main-checkout findings below are historical, not proof those gaps remain on the ARKit branch.

Status after the Owner C integration fixes: `MyApp/Net`, `MyApp/Models` and B's `MyApp/UI` are present and preserved unchanged. All 45 backend tests pass. Swift Codable compilation/round-trips and physical iPhone connectivity are **not verified here**. Do not mark D's Phase 0 checkboxes complete from backend tests.

Current client gaps for D: `LobbySnapshot.grid` in `MyApp/Models/Messages.swift` is required (`Grid`) but new rooms send null; make it optional and update consumers. Lobby also needs the approved `hostId` field; both lobby and setup need `setupConfirmed`, which the current models omit. Remove obsolete `setRoom` use. The debug screen can send start but has no confirm-setup control; add a host confirmation action before starting. `NetDebugView` is no longer the root screen in main, so D must explicitly run it locally for this integration check. The separate Connect/Disconnect rows from main are preserved. No iOS files were changed by the backend integration fixes.

Main now mounts B's `RootView()`, whose default initializer creates a mock session. D must supply an actual `GameSession` adapter backed by a retained `GameClient` and map `ClientIntent` / `ServerEvent` to the wire events. The full UI already has host setup confirmation, but it currently trusts local state; map server `setupConfirmed` back into it. Carry wire `ready`/`connected` into lobby UI state and use the same manual-tile path. The mock UI is useful for visual work but does not prove any connection to the laptop. No Swift files were edited during this merge.

## Transport and identity

Connect to `ws://<laptop-LAN-IP>:8080/ws`. All frames are JSON text with a top-level `t` discriminator. Model fields sit beside `t`, never inside a `data` or `state` wrapper. All enum values are case-sensitive. Compare `lobby.hostId` with your joined player ID for host controls. Server permissions are authoritative; disconnect does not transfer host ownership.

```json
{"t":"create","name":"Host"}
{"t":"join","room":"ABCD","name":"Player"}
{"t":"joined","room":"ABCD","playerId":"<opaque ID>"}
{"t":"join","room":"ABCD","name":"Player","playerId":"<same opaque ID>"}
```

Reconnect preserves the player's ID and role. Send the same room/name/player ID. The server sends `joined`, current `setup` if available, `lobby`, and during/after play the player's private `role`, public `state`, and final `result` if ended. A replaced socket loses authority. Disconnected players remain registered and count toward the room's capacity.

The displaced socket closes with code `4000`, reason `Reconnected elsewhere`. D must treat this as terminal for automatic retries, requiring an explicit Connect action to take over again. Retrying it automatically can cause two clients sharing an identity to replace each other indefinitely. Normal network drops still reconnect. Backend tests verify replacement ownership, protection against stale close callbacks, rejected reconnects, and standard ping/pong; they do not implement the Swift retry fix. See [error handling reference](ERROR_CODES.md).

## Setup and readiness

`lobby` has `hostId: String`, `players`, `grid: Grid?`, `stations`, `hasMap: Bool`, and `setupConfirmed: Bool`. `grid` is null until the server produces setup. `setup` has `grid: Grid`, `stations`, and `setupConfirmed: Bool`. The flag is necessary after reconnect: confirmed setup is locked.

Player has `id`, `name`, `tile: Tile?`, `alive: Bool`, `tileSource: "ar"|"manual"`, `ready: Bool`, and `connected: Bool`. Ready status remains supported as approved; it is advisory, not an extra start requirement. Disconnect clears ready. Reconnect requires readying again.

```json
{"t":"ready","ready":true}
{"t":"editStation","station":{"id":"dial","name":"Door dial","tile":{"x":0,"y":0},"task":"dial","kind":"task"}}
{"t":"editStation","station":{"id":"dial","delete":true}}
{"t":"confirmSetup"}
{"t":"start"}
```

Only the host edits/confirms, only in lobby. Edits broadcast `setup` and `lobby`. Confirmation broadcasts both with `setupConfirmed=true`; retrying confirmation is idempotent. Start requires 4 to 10 connected players and confirmed setup. The client cannot confirm by placing `setupConfirmed` on a `start` message.

Grid fields are `cols`, `rows`, `tileSize: 1.0`, `originX`, `originZ`, `playable: [Tile]`, and `edge: [Tile]`. A tile inside rectangular bounds can still be non-playable. Old `blocked` grids and the old client `setRoom` event are no longer accepted. Room geometry comes from the server. Phase 3 scan generation/upload routes remain pending; use the developer fixture to integrate the manual game now.

Task/fix stations must be on edge tiles and at least 2 m apart measured between centers using Euclidean distance. The single emergency station is server-controlled, playable, and immutable to host edits. Its required `task` field uses `hold` as an ignored placeholder; branch on `kind` and do not launch a task for `emergency` or treat it as task progress. Emergency location must be read from the station; do not assume (0,0).

## Game events

`state` contains `phase`, public `players`, `tasksDone`, `tasksTotal`, `lightsOut`, `killCooldownEndsAt: Int64?`, and `meeting: MeetingState?`. `meeting` event fields are `reason`, `bodyOf`, `endsAt`, `votes`; the same object is nested in GameState. Dead players cannot move, vote, kill, report, do tasks or fix lights. `role` is private to its recipient; role never appears in public Player. `killed` contains no killer identity.

```json
{"t":"role","role":"crew"}
{"t":"meeting","reason":"report","bodyOf":"<player ID>","endsAt":1700000030000,"votes":{}}
{"t":"result","ejected":null,"role":null,"winner":null}
{"t":"error","code":"SETUP_NOT_CONFIRMED","message":"The host must confirm setup before starting."}
```

Epoch timestamps are milliseconds (use Int64); pose-log `t` values in the two-pass pipeline are seconds relative to video start. Result `role` and `winner` can be null. Vote targets are a player ID or `skip`. Send tile changes twice consecutively, including manual mode; meetings reset pending tile reports. Use existing intent names in `docs/architecture.md`.

## Fixtures and integration checklist

- [Empty lobby](fixtures/lobby-empty.json): nullable grid/tile before setup.
- [Draft manual setup](fixtures/manual-setup.json): revised grid, three edge tasks, fix station and centered emergency station with nonzero AR origins.
- [Playing state](fixtures/state-playing.json): four public players, no secret roles, nullable meeting, millisecond cooldown.

Run `npm.cmd run start:manual` in `server/` to seed each new room with the draft fixture. In a second terminal run `npm.cmd run round` to connect four bots and confirm/play it. `npm.cmd start` does not load a fabricated setup; those rooms wait for Phase 3's server scan processor. No model/API key is needed for manual mode.

D should compile the Codable models against these fixtures, including nulls and Int64 values; connect from a simulator/phone; create/join/reconnect; edit/confirm setup; and complete a manual-tile round with B. The server tests verify kill/report/vote and sabotage/fix/task synchronization over four real WebSocket connections. They do not replace those iOS checks.

Pending shared contracts for later phases: per-player completed-station IDs for dimmed AR icons are not present in GameState; agree with A/B/D before adding fields. Pose-log fixtures and the generated polygon/centroid acceptance criteria belong to Phase 3 and are not supplied by this manual setup fixture.

## Roles, sabotages and rooms (added with the 10-player update)

- `role` now also carries `power` (`"medic"`, `"scout"` or `null`) and `partners` (other impostors' player ids, impostors only). `scout` and `revived` are private messages.
- `sabotage` takes `{kind: "lights"|"jammer"|"meltdown"}`; with no kind it still means lights. `state.sabotage` is `{kind, fixStationId, endsAt, holders}` or `null`, and `lightsOut` stays true during the lights sabotage. `ability` takes an optional `targetId`.
- `lobby` and `setup` carry `zones` (empty when nothing was scanned). Scan and map HTTP routes accept an optional `zone` (`?zone=z2` on `/map/:room`); `setDoors` and `removeZone` are host-only lobby messages. Details and the shared-tile rule are in `docs/architecture.md`, "Multiple rooms (zones)".
- Swift decoders treat missing `power`, `partners`, `zones` and `sabotage` as empty, so a one-room game from an older server still decodes.
