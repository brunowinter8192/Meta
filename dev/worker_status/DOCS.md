# dev/worker_status/

## Role

Smoke tests for worker status detection (`_worker_detect_status` in `src/spawn/tmux_spawn.sh`).

## Modules

### test_status_detection.sh

**Purpose:** Verify tmux `#{pane_dead}` transitions from 0→1 after process exits (remain-on-exit mode).
**Usage:** `bash dev/worker_status/test_status_detection.sh`
