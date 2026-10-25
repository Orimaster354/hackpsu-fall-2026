# Blindspot: Interview Spec (HackPSU 2026, 24h)

Status: interview complete, pending user approval. No code or docs written yet.

## Decisions

| Area | Decision |
|---|---|
| Platform | Native iOS (Swift/SwiftUI), 4 iPhones; Node.js WebSocket authoritative server (Windows) |
| Network | Server on a laptop, phones on a phone hotspot, LAN IP |
| Join | 4-letter room code, no QR |
| Positioning | Host scans room (RoomPlan/ARKit), saves ARWorldMap + grid; map uploaded to server, joiners download and relocalize (20s timeout) |
| Fallback | Manual tile pick on a 2D room map (also the dev/test mode, build first) |
| Grid | 1.0 m tiles, derived from the scan bounds |
| Position updates | Each phone sends its tile (not raw pose) at ~2-4 Hz; server decides adjacency |
| Scan (revised) | Host records 2 videos + pose logs (overview, then edge walk). Server builds polygon, grid, stations, emergency tile. Task stations on edge tiles only. Players see AR icons (question mark on tasks, EMERGENCY text on the meeting tile) |
| AI | Gemini Flash on the videos returns timestamped objects; server casts a ray from the pose at that time and snaps to the nearest edge tile; host can edit. No canned fallback. Key stays on the server |
| Roles | 1 impostor + 3 crew (count configurable) |
| Kill | Impostor swipe, valid only if victim is on the SAME tile, 25s cooldown |
| Death | Ghost leaves their phone on the spot as the body and may wander; the phone's tile is the body location; others report from that tile |
| Meetings | Full loop: report body or emergency button, discussion/vote ~30s, ejection reveal, win check |
| Sabotage | Lights out: crew screens dim and tasks disabled until a crew member holds a fix station |
| Tasks | Shake/tilt balance, hold-steady/pour, rotate dial, phone gesture pattern (generous tolerance; cut first) |
| Win | Crew: all tasks done or impostor ejected. Impostor: alive crew <= impostors |
| Demo | Scripted 2-3 min run: scan, AI stations, one task, one kill, report, vote |

## Open points to confirm at plan approval
- Ghost tasks: ghosts leave the phone, so assume ghosts do NOT do tasks; task counter must use living crew only.
- Gesture-pattern task is the first cut if time slips.
- Exact win-check when ghost phone is idle (server treats ghost as non-voting).

## Risks and mitigations
1. ARWorldMap relocalization fails: manual tile pick fallback, tested before any AR work.
2. Drift misplaces tiles: 1 m tiles, server smoothing (require 2 consecutive reports).
3. Gemini mislabels or box misses mesh: host edits/rejects; ship a canned stations JSON as demo backup.
4. Hotspot/Wi-Fi drop: server keeps authoritative state, clients auto-reconnect with player id.

## Workstreams (by layer)
- A (Mac 1): scan, ARWorldMap, grid, tile tracking, raycast.
- B (Mac 2): SwiftUI screens, role/meeting/vote UI, Core Motion tasks.
- C (Windows): Node server, state machine, protocol, Gemini proxy.
- D: shared contracts (protocol.md + Swift Codable models), integration, demo script.

## Build order
1. Contracts and server skeleton with fake clients; manual-tile mode end to end (lobby, roles, kill, meeting).
2. Tasks and sabotage.
3. Scan + grid + map upload.
4. Relocalization + tile broadcast.
5. Gemini stations.
6. Demo rehearsal.

## Deliverables after approval
README.md, AGENTS.md, CLAUDE.md, docs/architecture.md, docs/tasks.md.
