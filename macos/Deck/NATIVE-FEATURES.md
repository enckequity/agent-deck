# Deck ↔ agent-deck: what's native, what we use, what stays hand-rolled

Deck (`macos/Deck/`) is a native SwiftUI front end; `deck-task` (`~/bin/deck-task`,
tracked here as `macos/Deck/deck-task`) launches one autonomous session per task.
This note records the research into agent-deck's own features and the changes made
to lean on them.

agent-deck version inspected: **v1.16.10** (`agent-deck --help`), fork of
`asheshgoplani/agent-deck`.

## Short version

We now use agent-deck for worktree creation, branch reporting, replies, session
start/stop, archive, and the done marker. Four things stay hand-rolled because the
native feature does a *different* job: the opencode conversation reader, the
FSEvents refresh, macOS notifications, and the per-harness auto-continue nudger.

## Native features that overlap with Deck / deck-task

### Worktrees
- `agent-deck launch <repo> -w <branch> -b` (and `add -w -b`) creates the git
  worktree, roots the new branch at origin's default branch with a best-effort
  `fetch`, honours `[worktree] path_template`, runs `.agent-deck/worktree-setup.sh`,
  and registers the worktree against the session.
- `agent-deck worktree info <session> --json` → `{branch, worktree_path, main_repo}`.
- `agent-deck worktree finish <session>` → **local** merge into a target branch,
  then remove the worktree and delete the session (`--no-merge`, `--keep-branch`,
  `--into` available; also `POST /api/sessions/{id}/worktree/finish`).
- `agent-deck worktree list|cleanup`, plus `.agent-deck/worktree-*.sh` trust scripts.

### Completion sentinel, children, inbox
- Every spawned session gets an identity block; the canonical completion line is
  `===AGENTDECK_DONE=== status=<ok|fail> summary=<one line>`.
- `launch --assert-done` appends the instruction to the initial message (default
  **on** for Claude-compatible tools only).
- `session children --json`, `inbox drain --json`, and a `notify-daemon` transition
  notifier carry child completions up to a parent.

### Conductor (native auto-response)
- `agent-deck conductor setup <name>` registers a persistent supervised session
  (Claude/Codex) that reads `POLICY.md`, watches sessions in `waiting`/`error`,
  auto-responds when policy matches and escalates otherwise.
- A launchd heartbeat daemon pings it on an interval (default 15 min); watchers
  (GitHub/ntfy/webhook) ring it for external events.

### Event stream (web server)
- `agent-deck web [--no-tui] [--read-only]` serves:
  - `GET /events/menu` — SSE; pushes the session snapshot when it changes
    (2s internal poll, 15s keepalive comment), with the same hook-status overlay
    the REST handlers apply.
  - `GET /api/menu`, `/api/session/<id>`, `/api/sessions`, `/api/costs/*`,
    `/api/push/*`, and `WS /ws/session/<id>` (terminal).
- Measured: headless read-only server ~**27 MB RSS**.

### Notifications
- `[notifications] desktop = true` makes the **TUI process** fire OS notifications
  (`internal/desknotify`, osascript/notify-send).
- `agent-deck web --push` sends **Web Push** to a browser/PWA (needs a service
  worker and VAPID keys).

## Answers to the specific questions

**(a) Can the conductor replace our auto-continue hooks? No.**
The conductor does auto-respond to `waiting`/`error` sessions, but it is a
heavyweight persistent Claude session driven by a 15-minute heartbeat, needs a
launchd daemon (and, for real use, a channel) to be useful, and only reacts to a
*status*, not to the end of a turn. Our hooks are event-driven, per-harness
(Claude Stop hook + opencode plugin), cost nothing when idle, deny the blocking
question tool, and bound nudges to 25 per human prompt. On an 8 GB Mac, adding a
second always-on Claude session to replace two tiny scripts is a bad trade. The
hook contract lives in `agents-sync` (outside this repo), so it was left alone.

**(b) Native worktree → PR → merge? No.**
`worktree finish` performs a **local** merge, which bypasses the PR/review flow
`deck-task` requires. `--no-merge` is teardown-only. It is not a drop-in for
`gh pr merge`, so `deck-task` still drives the PR itself.

**(c) Should Deck subscribe to `/events/menu` SSE instead of FSEvents + `list --json`? No.**
SSE only carries session metadata; it does **not** carry the opencode conversation,
so Deck would still watch `opencode.db`. FSEvents delivers the same change signal
serverlessly and also catches opencode history writes. Adding an always-on web
server would spend ~27 MB RAM and a new failure mode for no functional gain.
FSEvents stays.

**(d) Native notifications to replace Deck's? No.**
Deck already uses `UNUserNotificationCenter`, which *is* the native macOS API for a
GUI app. agent-deck's desktop notifications belong to the TUI process, and its push
notifications target browsers/PWAs. Nothing to reuse.

## What we changed (each its own commit)

1. **`deck-task` worktree creation is now native** (`refactor(macos): let agent-deck
   create deck-task worktrees natively`). Deleted the hand-rolled `git fetch`,
   `git worktree add`, branch-base resolution, and path construction. `deck-task`
   now calls `agent-deck launch <repo> -w <branch> -b …`.
2. **Deck reads the branch from agent-deck** (`refactor(macos): resolve worktree
   branch via agent-deck worktree info`). Deleted the fragile path-based branch
   inference (the native creator sanitizes `branch/with/slashes` to `branch-with-
   slashes`); "Copy Branch Name" now calls `agent-deck worktree info <id> --json`.
3. **Deck defers replies to busy sessions** (`fix(macos): defer replies to busy
   sessions …`). Uses native `agent-deck session send --defer-if-busy` so a reply
   lands at the turn boundary instead of interrupting generation.

Already native before this work: session start (`session start`), replies
(`session send`), archive (`session archive`), and the TUI-facing session list
(`list --json`).

## What stays hand-rolled, and why

- **opencode conversation reader** (`Conversation.swift`, SQLite): agent-deck only
  exposes a session's *last* response (`session output`), and for opencode that is
  a raw terminal snapshot with TUI box-drawing artifacts, not structured history.
  Reading opencode's own store is the only way to render the conversation.
- **FSEvents refresh** (`FileWatcher.swift`): serverless and covers opencode.db;
  see (c).
- **macOS notifications** (`UNUserNotificationCenter`): already the native API;
  see (d).
- **auto-continue hooks** (`agents-sync`, outside this repo): see (a).
- **`deck-task` prompt and free-disk guard**: task-specific content agent-deck has
  no opinion on (the guard is surfaced through Deck's error UI).

## Recommended follow-up (not done here)

agent-deck's native sentinel parser (`ParseDoneSentinel`) requires
`status=<ok|fail>`, but `agents-sync/hooks/auto-continue-core.mjs` `isTerminal`
accepts only a bare `===AGENTDECK_DONE===` line. So agent-deck's completion ledger
never sees a deck-task worker as *done* — only as *waiting*. Allowing the native
`status=…` suffix in `isTerminal` (a one-line change in `agents-sync`) would let
`deck-task` pass `launch --assert-done` and make completions visible to
`session children` / the parent inbox. Left out because it touches the shared
hooks repo that other running agents depend on.
