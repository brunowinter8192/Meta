# dev/worker_spawn/

## Role

Smoke tests for the worker spawn flow (`src/spawn/`) — tmux session creation, env inheritance, cross-project worktree tracking, pane capture cleaning. No live Claude Code session started; dummy commands stand in.

## Modules

### test_capture_clean.py

**Purpose:** Fixture-based smoke for `src/spawn/_capture_clean.py`.
**Usage:** `python3 dev/worker_spawn/test_capture_clean.py` (from project root)

### test_direct_command.sh

**Purpose:** Verify tmux session inherits env vars (GH_TOKEN, PATH) when using direct command arg.
**Usage:** `bash dev/worker_spawn/test_direct_command.sh`

### test_spawn_flow.sh

**Purpose:** Test the full spawn flow without starting a real Claude Code session (dummy command instead of claude-patched). Covers proxy env, non-blocking tmux session creation, non-blocking Ghostty viewer.
**Usage:** `bash dev/worker_spawn/test_spawn_flow.sh`

### test_xproject_worktrees.sh

**Purpose:** Smoke test for cross-project worktree tracking in worker-cli. Uses `WORKER_REGISTRY_DIR` + throwaway git repos — no tmux, no spawn, no live registry.
**Usage:** `bash dev/worker_spawn/test_xproject_worktrees.sh`
