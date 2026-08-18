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
**Usage:** `bash dev/worker_wait/test_worker_wait.sh` (~2min; spins up/tears down throwaway
tmux sessions under `worker-<basename>-w1`, plus a throwaway `*.output` file handle under
`/tmp/claude-<uid>/`; appends to the real `wait_trace.log`, never truncates it).
