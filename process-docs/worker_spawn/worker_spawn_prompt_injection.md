# worker_spawn_prompt_injection — Prompt via Paste Instead of Cmdline Arg

**Date**: 2026-05-30
**Branch**: infra
**Commit**: 2a024e0
**Files changed**: `src/spawn/tmux_spawn.sh`

---

## Problem

`spawn_claude_worker` passed the prompt as a positional argument to claude
(runner line in the heredoc):

```bash
${worker_claude_bin} --model '${model}' ${extra_flags} "$(cat '${prompt_file}')"
```

The full prompt text thus sat in the claude process's command line —
visible via `ps aux`, `pgrep -fa`, and any tool that scans process
cmdlines for substrings. Real-world consequence: 2 workers were killed at
startup because their prompt text happened to contain a cleanup match
string.

---

## Rejected approach: JSONL poll as readiness gate

**Idea**: after spawn, wait until a new JSONL file appears in
`~/.claude/projects/<encoded-worktree>/` — CC writes a `system` record at
session start, before the prompt appears.

**Why dead-end**: the assumption was wrong. CC writes **no JSONL before
the first user prompt**. A session officially begins with the first
prompt — nothing happens internally before that. A JSONL poll gate would
deadlock:

```
Gate waits for JSONL
→ JSONL needs the prompt
→ prompt waits for the gate
→ 30s timeout → NO worker ever gets its prompt
```

Empirically confirmed (probes 1–3): no JSONL after 8s in fresh and
established project dirs as long as no user input occurred.
User-authoritatively confirmed.

---

## Empirical probe findings

### Readiness marker

`tmux capture-pane -p` in the input-ready state shows:
```
❯ 
```
Bytes: `e2 9d af` (U+276F, HEAVY RIGHT-POINTING ANGLE QUOTATION MARK) +
`c2 a0` (U+00A0, NO-BREAK SPACE) + `0a` (newline).

The line starts at column 0 with `❯`. `grep -q '^❯'` matches reliably.

**Distinguishing the trust dialog**: the workspace-trust dialog shows
` ❯ 1. Yes, I trust this folder` with a leading space — no match on `^❯`.

### Trust-dialog behavior

- **Fresh/unknown dirs** (e.g. `/tmp/...`): trust dialog appears
  **even** with `--dangerously-skip-permissions` (the flag suppresses
  tool-permission prompts, not the workspace-trust dialog).
- **Established project dirs** (known git repos): no dialog — straight to
  the `❯` prompt after ~3-4s boot time.
- **Worker spawns** (`$project_path` = existing repo root):
  established, no dialog expected. Confirmed by a clean spawn.

### Early-paste queueing

Bytes pasted into the pane BEFORE the `❯` state are held by the terminal
buffer and delivered when CC is ready. Measured: paste at T=0.1s, text
appears in the CC input box at T~4s as `❯ echo QUEUE_TEST`. The pane gate
is thus not a hard delivery blocker for the happy path — but it ensures
Enter is only sent once CC interprets the text as a prompt.

---

## Fix

### 1. Runner — remove the prompt arg

```bash
# Before (line 545):
${worker_claude_bin} --model '${model}' ${extra_flags} "$(cat '${prompt_file}')"

# After:
${worker_claude_bin} --model '${model}' ${extra_flags}
```

### 2. Readiness gate (`^❯` poll)

```bash
_pane_id=$(tmux list-panes -t "$session" -F "#{pane_id}" | head -1)
_deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$_deadline" ]; do
    tmux capture-pane -p -t "$_pane_id" 2>/dev/null | grep -q '^❯' && break
    sleep 0.3
done
if ! tmux capture-pane -p -t "$_pane_id" 2>/dev/null | grep -q '^❯'; then
    echo "spawn_claude_worker: CC did not reach input-ready state within 30s" >&2
    rm -f "$prompt_file"
    return 1
fi
```

The trust dialog does not match `^❯` → the gate runs into timeout →
explicit `return 1` instead of silently injecting into the dialog.

### 3. Prompt inject (identical to worker_send)

```bash
printf '%s' "$task_prompt" | tmux load-buffer -
tmux paste-buffer -d -t "$_pane_id"
sleep 0.2
tmux send-keys -t "$_pane_id" Enter
rm -f "$prompt_file"
```

`prompt_file` is cleaned up both on success (after inject) and on gate
timeout (`return 1`).

### Position in the spawn flow

Gate + inject after `open_tmux_viewer "$session" ... &` (the Ghostty
launch runs in the background parallel to gate polling), before
`echo "$session"`. `_orchestrator_signal_update` stays at line 558 —
covers the menubar grace phase during boot + gate wait.

`spawn_claude_worker_from_file` is not directly changed — it reads the
file into `$task_prompt` and calls `spawn_claude_worker`; the fix applies
automatically.

---

## Known fragility

**The `^❯` marker is CC-version-dependent.** The glyph U+276F is used in
the CC TUI as the input prompt — not guaranteed by any stable API. If a
CC version changes this glyph:
- gate timeout after 30s
- `return 1` → explicit spawn fail (never silent failure)
- remedy: adjust `grep -q '^❯'` in `tmux_spawn.sh` to the new marker
