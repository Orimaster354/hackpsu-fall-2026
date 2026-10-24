# CLAUDE.md

Follow everything in `AGENTS.md`. It is the source of truth. This file only adds Claude Code specifics.

## Workflow
- Start each session by reading `docs/architecture.md` and the unchecked items for your workstream in `docs/tasks.md`.
- Stay in your owned paths. Check `git status` and `git pull --rebase` before starting.
- Tick the checkbox in `docs/tasks.md` when an acceptance criterion is met, in the same commit.
- Use plan mode for anything touching the protocol or shared models.

## Commands
- Server: `cd server && npm start`, tests with `npm test`.
- iOS: build and run from Xcode on a physical iPhone. The Windows side cannot build Swift, so do not attempt it there.
- Fake clients: `node server/tools/fakeClient.js <ROOM>` simulates players for UI work.

## Do not
- Do not add dependencies without a reason noted in the commit.
- Do not edit `project.pbxproj` directly.
- Do not change the wire protocol without updating `docs/architecture.md`.

Commit message end: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`
