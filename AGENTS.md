# AGENTS.md

Shared rules for all coding agents. Read `docs/architecture.md` and `docs/tasks.md` first.

## Rules
1. Work only inside your owned paths (see below). If you need a change elsewhere, ask the owner or open a note in `docs/tasks.md`.
2. `docs/architecture.md` is the contract. Do not change message names, fields or model shapes without updating it in the same commit and telling the other owners.
3. The server is authoritative. Clients send intents; the server validates and broadcasts state.
4. Clients send tiles `{x, y}`, never raw ARKit poses.
5. Every AR feature must work with the manual-tile fallback. Build the manual path first.
6. Never put API keys in the app or the repo. Gemini is called only from the server.
7. No databases, auth or extra frameworks. In-memory state, plain JSON over WebSocket.
8. Small commits, branch per workstream (`ar/`, `ui/`, `server/`), rebase on `main` before merging. Never edit `project.pbxproj` by hand; add Swift files via Xcode only on the Mac owner's branch, and tell others to pull.
9. Cut order when behind: gesture-pattern task, sabotage, Gemini suggestions.
10. Keep it simple. Prefer the least code that passes the acceptance criteria in `docs/tasks.md`.

## Ownership
| Workstream | Owner | Paths |
|---|---|---|
| A: AR, scan, grid, tile tracking | Mac 1 | `MyApp/AR/` |
| B: SwiftUI screens, tasks, Core Motion | Mac 2 | `MyApp/UI/`, `MyApp/Tasks/` |
| C: Server, state machine, Gemini | Windows | `server/` |
| D: Contracts, networking client, integration | Shared lead | `MyApp/Net/`, `MyApp/Models/`, `docs/` |
