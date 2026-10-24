# IRL Among Us (HackPSU Fall 2026)

An Among Us-inspired game played in a real room on four iPhones. Players walk to real task stations, do motion-based tasks, and try to find the impostor.

## MVP
- Host records two videos with a pose log (an overview, then a walk along the walls) and saves an ARWorldMap. The app does no geometry.
- The server builds the room polygon and a 1 m tile grid, and Gemini Flash finds objects in the videos. Task stations go on edge tiles only, plus an emergency tile near the center. Host reviews and can edit.
- Players see world-anchored AR icons: a question mark on task tiles and an EMERGENCY text icon on the meeting tile.
- Four phones join with a 4-letter room code. No QR codes.
- 1 impostor, 3 crew. Roles are private.
- Crew do tasks at stations: shake/tilt balance, hold-steady, rotate dial, gesture pattern.
- Impostor swipes to kill a player on the SAME tile (25 s cooldown).
- A dead player leaves their phone on the spot as the body, and may wander. Ghosts do not do tasks.
- Report or emergency meeting, 30 s vote, ejection, win check.
- One sabotage: lights out, fixed by holding a fix station.
- Fallback: if relocalization fails, a player taps their tile on a 2D map.

## Stack
- iOS: Swift, SwiftUI, ARKit (video, pose log, ARWorldMap, AR icons), Core Motion.
- Server: Node.js, `ws`, in-memory state (no database).
- AI: Gemini Flash, called only from the server.

## Setup
1. iOS: open `Untitled Project 2.xcodeproj` on a Mac, set your signing team, run on a physical iPhone.
2. Server: `cd server && npm install && cp .env.example .env` (set `GEMINI_API_KEY`), then `npm start`. It listens on port 8080.
3. Network: join all phones to one phone hotspot, run the server on a laptop on it, and enter the laptop's LAN IP in the app's settings.

## Docs
- `docs/architecture.md`: modules, models, protocol.
- `docs/tasks.md`: ordered checklist with owners.
- `AGENTS.md`, `CLAUDE.md`: rules for coding agents.
