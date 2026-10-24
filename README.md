# IRL Among Us (HackPSU Fall 2026)

An Among Us-inspired game played in a real room on four iPhones. Players walk to real task stations, do motion-based tasks, and try to find the impostor.

## MVP
- Host scans a room (RoomPlan/ARKit), builds a 1 m tile grid, and saves an ARWorldMap.
- Gemini Flash suggests task stations from photos; host accepts or rejects them.
- Four phones join with a 4-letter room code. No QR codes.
- 1 impostor, 3 crew. Roles are private.
- Crew do tasks at stations: shake/tilt balance, hold-steady, rotate dial, gesture pattern.
- Impostor swipes to kill a player on the SAME tile (25 s cooldown).
- A dead player leaves their phone on the spot as the body, and may wander. Ghosts do not do tasks.
- Report or emergency meeting, 30 s vote, ejection, win check.
- One sabotage: lights out, fixed by holding a fix station.
- Fallback: if relocalization fails, a player taps their tile on a 2D map.

## Stack
- iOS: Swift, SwiftUI, ARKit, RoomPlan, Core Motion.
- Server: Node.js, `ws`, in-memory state (no database).
- AI: Gemini Flash, called only from the server.

## Setup
1. iOS: open `Untitled Project 2.xcodeproj` on a Mac, set your signing team, run on a physical iPhone (LiDAR needed for scanning).
2. Server: `cd server && npm install && cp .env.example .env` (set `GEMINI_API_KEY`), then `npm start`. It listens on port 8080.
3. Network: join all phones to one phone hotspot, run the server on a laptop on it, and enter the laptop's LAN IP in the app's settings.

## Docs
- `docs/architecture.md`: modules, models, protocol.
- `docs/tasks.md`: ordered checklist with owners.
- `AGENTS.md`, `CLAUDE.md`: rules for coding agents.
