# `worker-cli wait` — Pull-Based Replacement for the Orchestrator Sleep-Timer

The orchestrator previously armed a raw `sleep 3300 && echo done` background timer after
dispatching work to a worker; an external menubar process killed that sleep once all
workers of the project went idle (push). This was fragile (premature/duplicate wakeups,
block-hooks forcing extra agent reasoning). `worker-cli wait [project_path] [--timeout N]`
replaces it: a single blocking command the orchestrator launches as its own background
task, whose exit IS the wake-up (pull). Implemented as a new `wait` case in `bin/worker-cli`
— `src/spawn/tmux_spawn.sh` untouched (only consumed via its existing `worker_list` /
`worker_status` functions).

## Stability window: 3 samples x 5s poll = 10s span

A single idle sample can't rule out a sampling race at the exact hook-transition instant.
Chose 5s poll interval, 3 consecutive idle samples required — 10s between the first and
last confirming sample. 10s reuses the figure `_worker_detect_status` already relies on for
its `window_activity` stale-check (WORKING_THRESHOLD_SECS=10 — see the `process-docs/worker_status/`
area) — an already-vetted "long enough to not be noise" constant in this codebase, not a new
number invented for this feature.

## Fail-toward-waiting, everywhere

Only a verbatim `"idle"` string counts as idle. `working`, `limit reached`, `unknown`, and
any probe crash all fall through to NOT idle — no separate error branch needed. `worker_list`
failing entirely (tmux hiccup, or the process crashing, see below) yields an empty NAMES list,
handled identically to "no worker visible yet" (keep waiting, never exit). `--timeout` (default
3300, matching the old sleep) is the only way out when nothing ever goes idle.

## Worker-side background-task visibility — heuristic, not a guarantee

`_worker_detect_status`'s existing process-tree check only confirms *a* `claude`-named
descendant of the pane exists — it does not look at whether THAT claude process still has
live children of its own. A `run_in_background` bash tool call inside the worker's own
session would leave the Stop hook firing normally (hooks.json -> idle) while a live child
process still runs under the worker's `claude` pid.

Added `_wait_has_live_bg_task` (new, additive — does not touch `tmux_spawn.sh`): walks
pane_pid -> claude-descendant (same lookup `_worker_detect_status` already does) one level
deeper, and treats any live grandchild as "not done". Explicitly a heuristic, not a
guaranteed-accurate detector: it only sees processes still attached in the tmux pane's
process tree — a fully detached/double-forked background process would be invisible to it.
Any probe failure (session vanished, tmux error) resolves to "yes, treat as busy" — same
fail-toward-waiting direction as the status check.

## Test-fixture pitfall: `worker_list` crashes silently on a session missing WORKER_SPAWNED/WORKER_PURPOSE

First test run: a fake tmux session with a genuinely `idle` hooks.json entry still made
`wait` time out. Root cause: `worker_list` (`tmux_spawn.sh`) reads `WORKER_SPAWNED` /
`WORKER_PURPOSE` via `tmux show-environment`, which exits non-zero when the var was never
set. Under the script's `set -euo pipefail` (re-applied on every `source`), that bare
`pipefail`d assignment aborts the whole function mid-loop with zero output — same failure
class already documented for the hooks.json read in the `process-docs/worker_status/` area.
Real spawned workers never hit this (`spawn_claude_worker` always sets both vars); only a
hand-built test fixture that skips them does. Fixed in the test fixture (sets both vars
right after `tmux new-session`, mirroring production), not in `tmux_spawn.sh` — out of this
task's negative scope, and not a real production bug.

## Test-fixture pitfall: killing a background child can collapse the whole process chain

For the "worker-side background task ends" test case, the naive dummy worker script backed
the "claude" process directly onto the background child (`exec -a claude-dummy bash -c
'sleep N & wait'`): killing the child made that `wait` return, which ended the whole
claude-dummy process (its last command), which propagated up and killed the tmux pane —
`pane_dead=1`, status flips to `limit reached`, never `idle`. Fixed by having the dummy
claude process re-exec into a bare `sleep` (`exec -a claude-dummy sleep N`) after its `wait`
returns — same pid, same process name, now with zero children, staying alive as the
`idle`+no-background-task end state the test needs to observe.

## Verification

`dev/worker_wait/test_worker_wait.sh` — 5 integration-level cases, all against the real
`worker-cli wait` binary, real tmux sessions, and a scoped `hooks.json` entry (backed up
before the run, restored after, whatever the outcome):

1. idle worker -> exits `workers idle` in 10s (within the 9-25s window for a 5s-poll/10s-stability design).
2. no worker + `--timeout 6` -> exits `timeout` at ~10s (coarse due to 5s poll granularity — a documented, acceptable "late, never early" cost).
3. two concurrent `wait` processes on the same idle transition both exit 0 / `workers idle`.
4. probe target killed mid-wait (tmux session vanishes) -> process stays alive immediately after, final reason is `timeout`, never `workers idle`.
5. idle status with a live worker-side background task holds `wait` for the full window; killing the background child lets it exit `workers idle` promptly afterward.

All 5 passed on the final run. Verified at the entry-point level (the real `bin/worker-cli
wait` subcommand, real argument parsing, real polling loop) against real tmux + real
`hooks.json` reads — not a stub. NOT verified: the actual orchestrator wiring (spawning
`wait` as its own background task and reading the printed reason line back) — that
integration is the orchestrator side of this change, out of scope here.
