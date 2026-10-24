# Architecture

## Overview
Four iPhones connect over WebSocket to one authoritative Node server on a laptop (phone hotspot, LAN IP). The host phone scans the room; the server stores the grid, stations and ARWorldMap; all other phones download them and relocalize.

```
iPhone (host) --scan--> grid + worldmap + photos --> Server --> Gemini
iPhone x3  <--- room, stations, worldmap ---  Server
All phones <--> WebSocket JSON (tiles, intents, state) <--> Server (game state machine)
```

## Modules and boundaries
| Module | Path | Responsibility | Depends on |
|---|---|---|---|
| AR | `MyApp/AR/` | RoomPlan scan, grid build, ARWorldMap save/load, relocalize, current tile, photo raycast | Models |
| Net | `MyApp/Net/` | WebSocket client, encode/decode messages, reconnect | Models |
| Models | `MyApp/Models/` | Codable types below | none |
| UI | `MyApp/UI/` | Lobby, role reveal, map, meeting, vote, end screens, manual tile picker | Net, Models |
| Tasks | `MyApp/Tasks/` | Core Motion task views, each returns success/fail | none |
| Server | `server/` | Rooms, state machine, validation, Gemini proxy | none |

## Positioning model
- Grid: `cols x rows` of 1.0 m tiles; origin at the scan bounds' min corner; axes follow the world map.
- Phone computes `tile = floor((pos - origin) / 1.0)` from ARKit and sends it at 2-4 Hz.
- Server accepts a tile change only after 2 consecutive identical reports (drift filter).
- Fallback: `tileSource = "manual"`, player taps a tile on the 2D map. Same message.
- Relocalization has a 20 s timeout, then the app offers manual mode.

## Shared models (Swift Codable / JSON)
```
Tile        { x: Int, y: Int }
Grid        { cols: Int, rows: Int, tileSize: Double (1.0), blocked: [Tile] }
Station     { id: String, name: String, tile: Tile, task: TaskType, kind: "task"|"fix" }
TaskType    "shake" | "tilt" | "dial" | "hold" | "gesture"
Role        "crew" | "impostor"
Phase       "lobby" | "playing" | "meeting" | "ended"
Player      { id, name, tile: Tile?, alive: Bool, tileSource: "ar"|"manual" }
GameState   { phase, players: [Player], tasksDone: Int, tasksTotal: Int,
              lightsOut: Bool, killCooldownEndsAt: Int?, meeting: MeetingState? }
MeetingState{ reason: "report"|"emergency", bodyOf: String?, endsAt: Int, votes: { [id]: id|"skip" } }
```
`tasksTotal` counts tasks for living crew only. Ghosts do not do tasks. Times are epoch ms.

## Protocol
JSON text frames, `{ "t": "<type>", ...fields }`. HTTP: `POST /map/:room` and `GET /map/:room` for the ARWorldMap binary (not over WebSocket).

### Client to server
| t | fields | notes |
|---|---|---|
| `create` | name | returns `room` code (4 letters), host |
| `join` | room, name | returns `playerId`; same playerId on reconnect |
| `setRoom` | grid, stations | host only; uploads scan result |
| `suggest` | photos (base64 jpeg), boxes metadata | host only; server calls Gemini, replies `suggestions` |
| `start` | | host only, needs 4 players |
| `tile` | tile, source | position report |
| `taskDone` | stationId | server checks player is on that tile and alive |
| `kill` | targetId | impostor swipe; server checks same tile, cooldown, alive |
| `report` | bodyId | reporter on body's tile |
| `emergency` | | must be on emergency tile, once per player |
| `vote` | target (id or "skip") | |
| `sabotage` | | impostor; starts lights out |
| `fix` | stationId | crew on fix tile |

### Server to client
| t | fields |
|---|---|
| `joined` | playerId, room |
| `lobby` | players, grid, stations, hasMap |
| `suggestions` | stations (with name, tile, task) |
| `role` | role (private) |
| `state` | full GameState (broadcast on every change) |
| `killed` | by hidden; sent only to victim |
| `meeting` | MeetingState |
| `result` | ejected: id\|null, role, winner |
| `error` | code, message |

## Rules enforced by the server
- Kill: impostor alive, victim alive and crew, same tile, cooldown 25 s from last kill (and from game start).
- Dead player: phone stays at the body tile; `alive=false`; cannot vote, kill or do tasks.
- Report: reporter alive and on same tile as the body. Emergency: once per player, 3 total.
- Meeting: 30 s vote; majority ejects; tie or skip majority ejects no one.
- Win: crew when `tasksDone >= tasksTotal` or impostor ejected; impostor when alive crew <= alive impostors.
- Lights out: `lightsOut=true`, crew tasks rejected until `fix` on the fix station; sabotage cooldown 45 s.
- Roles: random, 1 impostor for 4 players (count is a constant `IMPOSTORS`).

## Gemini flow
1. Host captures ARFrame JPEGs plus camera transform/intrinsics.
2. Server sends photos to Gemini Flash asking for JSON `[{label, box:[x,y,w,h]}]`.
3. App raycasts each box center against the scan (mesh or planes) to a world point, converts to a tile, and picks a task type per label. Host accepts or rejects each station.
There is no canned fallback: if Gemini fails, the host places stations by hand on the 2D map.

## Failure handling
- Disconnect: server keeps the player; reconnect with `playerId` restores state.
- Relocalization failure: manual tile picker.
- Server restarts lose state (accepted for the hackathon).
