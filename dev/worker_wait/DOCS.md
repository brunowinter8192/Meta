# dev/worker_wait/

## Role

Integration tests for `worker-cli wait` (`bin/worker-cli`, `wait` case) — the pull-based
replacement for the orchestrator's background sleep-timer.

## Modules

### test_worker_wait.sh

**Purpose:** Exercise the real `worker-cli wait` binary against real tmux sessions + a
scoped `hooks.json` entry (backed up/restored around the run, never left dirty). Covers:
prompt exit on a stably-idle worker, timeout with no worker visible, two concurrent `wait`
processes on the same idle transition, a vanished probe target never yielding a false
"workers idle", and a live worker-side background task (child process under the worker's
`claude` pid) holding off exit until it ends.
**Usage:** `bash dev/worker_wait/test_worker_wait.sh` (~90s; spins up/tears down throwaway
tmux sessions under `worker-<basename>-w1`).
