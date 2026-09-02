# dev/worker_status/

## Role

Tests for worker status detection (`_worker_detect_status` in `src/spawn/tmux_spawn.sh`).

## Modules

### test_status_detection.sh

**Purpose:** Verify tmux `#{pane_dead}` transitions from 0→1 after process exits (remain-on-exit mode).
**Usage:** `bash dev/worker_status/test_status_detection.sh`

### test_worker_status.sh

**Purpose:** Integration coverage for the closed three-value status vocabulary
(`working`/`idle`/`dead`, 2026-09-02) that replaced `working`/`idle`/`"limit reached"`/
`unknown`. Exercises the real `_worker_detect_status` (and `worker_status`, for the
missing-session case) against real throwaway tmux sessions + a scoped `hooks.json` entry
(backed up/restored around the run, never left dirty). Fixture style copied from
`dev/worker_wait/test_worker_wait.sh` (`create_worker` idle/working/bg/chatty modes,
`go_quiet`, `kill_claude_child`, `delete_hook_entry`) — standalone copy, not an import.

Covers: `idle` from a verbatim hooks.json `idle` entry regardless of pane activity;
`working` from hook `working` with fresh (chatty) activity; the ESC-interrupt case —
hook `working` but the pane quiet > 10s — now reads as `idle` (was `"limit reached"`);
the same 10s demote rule applied to the two former `unknown` paths (no hook entry at all,
with chatty vs. quiet pane) and to a genuinely fresh spawn with no JSONL file yet at all
(`working`, the honest default); `dead` from a killed claude child (session/pane stay
alive via `remain-on-exit`), from `#{pane_dead}=1` directly, from a killed tmux SESSION
(via `worker_status`, which gates on `tmux has-session` itself before ever calling
`_worker_detect_status`), and from the session JSONL's last assistant-type entry being
Claude Code's client-side context-limit marker (`message.model=="<synthetic>"` + text
`Prompt is too long` + `isApiErrorMessage=true` + `error="invalid_request"` —
anthropics/claude-code #90113, #23377) even when hooks.json still says `idle` (dead
signals are checked before hook_status, so they take precedence). A companion case
writes an ORDINARY aborted assistant message (real model, no marker fields) to prove the
context-limit guard never false-positives on a plain ESC-interrupted turn. A final grep
assertion checks the retired strings `limit reached` and `echo "unknown"` no longer occur
anywhere in `tmux_spawn.sh`.

**JSONL marker fixture:** `write_synthetic_marker_jsonl`/`write_normal_assistant_jsonl`
overwrite the JSONL `create_worker` already touched empty, using `jq -n` to build the
JSON safely (no shell-quoting of the message text). `jsonl_path` derives the same
`~/.claude/projects/<encoded>/<session_id>.jsonl` path `_worker_detect_status` itself
resolves from `#{pane_current_path}`.

**Usage:** `bash dev/worker_status/test_worker_status.sh` (~1min; spins up/tears down
throwaway tmux sessions under `worker-<basename>-<name>`). Run it ONCE at a time — like
the wait suite, concurrent invocations race on the same real `hooks.json` backup/restore
cycle.
