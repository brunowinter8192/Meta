# worker_dead_ctx_detection — Dead Worker Shows 100% Context

**Date**: 2026-05-30
**Branch**: infra
**Commit**: a7ca512
**Files changed**: `bin/worker-cli` (only)

---

## Symptom

`worker-cli list` (no args, registry path) showed dead workers with context
at **100%** instead of `—%`. Observed pattern: worker killed/died → tmux
session gone → registry entry remains → next `list` call shows
`<name>: unknown 100%`.

---

## Root Cause — Path A (reproduced)

`context_pct()` in `bin/worker-cli` had an **optional** guard block:

```bash
local session="worker-$(basename "$project")-$name"
if tmux has-session -t "$session" 2>/dev/null; then
    # _worker_detect_status check …
fi
# fell through to JSONL reading regardless
```

When the tmux session was gone (`has-session` → false), the entire guard
block was skipped. Execution fell through to JSONL reading. If the latest
JSONL had `cache_read_input_tokens = 0` (fresh/new session at time of
death), the formula `(170000 - 0) / 170000 = 100%` was returned.

**Reproduced** with a controlled test: fake JSONL (CR=0) + no tmux session
→ `context_pct` returned `100%`. After fix: returns `—%`.

The registry (`~/.claude/.worker-registry`) does not clean up stale entries
automatically — entries persist after `kill` or manual session removal.
`worker-cli list` (no args) iterates the registry unconditionally, so every
stale entry hit this path.

---

## Fix

Convert `if tmux has-session` from an optional block to a **positive
liveness precondition** — no session → immediate `—%`, never read the JSONL:

```bash
if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "—%"; return
fi
local status
status=$(bash -c "source "$1" && _worker_detect_status "$2"" \
    _ "$SPAWN" "$session" 2>/dev/null || echo "unknown")
if [ "$status" = "exited" ] || [ "$status" = "unknown" ]; then
    echo "—%"; return
fi
```

The `_worker_detect_status` check (exited/unknown) is preserved unchanged
for the second scenario: CC dies inside a still-alive tmux session (zsh
keeps pane alive after claude exits).

`_worker_detect_status` itself was **not changed** — no `src/spawn/DOCS.md`
update needed.

---

## Dead-Worker Path Coverage

| Path | Signal | Status after fix |
|---|---|---|
| **A** tmux session gone (reproduced bug) | `has-session` false | `—%` — fixed |
| **B** Session alive, `pane_dead=1` | `_worker_detect_status` → `exited` | `—%` — already correct |
| **C** Session alive, no claude child | `_worker_detect_status` → `exited` | `—%` — already correct |
| **D** Session alive, zombie/defunct claude | `grep claude` still matches defunct → `has_claude=1` → slips through | Pre-existing limitation |
| **E** Session alive, `pane_pid` empty | Process-tree block skipped → hook status used → may return `idle` | Pre-existing limitation |

Paths D and E are outside this task's scope. Both require process-state
introspection beyond what `pgrep`/`grep` provides (D: distinguish defunct
from live; E: fallback when tmux `pane_pid` query fails).
