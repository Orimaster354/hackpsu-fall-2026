# Owner D backend handoff

Status: backend wire tests pass; `MyApp/Net` and `MyApp/Models` are not ready yet, so Swift Codable compilation/round-trips and physical iPhone connectivity are **not verified**. Do not mark D's Phase 0 checkboxes complete from backend tests.

## Transport and identity

Connect to `ws://<laptop-LAN-IP>:8080/ws`. All frames are JSON text with a top-level `t` discriminator. Model fields sit beside `t`, never inside a `data` or `state` wrapper. All enum values are case-sensitive. The client that sends `create` is the host; retain that local flag with the returned room/player ID for reconnect. Server permissions are authoritative.

```json
{"t":"create","name":"Host"}
{"t":"join","room":"ABCD","name":"Player"}
{"t":"joined","room":"ABCD","playerId":"<opaque ID>"}
{"t":"join","room":"ABCD","name":"Player","playerId":"<same opaque ID>"}
```

Reconnect preserves the player's ID and role. Send the same room/name/player ID. The server sends `joined`, current `setup` if available, `lobby`, and during/after play the player's private `role`, public `state`, and final `result` if ended. A replaced socket loses authority. Disconnected players remain registered and count toward the room's capacity.

## Setup and readiness

`lobby` has `players`, `grid: Grid?`, `stations`, `hasMap: Bool`, and `setupConfirmed: Bool`. `grid` is null until the server produces setup. `setup` has `grid: Grid`, `stations`, and `setupConfirmed: Bool`. The flag is necessary after reconnect: confirmed setup is locked.

Player has `id`, `name`, `tile: Tile?`, `alive: Bool`, `tileSource: "ar"|"manual"`, `ready: Bool`, and `connected: Bool`. Ready status remains supported as approved; it is advisory, not an extra start requirement. Disconnect clears ready. Reconnect requires readying again.

```json
{"t":"ready","ready":true}
{"t":"editStation","station":{"id":"dial","name":"Door dial","tile":{"x":0,"y":0},"task":"dial","kind":"task"}}
{"t":"editStation","station":{"id":"dial","delete":true}}
{"t":"confirmSetup"}
{"t":"start"}
```

Only the host edits/confirms, only in lobby. Edits broadcast `setup` and `lobby`. Confirmation broadcasts both with `setupConfirmed=true`; retrying confirmation is idempotent. Start requires four connected players and confirmed setup. The client cannot confirm by placing `setupConfirmed` on a `start` message.

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
