# Blindspot (HackPSU Fall 2026)

Blindspot is a social-deduction game, inspired by Among Us, played in a real room on four iPhones. Players walk to real task stations, do motion-based tasks, and try to find the impostor.

## MVP
- Host records a perimeter pose walk, then a sweep of JPEG frames with matching poses/intrinsics, and saves an ARWorldMap. The app does no geometry.
- The scan processor builds the room polygon and a 1 m tile grid from a perimeter pose walk. YOLOE detects wall Post-it notes and contextual wall features; Gemini chooses note observations as task candidates using nearby visual cues. Server geometry places stations on edge tiles and an emergency tile near the center; host reviews and edits. Perimeter/sweep endpoints and synthetic geometry acceptance are implemented; real ARKit sweep acceptance remains pending.
- Players see world-anchored AR icons: a question mark on task tiles and an EMERGENCY text icon on the meeting tile.
- Four phones join with a 4-letter room code. No QR codes.
- 1 impostor, 3 crew. Roles are private.
- Crew do tasks at stations: shake, hold-steady, rotate dial, gesture pattern, hammer.
- Impostor swipes to kill a player on the SAME tile (25 s cooldown).
- A dead player leaves their phone on the spot as the body, and may wander. Ghosts do not do tasks.
- Report or emergency meeting, 30 s vote, ejection, win check.
- One sabotage: lights out, fixed by holding a fix station.
- Fallback: if relocalization fails, a player taps their tile on a 2D map.

## Stack
- iOS: Swift, SwiftUI, ARKit (video, pose log, ARWorldMap, AR icons), Core Motion.
- Server: Node.js, `ws`, in-memory state (no database).
- AI: local YOLOE-26 Large detection (configurable checkpoint); Gemini task reasoning called only from the server. See `server/README.md` for detector setup and the live app-scan dashboard.

## Setup
1. iOS: open `Untitled Project 2.xcodeproj` on a Mac, set your signing team, run on a physical iPhone.
2. Server: `cd server && npm install && cp .env.example .env` (set `GEMINI_API_KEY`), then `npm start`. It listens on port 8080.
3. Network: join all phones to one phone hotspot, run the server on a laptop on it, and enter the laptop's LAN IP in the app's settings.

## Docs
- `docs/architecture.md`: modules, models, protocol.
- `docs/tasks.md`: ordered checklist with owners.
- `AGENTS.md`, `CLAUDE.md`: rules for coding agents.
