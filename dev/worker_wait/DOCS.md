# dev/worker_wait/

## Role

Integration tests for `worker-cli wait` (`bin/worker-cli`, `wait` case) — the pull-based
replacement for the orchestrator's background sleep-timer.

## Modules

### test_worker_wait.sh

**Purpose:** Exercise the real `worker-cli wait` binary against real tmux sessions + a
scoped `hooks.json` entry (backed up/restored around the run, never left dirty). Covers:
prompt exit on a stably-idle worker, a live incident regression (idle worker with a
**persistent tooling-child process** under its `claude` pid, e.g. a language server —
must still exit promptly, not the old process-tree-walk false positive), **the trace file
records this run's `event=start`/`event=exit` lines** (C1, 2026-08-18 — checked via a
before/after byte-offset diff on the real, shared, gitignored `wait_trace.log`, not a
test-isolated copy), **zero workers ever registered fast-exits `"no workers"` well before
the timeout ceiling** (C3, 2026-08-18 — same 3-sample/5s-poll grace window already trusted
for the idle transition, not a new threshold) **and a timeout shorter than that grace
window still wins cleanly** (proves the two exit paths don't interfere), two concurrent
`wait` processes on the same idle transition, a vanished probe target never yielding a
false "workers idle", a genuinely open `*.output` write handle (the real background-task
signal, 2026-08 handle-based rewrite) holding off exit until closed — including the
`/tmp` vs `/private/tmp` resolution gotcha, exercised by opening the handle via the
unresolved path while the checker resolves the real one — and an `lsof`-unresolvable
probe error never yielding a false "workers idle" either.

**Terminal-status wake (2026-08-19, incident regression):** a stably `unknown`/`limit
reached` worker now folds into the same "non-blocking" bucket as `idle` on the existing
stability window, exiting `"worker terminal"` (distinct from `"workers idle"`) instead of
grinding to the timeout ceiling. Covers: session-alive-but-status-stuck-on-`unknown`
forever (the live incident — distinct fixture from the probe-vanishes/session-GONE case
above, which stays on the empty-`NAMES` path untouched by this), stuck `limit reached`,
a mixed project (one terminal + one genuinely `working` worker — proves terminal doesn't
short-circuit a real busy worker, and the exit line stays `"worker terminal"` once the busy
one finishes), and a terminal worker with a live open `*.output` handle still exiting
promptly (proves the bg-task probe is deliberately skipped for terminal statuses, not
applied like it is for `idle`).

**Known flake source (observed, not fixed here — out of this area's scope):** `unknown` is
an overloaded string — `_worker_detect_status`/`worker_status` (`src/spawn/tmux_spawn.sh`)
also return it for transient no-data-yet conditions (fresh-spawn pre-JSONL, a momentary
probe hiccup), not only a stuck/dead worker. A blip lasting >=2 consecutive 5s polls can
misclassify a healthy worker as terminal — observed once live in this suite's own Test 1b
(a probe blip flipped `idle`->`unknown` for two polls, see `process-docs/worker_wait/`).
`tmux_spawn.sh` stays untouched (same established boundary as the rest of this area) —
accepted trade-off, not a bug in `wait`'s own logic.

**Usage:** `bash dev/worker_wait/test_worker_wait.sh` (~2-3min; spins up/tears down throwaway
tmux sessions under `worker-<basename>-<name>`, plus throwaway `*.output` file handles under
`/tmp/claude-<uid>/`; appends to the real `wait_trace.log`, never truncates it).
