# worker-cli janitor — stale-worker cleanup subcommand

**Date:** 2026-08-19

## Problem

Worker tmux sessions accumulate: workers die (context limit) or the registry loses track of
them, and their tmux sessions + worktrees + branches linger. Live example at investigation
time: tmux session `worker-repro1b58790-w1` (~22h old) existed with no corresponding
`~/.claude/.worker-registry/` entry.

## Design: resolving (name, project) from a raw session string

The registry is keyed by worker NAME, but a janitor sweep starts from a raw tmux SESSION
string (`worker-<project-basename>-<name>`) — the inverse direction of every existing
resolution helper in `bin/worker-cli` (`resolve_worker_project`, `tmux_scan_project` both take
NAME as input). Splitting the session string on `-` is ambiguous both ways: project basenames
contain dashes (`iterative-dev`) AND worker names contain dashes (`keep-filters`,
`menubar-remote`), so no fixed split point works.

Resolution order implemented (`_janitor_resolve_worker` in `bin/worker-cli`):
1. **Registry recompute** — for every registry entry, rebuild its expected session name via
   `_worker_session_name` (`src/spawn/tmux_spawn.sh`) and compare to the actual session. Exact
   match, no guessing.
2. **`pane_current_path`** — worktree-mode spawns `cd` into `$PROJECT/.claude/worktrees/$NAME`
   before launching (`spawn_claude_worker` in `tmux_spawn.sh`), so the pane's cwd directly
   yields both PROJECT (strip the worktree suffix) and NAME (its basename) — no ambiguity, same
   technique `_worker_detect_status` already relies on for its own hooks.json lookup.
   `--no-worktree` spawns cd into PROJECT directly (no suffix); NAME then comes from an exact
   `worker-<basename(PROJECT)>-` prefix strip on the session string, since PROJECT is already
   known independently of the session string in that branch.
3. **`tmux_scan_project` fallback** — last resort, guesses NAME as the session's trailing `-`
   segment and reuses the existing helper (filesystem search + registry-cache write).

Every candidate from steps 2-3 is round-trip verified — `_worker_session_name(candidate_project,
candidate_name)` must reproduce the exact original session string — before being accepted.
A wrong guess fails the round-trip and falls through to `skip-unresolvable`, never masquerades
as resolved. Cleanup itself reuses the existing `kill` case verbatim via a recursive `"$0" kill
NAME PROJECT` subprocess call, per the "reuse the kill path, don't duplicate raw
tmux/git cleanup" constraint — `bin/worker-cli` stayed the sole touched file;
`src/spawn/tmux_spawn.sh` was not modified.

## Safety: isolating the "real kill" smoke test from live tmux state

`janitor` sweeps ALL `worker-*` sessions server-wide — unlike `wait`/`list` (project-scoped),
there's no natural scope keeping a real (non-dry-run) test away from live sessions, and
`session_created` can't be faked, so exercising the age gate requires `--max-age-hours 0`,
which matches every live `worker-*` session on the machine.

Verified empirically that `TMUX_TMPDIR` does NOT isolate a new tmux server when already
inside an attached tmux session (`$TMUX` env var wins over `TMUX_TMPDIR`-derived socket
resolution) — a `TMUX_TMPDIR` override for the test subprocess still saw and could have
touched the real default server's sessions. `tmux -L <name>` (explicit alternate socket) DOES
fully isolate — confirmed a session created via `-L` is invisible to a plain `tmux
list-sessions` on the default server and vice versa.

`dev/worker_janitor/test_janitor.sh` exploits this via a PATH-shadowed `tmux` wrapper
(`exec <real-tmux-path> -L janitor_smoke_test_$$ "$@"`) placed ahead of the real `tmux` in
`PATH` for its own subprocess tree only. `bin/worker-cli`'s bare `tmux` invocations resolve
through PATH to the wrapper transparently — zero source changes to `bin/worker-cli` or
`tmux_spawn.sh` for testability, and the real-kill pass structurally cannot reach live state
even at `--max-age-hours 0`.

## Verification (2026-08-19)

- Dry-run against LIVE tmux state (default server, no wrapper): `worker-repro1b58790-w1`
  (~22.6h old) listed as the sole `DRY-RUN candidate`; `worker-linkedin-keep-filters`,
  `worker-wise2627-menubar-remote`, and this worker's own `worker-monitor-cc-janitor` session
  all spared by the default 12h age gate. Confirmed post-run: all 4 live sessions'
  `session_created` timestamps unchanged (zero interaction).
- Smoke test (`dev/worker_janitor/test_janitor.sh`, isolated `-L` server): 11/11 checks pass —
  dry-run lists a stale synthetic session without killing it; a real run kills it end-to-end
  (tmux session + worktree + branch + registry, via the reused `kill` path) with a
  `janitor.log` line; a fresh synthetic session is spared by the default 12h threshold; an
  orphan registry entry (registry file, no live tmux session, past the 30s spawn-race grace
  window) is cleaned via the same `kill` path.
- NOT exercised live: the `working`-status skip branch. `_worker_detect_status`'s only route
  to `working` is a real `hooks.json[session_id].status` entry keyed off a real Claude Code
  JSONL session — faking one safely would mean writing throwaway keys into the real, shared,
  global `hooks.json` (the `worker_wait` test suite accepts this trade-off with a
  backup/restore discipline; this session did not, given the added blast-radius risk in a
  server-wide sweep). This branch is code-reviewed only, not integration-tested.

## Gotcha carried into `dev/worker_janitor/DOCS.md`

`mktemp -d`'s default macOS naming (`tmp.XXXXXXXX`) contains a `.` — tmux silently rewrites
`.`/`:` (reserved tmux target-spec separators) to `_` in session names on creation, desyncing
the actual live session name from what `_worker_session_name` computes from the path's
basename. First surfaced as a spurious `skip-unresolvable` in the smoke test's first draft;
root-caused to the test harness's temp-dir naming, not a janitor resolution bug. Latent
elsewhere in the wider spawn system too (any project path whose basename contains a `.` would
hit the same divergence) — out of this area's scope, not fixed.
