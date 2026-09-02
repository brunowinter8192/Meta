# dev/worker_wait/

## Role

Integration tests for `worker-cli wait` (`bin/worker-cli`, `wait` case) — the pull-based
replacement for the orchestrator's background sleep-timer.

## Modules

### test_worker_wait.sh

**Purpose:** Exercise the real `worker-cli wait` binary against real tmux sessions + a
scoped `hooks.json` entry (backed up/restored around the run, never left dirty).

**Transition-gate contract (2026-xx):** `wait` may only exit `"workers idle"` or `"worker
terminal"` if THIS invocation observed at least one `working`-status poll first (`SAW_
WORKING`, set only on a verbatim `working` classification, never on the terminal/unknown
default-arm busy path). An idle-at-arm or never-registered worker is a *state*, not a
*transition* — `wait` now keeps polling through it instead of exiting on it. The `"no
workers"` fast-exit (C3, 2026-08-18) is removed entirely: an empty roster is just another
non-exiting state, same reasoning as idle-at-arm. Covers: idle-from-start and
never-registered never exit early (run to the timeout ceiling instead), a genuinely
`working` (chatty print-loop, keeps `#{window_activity}` fresh past the 10s demote
threshold — `tmux_spawn.sh:172-186`) worker edging to idle DOES exit `"workers idle"`
within the existing 3-sample/5s-poll stability window, two concurrent `wait` processes
armed during a real working phase exit together on the same edge, a working worker whose
claude child is killed (session/pane stay alive via `remain-on-exit`, distinct from a
killed SESSION which stays on the untouched empty-`NAMES` path) edges to `"worker
terminal"`, and `wait` armed while idle survives an idle-only stretch well past the old
15s threshold before exiting only after a later working->idle edge, never the first idle
phase. The `saw_working=` flag is on every per-poll and exit trace line for direct
before/after diffing.

**Also covers (unchanged by the transition gate, verified compatible):** the C1
(2026-08-18) trace-observability check (`event=start`/`event=exit` lines diffed via
before/after byte offset on the real, shared, gitignored `wait_trace.log`), a live
incident regression (idle worker with a **persistent tooling-child process** under its
`claude` pid, e.g. a language server, correctly ignored by the handle-based bg-task
check), a vanished probe target (killed SESSION, not just the claude child) never
yielding a false `"workers idle"`, a genuinely open `*.output` write handle holding off
exit until closed — including the `/tmp` vs `/private/tmp` resolution gotcha — and an
`lsof`-unresolvable probe error never yielding a false `"workers idle"` either.

**Terminal-status wake (2026-08-19, incident regression):** a stably `unknown`/`limit
reached` worker (after a real working phase, per the transition gate above) folds into the
same "non-blocking" bucket as `idle` on the existing stability window, exiting `"worker
terminal"` (distinct from `"workers idle"`). Covers: session-alive-but-status-stuck-on-
`unknown` (via a deleted hooks.json entry, not a session/process teardown — distinct from
the probe-vanishes/session-GONE fixture, which stays on the empty-`NAMES` path untouched
by this), stuck `limit reached`, a mixed project (one terminal + one genuinely `working`
worker — proves terminal doesn't short-circuit a real busy worker, and the exit line stays
`"worker terminal"` once the busy one finishes), and a terminal worker with a live open
`*.output` handle still exiting promptly (proves the bg-task probe is deliberately skipped
for terminal statuses, not applied like it is for `idle`).

**Known flake source (observed, not fixed here — out of this area's scope):** `unknown` is
an overloaded string — `_worker_detect_status`/`worker_status` (`src/spawn/tmux_spawn.sh`)
also return it for transient no-data-yet conditions (fresh-spawn pre-JSONL, a momentary
probe hiccup), not only a stuck/dead worker. A blip lasting >=2 consecutive 5s polls can
misclassify a healthy worker as terminal — observed once live in an earlier run of this
suite's Test 1b (a probe blip flipped `idle`->`unknown` for two polls, see
`process-docs/worker_wait/`). `tmux_spawn.sh` stays untouched (same established boundary
as the rest of this area) — accepted trade-off, not a bug in `wait`'s own logic.

**Chatty fixture gotcha:** `create_worker`'s `CHATTY=1` mode is the only way to keep
`#{window_activity}` fresh past 10s (a plain/`BG=1` worker is silent, so a `working` status
flipped in well after creation demotes to `limit reached` before ever being read as
`working`). `go_quiet()` stops the print loop; `kill_claude_child()` kills just the
recorded claude-dummy pid (leaves the session/pane alive, which then goes dead via
`remain-on-exit` once the wrapper's own `wait $CLAUDE_PID` returns) — do not confuse with
killing the whole tmux SESSION, which routes through the untouched empty-`NAMES` path
instead and never classifies as terminal.

**Usage:** `bash dev/worker_wait/test_worker_wait.sh` (~5-6min, up from ~2-3min pre-gate —
several fixtures now need a genuine working phase before their edge; spins up/tears down
throwaway tmux sessions under `worker-<basename>-<name>`, plus throwaway `*.output` file
handles under `/tmp/claude-<uid>/`; appends to the real `wait_trace.log`, never truncates
it). Run it ONCE at a time — concurrent invocations race on the same real `hooks.json`
backup/restore cycle and can corrupt each other's in-progress fixtures (observed once
during this rewrite from an accidental double-invocation, not a bug in the suite itself).
