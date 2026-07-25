# Worker Revive: Proxy Attachment + Diagnostic Logger Sidecar

**Date:** 2026-05-25
**Commits:** b48b5bb (feat), 231f206 (path-encoding fix)
**Scope:** `src/spawn/tmux_spawn.sh`, `src/spawn/worker_logger.sh` (NEW), `bin/worker-cli`, `src/logs/` (NEW)

## Problem

`worker-cli revive` attached no worker-specific mitmproxy when reanimating. Consequences:
- Revived workers talked directly to api.anthropic.com (without the Monitor_CC proxy addon)
- Proxy-injected rules were missing from the worker's requests
- The cache-prefix hash toward Anthropic changed (the prefix contains the injected rules)
- **Anthropic saw a cache miss → full re-upload of the entire conversation history on every revive**

Plus: two consecutive worker deaths in the session (status 143 = SIGTERM) with no identifiable cause. Without forensic data there was no diagnostic path for future incidents.

## Solution — three connected building blocks

### 1. Refactor: `_worker_proxy_setup` helper extracted

Proxy-setup block moved out of `spawn_claude_worker` (old lines 378-435) into a standalone function. Writes globals `WORKER_PROXY_PID`, `WORKER_PROXY_ENV_PREFIX`, `WORKER_PROXY_LIVE_ADDON`, `WORKER_PROXY_LIVE_DIR`. Returns 0 always (including no-proxy-active), 1 only on dedup error.

`spawn_claude_worker` calls the helper and copies the globals into local vars (backward-compatible with the old heredoc variable interpolation).

### 2. New function `worker_revive` in `tmux_spawn.sh`

Moved out of `bin/worker-cli`. 4 gates (tmux session exists, pane_dead=1, worktree exists, JSONL exists), rescue env vars from the old session (WORKER_MODEL, WORKER_PURPOSE, WORKER_PARENT), kill the old session, **call `_worker_proxy_setup`**, build the runner script with `proxy_env_prefix`, start the new tmux session, restore env vars + pane-died hook, open the viewer.

`bin/worker-cli revive` handler reduced to a delegate call: `bash -c "source $SPAWN && worker_revive $NAME $PROJECT"`.

### 3. Diagnostic logger sidecar — `worker_logger.sh`

Background daemon spawned in `_start_worker_logger` (called from spawn AND revive). Samples every 10s:
- `tmux display-message "#{pane_dead}"` — death detection
- claude.exe PID via pane-pid descendants walk
- claude.exe RSS via `ps -o rss=`
- total system RSS via `ps -axo rss=`
- JSONL last-write age via `stat -f %m`

Output: `src/logs/<worker>_<timestamp>_<event>.log` (event = "spawn" or "revive"), one sample line per 10s.

On detected `pane_dead=1`: `_capture_death` writes a forensic snapshot `<...>_DEATH.txt` containing:
- tmux pane state (`pane_dead_status`, `pane_dead_signal`, `pane_pid`)
- full `ps -axo pid,ppid,user,rss,etime,command | sort -k4 -rn | head -50`
- `vm_stat`
- last 30 lines of `~/.oom-watchdog.log`
- last 30 lines of `/tmp/menubar-abort.log`
- last 20 entries from the worker session JSONL
- last 30 samples of the logger itself

Lifecycle:
- `worker_spawn` → `_start_worker_logger "$name" "$session" "spawn"`
- `worker_revive` → `_start_worker_logger "$name" "$session" "revive"`
- `worker-cli kill` → `_stop_worker_logger` before `tmux kill-session` (otherwise a spurious DEATH snapshot)

PID file `/tmp/worker-logger-<name>.pid`. The logger traps SIGTERM and removes the PID file on cleanup.

Log dir default `$HOME/Documents/ai/Meta/blank/src/logs` (user-specific, override via `WORKER_LOGGER_DIR`).

### 4. Path-encoding bug (commit 231f206)

The first revive implementation used `sed 's|/|-|g'` for the encoded-dir lookup under `~/.claude/projects/`. But Claude Code's encoding additionally replaces `.` and `_` with `-`. Worktree path `.claude/worktrees/eval-sweep` encodes to `--claude-worktrees-eval-sweep`, not `-.claude-worktrees-eval-sweep`. Fix: three shell parameter expansions `${p//\//-}; ${p//\./-}; ${p//_/-}`, matching the `encode_worktree_path` function in `bin/worker-cli`.

## Evidence

- **Smoke test of the new revive logic (2026-05-25 19:48):** worker `eval-sweep` revived after death. claude.exe PID 2022 immediately had `HTTPS_PROXY=http://localhost:8082` set (verified via `ps -E`), worker-specific mitmproxy PID 2013 on port 8082 with the `_worker_eval-sweep` live-addon file visible. State-file lookup for the JSONL returned session ID `5eb09390-f67a-44c3-a707-66f8030eb5c8` correctly. `claude --resume` loaded the context without a cache miss.
- **Logger captured a DEATH event cleanly:** on the second death (2026-05-25 19:31:14), `worker_logger.sh` detected the `pane_dead` 0→1 transition and wrote a death snapshot with the complete process tree + vm_stat + watchdog/menubar logs + JSONL tail. File: `src/logs/eval-sweep_20260525_192702_revive_DEATH.txt`. The snapshot was essential for the subsequent root-cause analysis (RAG project process history, server-stop self-kill bug).

## Consequences

- Reanimation no longer costs the Anthropic cache (the proxy prefix stays stable)
- Worker deaths are documented automatically from now on; the next death diagnosis needs no live debugging
- Code duplication between spawn and revive eliminated (shared helpers)

## Sources

- Diff reviews: commits b48b5bb (main feature), 231f206 (path-encoding fix)
- Cross-project: the death snapshots from this logger were the primary evidence for identifying the RAG project's server-stop self-kill bug
