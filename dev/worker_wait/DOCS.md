# dev/worker_wait/

## Role

Integration tests for `worker-cli wait` (`bin/worker-cli`, `wait` case) — the pull-based
replacement for the orchestrator's background sleep-timer.

## Modules

### test_worker_wait.sh

**Purpose:** Exercise the real `worker-cli wait` binary against real tmux sessions + a
scoped `hooks.json` entry (backed up/restored around the run, never left dirty).

**Transition-gate contract (2026-09-02):** `wait` may only exit `"workers idle"` or `"worker
dead"` if THIS invocation observed at least one `working`-status poll first (`SAW_
WORKING`, set only on a verbatim `working` classification, never on the `dead`/default-arm
busy path). An idle-at-arm or never-registered worker is a *state*, not a *transition* —
`wait` now keeps polling through it instead of exiting on it. The `"no workers"` fast-exit
(C3, 2026-08-18) is removed entirely: an empty roster is just another non-exiting state,
same reasoning as idle-at-arm. Covers: idle-from-start and never-registered never exit
early (run to the timeout ceiling instead), a genuinely `working` (chatty print-loop, keeps
`#{window_activity}` fresh past the 10s demote threshold — `tmux_spawn.sh`) worker edging
to idle DOES exit `"workers idle"` within the existing 3-sample/5s-poll stability window,
two concurrent `wait` processes armed during a real working phase exit together on the same
edge, a working worker whose claude child is killed (session/pane stay alive via
`remain-on-exit`, distinct from a killed SESSION which stays on the untouched empty-`NAMES`
path) edges to `"worker dead"`, and `wait` armed while idle survives an idle-only stretch
well past the old 15s threshold before exiting only after a later working->idle edge, never
the first idle phase. The `saw_working=` flag is on every per-poll and exit trace line for
direct before/after diffing.

**Working/idle/dead vocabulary (2026-09-02, milestone 2 of the status-vocabulary change):**
`bin/worker-cli`'s own consumers of `_worker_detect_status`/`worker_status` were moved from
the retired `working`/`idle`/`"limit reached"`/`unknown` set to the closed three-value
`working`/`idle`/`dead` set `tmux_spawn.sh` now returns (milestone 1, same area). `wait`'s
classification switch collapsed the `"limit reached"|unknown)` arm into a single `dead)`
arm — trace fields renamed `class=dead`, `reason=worker_dead`, `any_dead=`; exit line
`"worker dead"`. A `worker_status`/`_worker_detect_status` subprocess-call FAILURE (not a
worker_status "dead" answer, which already returns 0) is a probe error, not a worker state —
`wait`'s fallback is `probe-error`, which lands in the switch's `*)` default arm (stays
blocking, never arms `SAW_WORKING`) and is visible verbatim on the trace's `status=` field.

**A vocabulary consequence discovered by running the suite, not assumed:** a fresh pane
with no hooks.json entry (`create_worker_no_hook`) is no longer a distinct terminal state.
It now shares the SAME window-activity check as any other no-hook-data case — it reads as
`working` for its first ~10s (a just-created pane's activity is genuinely fresh; this is a
correct default, not a misclassification) and self-heals to `idle` once quiet. This retires
Test 7's original "stuck forever" framing: the 2026-08-19 incident it regression-guarded is
now fixed by self-healing rather than a special carve-out, so Test 7 was RE-PURPOSED (not
just relabeled) to assert `"workers idle"` after the self-heal, with a trace check for
`status=working` polls settling into `status=idle` polls. The "never observed working, gate
holds" proof for a from-the-start case still lives in Tests 1/2/11a, which use an explicit
`idle` hook status or no worker at all — neither goes through this shared fresh-pane
window. Similarly, `delete_hook_entry` ALONE is no longer a dead signal (same reasoning) —
Test 10 now combines it with `kill_claude_child` (the real dead signal) to build a
realistic dead-and-hook-orphaned worker, rather than relying on hook-deletion by itself.

**Also covers (unchanged by the transition gate or the vocabulary move, verified
compatible): the C1 (2026-08-18) trace-observability check (`event=start`/`event=exit`
lines diffed via before/after byte offset on the real, shared, gitignored
`wait_trace.log`, now additionally grep-scoped to this test's own `project=` tag — a
concurrently running REAL `wait` invocation elsewhere on the machine writes to the same
shared file and would otherwise pollute a byte-offset-only diff, observed live during this
milestone), a live incident regression (idle worker with a **persistent tooling-child
process** under its `claude` pid, e.g. a language server, correctly ignored by the
handle-based bg-task check), a vanished probe target (killed SESSION, not just the claude
child) never yielding a false `"workers idle"`, a genuinely open `*.output` write handle
holding off exit until closed — including the `/tmp` vs `/private/tmp` resolution gotcha —
and an `lsof`-unresolvable probe error never yielding a false `"workers idle"` either.

**Dead-worker wake (2026-08-19 incident regression, terminology updated 2026-09-02):** a
stably `dead` worker (after a real working phase, per the transition gate above) folds
into the same "non-blocking" bucket as `idle` on the existing stability window, exiting
`"worker dead"` (distinct from `"workers idle"`). Covers: a killed claude child with the
pane held alive via `remain-on-exit` (`kill_claude_child`), a wrapper that exits
immediately (`create_worker_dead`, `#{pane_dead}=1` directly), a mixed project (one dead +
one genuinely `working` worker — proves dead doesn't short-circuit a real busy worker, and
the exit line stays `"worker dead"` once the busy one finishes), and a dead worker (process
killed AND hook entry deleted) with a live open `*.output` handle still exiting promptly
(proves the bg-task probe is deliberately skipped for dead statuses, not applied like it
is for `idle`).

**Chatty fixture gotcha:** `create_worker`'s `CHATTY=1` mode is the only way to keep
`#{window_activity}` fresh past 10s (a plain/`BG=1` worker is silent, so a `working` status
flipped in well after creation demotes to `idle` before ever being read as `working`).
`go_quiet()` stops the print loop; `kill_claude_child()` kills just the recorded
claude-dummy pid (leaves the session/pane alive, which then goes dead via `remain-on-exit`
once the wrapper's own `wait $CLAUDE_PID` returns) — do not confuse with killing the whole
tmux SESSION, which routes through the untouched empty-`NAMES` path instead and never
classifies as dead. `delete_hook_entry()` alone does NOT make a worker dead (see the
vocabulary-consequence note above) — pair it with `kill_claude_child()` for a genuine dead
fixture.

**Usage:** `bash dev/worker_wait/test_worker_wait.sh` (~5-6min; spins up/tears down
throwaway tmux sessions under `worker-<basename>-<name>`, plus throwaway `*.output` file
handles under `/tmp/claude-<uid>/`; appends to the real `wait_trace.log`, never truncates
it). Run it ONCE at a time — concurrent invocations race on the same real `hooks.json`
backup/restore cycle and can corrupt each other's in-progress fixtures (observed once
during an earlier milestone from an accidental double-invocation, not a bug in the suite
itself).
