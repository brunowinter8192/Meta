# `_wait_has_live_bg_task` — Process-Tree Walk Replaced with Handle-Based Detection

## Live incident

`_wait_has_live_bg_task` (Milestone 1) counted ANY grandchild under a worker's `claude` process
as a live background task. A real worker holds persistent tooling children — observed live:
`pyright-langserver` running 36+ minutes as a `claude` child. Consequence: `wait` never exited on
the idle transition for any worker that ever spawned tooling — every wake-up degraded silently to
the 3300s timeout ceiling, with no error, no log line, nothing distinguishing it from a legitimately
long-running worker.

## The false-pass lesson

Milestone 1's own live-verification test (this same area, earlier the same day) reported Test 1 as
PASSED — genuinely, at the time. It sampled a
worker BEFORE that worker had ever spawned tooling (a fresh fixture, immediately after creation, no
LSP/MCP process yet existed under its `claude` pid). The process-tree check's flaw was real from the
moment it shipped, but structurally invisible to a test that never gave the worker time to accumulate
the exact child-process shape that breaks it. "Ran once and passed" is not the same claim as "handles
the shapes real workers actually take" — a verification claim needs to name the scenario it covered,
not just the outcome. This entry's own regression test (below) exists specifically to close that gap:
a fixture with a PERSISTENT tooling child, present for the entire test, not killed to reveal a
transition.

## Fix — mirrored, not reinvented

Read `/Users/brunowinter2000/Documents/ai/monitor-cc/src/menubar/proc_cache.py`
(`_has_active_bg`/`_refresh_bg_task_cache`/`_TASKS_BASE`/`_TASKS_BASE_REAL`) — monitor-cc's menubar
already solved this exact problem for its own worker-status display: a session's backgrounded Bash
task is in-progress iff some process holds an open WRITE handle on a `*.output` file under
`/tmp/claude-<uid>/<encoded-session-cwd>/<session-id>/tasks/`, found via `lsof`. LSP/MCP/tooling
processes never hold such a handle — structurally immune to the incident class.

Deliberate simplification vs. the reference: the reference does ONE global `lsof +D <all-sessions>`
scan per tick and filters by string prefix, because the menubar polls MANY sessions every tick.
`worker-cli wait` checks exactly one worker per call, so `_wait_has_live_bg_task` scopes `lsof +D`
directly to that worker's own resolved tasks dir — narrower, no manual prefix-filter needed (lsof's
own `+D` traversal already guarantees scope), measured ~120ms per call.

## Two real bugs found only through live measurement, not from reading the reference

1. **`lsof +D <dir> -Fn` exit code is not a signal.** Verified live, against a real occupied tasks
   dir on this machine (18 genuine open-file lines in stdout): `lsof` still exited 1. Also exits 1 on
   a directory with zero open files. Same exit code, two entirely different outcomes — matches why
   the reference module never checks `subprocess.run(...).returncode`, only parses stdout
   unconditionally. Implemented the same way here.

2. **`set -e` inheritance killed every call where the tasks dir existed at all** — found only by
   adding `set -x` and reading where the trace went silent, not by reasoning about the code.
   `_wait_has_live_bg_task` does `source "$1"` (`tmux_spawn.sh`) inside its own `bash -c '...'`
   subshell; that source re-applies tmux_spawn.sh's OWN `set -euo pipefail` to the REST of the same
   shell. `out=$(lsof +D "$tasks_dir" -Fn 2>/dev/null)` was a bare assignment with no `|| true` guard
   — combined with bug (1) above (lsof exiting 1 even on success), every single call where the tasks
   dir existed silently killed the subshell via inherited `set -e`, producing `error` unconditionally
   — which, per the fail-toward-waiting contract, is ALSO treated as busy, so the bug was invisible
   from the caller's side: `wait` just never finished, indistinguishable from the ORIGINAL incident
   it was written to fix, at first glance. Same failure class already documented in the
   `process-docs/worker_status/` area — a bare assignment failing under an inherited `set -e`
   aborts the enclosing subshell immediately, before the `||` fallback ever printed anything of its
   own. Fix: `out=$(lsof +D "$tasks_dir" -Fn 2>/dev/null) || true`.

Both were caught only by building fixtures that genuinely exercise the "tasks dir exists" path (a
real held-open file, killed and reopened) and watching real timing end-to-end — not by unit-testing
the parsing logic against synthetic `lsof` output, which would never have reproduced the exit-code
quirk or the `set -e` interaction.

## Verification

`dev/worker_wait/test_worker_wait.sh` — 12 checks, all passing on the final run (three earlier runs
caught and fixed real bugs: a fixture-construction mistake that broke the status check, then the
`set -e`/lsof-exit-code bug above):

1. plain idle worker — unchanged from Milestone 1, `workers idle` at 10s.
2. **incident regression**: idle worker with a persistent tooling-child grandchild (never killed) —
   `workers idle` at 10s, same timing as a plain idle worker. This is the direct fix proof.
3. no worker + timeout — unchanged.
4. two concurrent `wait` processes — unchanged.
5. probe target vanishes mid-wait — unchanged (status-check fail-toward-waiting, not bg-check).
6. `/tmp` vs `/private/tmp` resolution — explicit check that the resolved tasks dir starts with
   `/private/tmp/` on this machine, PLUS the open-handle file deliberately opened via the
   UNRESOLVED `/tmp/...` path while the checker resolves `/private/tmp/...` internally — proves
   detection matches regardless of which form was used to open the file (same underlying inode,
   OS-transparent symlink).
7. genuine open `.output` write handle — `wait` holds for 12s+ while open, then exits `workers idle`
   15s after the handle is closed.
8. `lsof` unresolvable (`PATH` stripped of `/usr/sbin`, `tmux` still resolvable) — never reports
   `workers idle` despite a genuinely idle, bg-task-free worker; ends in `timeout`. Isolates the
   bg-check's own error path specifically (distinct from case 5's status-check target-vanishing
   case) — same PATH-stripping technique the (now-removed) `block_timer_no_worker_working` hook's
   tmux-unresolvable verification used.

Fixture construction note (for future maintainers of this test): the persistent-tooling-child
fixture must keep the `claude`-named process ALIVE as a real bash process that FORKS its child —
`( exec -a claude-dummy bash -c '(exec -a pyright-langserver-dummy sleep N) & wait' )` — an early
draft used a nested `exec -a ... exec -a ...` chain that REPLACED the claude-dummy identity
entirely, leaving no `claude`-named process at all and silently breaking the STATUS check (not the
bg-check) instead of testing what it meant to.
