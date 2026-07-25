# dev/

## Role

Development scripts for testing, debugging, and experimentation related to the iterative-dev plugin. Organized by area, mirroring `process-docs/<area>/` where the two align. Touch when adding probes or smoke tests; do NOT touch for production code (`src/`).

## Areas

- [session_pipeline/DOCS.md](session_pipeline/DOCS.md) — session-pipeline audit scripts (reports in `session_pipeline/md/`)
- `worker_spawn/` — spawn-flow smoke tests (see below)
- `worker_status/` — status-detection smoke tests (see below)
- `desktop_targeting/` — space-move probe + report (`desktop_targeting/md/`)
- `cc_hooks/` — CC hook-input inspection helpers

## Modules

### worker_spawn/test_capture_clean.py

**Purpose:** Fixture-based smoke for `src/spawn/_capture_clean.py`.
**Usage:** `python3 dev/worker_spawn/test_capture_clean.py` (from project root)

### worker_spawn/test_direct_command.sh

**Purpose:** Verify tmux session inherits env vars (GH_TOKEN, PATH) when using direct command arg.
**Usage:** `bash dev/worker_spawn/test_direct_command.sh`

### worker_spawn/test_spawn_flow.sh

**Purpose:** Test the full spawn flow WITHOUT starting a real Claude Code session (dummy command instead of claude-patched). Covers proxy env, non-blocking tmux session creation, non-blocking Ghostty viewer.
**Usage:** `bash dev/worker_spawn/test_spawn_flow.sh`

### worker_spawn/test_xproject_worktrees.sh

**Purpose:** Smoke test for cross-project worktree tracking in worker-cli. Uses `WORKER_REGISTRY_DIR` + throwaway git repos — no tmux, no spawn, no live registry.
**Usage:** `bash dev/worker_spawn/test_xproject_worktrees.sh`

### worker_status/test_status_detection.sh

**Purpose:** Verify tmux `#{pane_dead}` transitions from 0→1 after process exits (remain-on-exit mode).
**Usage:** `bash dev/worker_status/test_status_detection.sh`

### desktop_targeting/probe.py

**Purpose:** Space-move API probe (macOS 15.7) — tests CGS/SLS move APIs from an unprivileged process. Report: `desktop_targeting/md/space_move_probe_2026-05-29.md`.
**Usage:** `python3 dev/desktop_targeting/probe.py`

### cc_hooks/log_permission_request.sh

**Purpose:** Log Claude Code PermissionRequest hook input to file for inspection.
**Usage:** install as hook in `~/.claude/settings.json` under hooks.PermissionRequest; output `/tmp/permission_request_log.jsonl`
