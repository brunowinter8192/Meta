# src/spawn/

## Role

Worker spawning and orchestration — tmux sessions, git worktrees, Ghostty viewers, proxy injection. Touch this package when changing how workers are spawned, how worktrees are set up, or how the proxy is injected into worker environments.

## Public Interface

Sourced by `~/.local/bin/worker-cli` (all subcommands):
- `tmux_spawn.sh` — bash library for worker lifecycle ops

Invoked via `python3 -m src.spawn.spawn` by `worker-cli spawn`:
- `spawn.py` — worktree setup + tmux session launch (stdlib only)

## Modules

### tmux_spawn.sh (814 LOC)

**Purpose:** Bash library — worker lifecycle: spawn, list, status, capture, send. Handles proxy injection for Monitor_CC sessions automatically when `/tmp/.monitor_cc_proxy_*` marker exists. **Worker model resolution (2026-08, model-selector milestone 3):** `_resolve_worker_model()` — returns the `"worker"` key from `~/.claude/shared-rules/model_selection.json` (env-overridable via `MODEL_SELECTION_FILE`, for tests) if present and non-empty, else the hardcoded fallback `claude-sonnet-5`; uses `jq` with the same `2>/dev/null || true` fail-open idiom already established at the `hooks.json` read in `_worker_detect_status` (this file runs under `set -euo pipefail`). Used as the default in `spawn_claude_worker`'s and `spawn_claude_worker_from_file`'s `${4:-$(_resolve_worker_model)}` (bash short-circuits — never called when an explicit 4th arg is given), and in `worker_revive`'s fallback (`[ -z "$model" ] && model="$(_resolve_worker_model)"`) — revive's own stored `WORKER_MODEL` (the model the worker was ORIGINALLY spawned with) always wins over this; the config only applies when that stored value is itself absent. **Not exercised for `worker-cli spawn`:** `spawn.py` resolves the model in Python before ever calling into this file, so a `worker-cli spawn <name> <prompt> <path>` call never reaches this function — see `spawn.py`'s entry below, and note the further upstream finding in `process-docs/model_selector/` about `bin/worker-cli`'s own pre-existing hardcoded default.
**Reads:** tmux session list, proxy marker `/tmp/.monitor_cc_proxy_<session_id>`, project path, `~/Library/Application Support/com.brunowinter.monitor-cc-menubar/hooks.json` (working/idle source), `~/.claude/shared-rules/model_selection.json` (worker model fallback).
**Writes:** tmux sessions, Ghostty windows, worker mitmproxy processes, `/tmp/worker-<name>.done` signal file.
**Called by:** `~/.local/bin/worker-cli` (all subcommands via `source`); `spawn.py` (via subprocess for `spawn_claude_worker_from_file`).
**Calls out:** tmux, osascript/Ghostty, mitmdump, `~/.local/bin/claude-223`, `jq`.

`worker_capture_clean NAME [PROJECT_PATH]` — captures pane, scopes to output since last real orchestrator `❯` prompt, applies clean filter (see `_capture_clean.py`), prints to stdout. Called by `worker-cli capture` (default). `worker_capture` (raw pane to file) called via `worker-cli capture --raw`.

**Status detection (`_worker_detect_status`):** `limit reached` from local pane/process checks (`pane_dead=1`, no child PIDs, no `claude` descendant) OR hook_status=`working` with `#{window_activity}` stale > 10s (forcefully-stopped: ESC/crash/ctx-limit) — mirrors menubar `discover.py:178-181`; `idle` from `hooks.json[session_id].status` (Stop hook fired); `working` from hooks (activity fresh ≤ 10s); `unknown` if no authoritative data. Fail-open: window_activity unreadable → no demote. All paths return exit 0. See `process-docs/worker_status/worker_force_stop_detection.md`.

**spawn_claude_worker — Prompt-Inject Flow:**
claude starts bare (no positional prompt arg — prompt never touches the cmdline).
After session creation, a readiness gate polls `tmux capture-pane` for `^❯`
(U+276F at col 0 = CC input-ready). 30s deadline; timeout → `return 1`.
Prompt is injected via `load-buffer / paste-buffer / send-keys Enter` (same
as `worker_send`). Fragility: `^❯` marker is CC-version-dependent — if the
glyph changes, gate times out and spawn fails explicitly; update the grep
pattern. See `process-docs/worker_spawn/worker_spawn_prompt_injection.md`.

### _capture_clean.py (153 LOC)

**Purpose:** Scope + clean worker pane output. Takes `<pane_file> <worker_name>`, prints `=== capture from <name> (since last prompt, N chars) ===` + cleaned body to stdout.
**Reads:** raw tmux pane file (arg); searches backward for last `❯ <non-whitespace>` prompt anchor.
**Writes:** stdout only.
**Called by:** `worker_capture_clean()` in `tmux_spawn.sh` (via `python3 _capture_clean.py`).
**Calls out:** nothing (stdlib only).

Scope: slices to lines after the last real orchestrator prompt (`_RE_REAL_PROMPT = r'^❯\s+\S'`); pre-trims bottom widget (rule/bare-❯/Sonnet footer/bypass) so the bare input box never wins the anchor. Fallback: full buffer + `⚠` warning when no prompt in scrollback.

Clean filter — **Strip:** boot welcome box (`╭…╰`), thinking spinners (`✻`), `ctrl+o to expand` collapse markers, CC diff body lines (indented `<linenum>[+/-]content` after `Update()`/`Create()` headers — counter `⎿ Added N` kept, body dropped), bottom widget chrome (rule/bare-❯/Sonnet/bypass). **Keep:** `Update()`/`Create()` headers, `Added N, removed M` counters, `Read()`/`Bash()` headers, prose, Bash output, checklists. Leading `⏺`/`⎿` glyphs stripped from lines where they are the first character.

---

### spawn.py (138 LOC)

**Purpose:** Worktree setup + worker session launch. Stdlib only — no fastmcp, no external deps. **Worker model resolution (2026-08, model-selector milestone 3):** the `model` CLI positional's argparse default changed from the hardcoded literal `"claude-sonnet-5"` to `None`, so `args.model` can be told apart from "not given" instead of colliding with a real value; `resolved_model = args.model or _resolve_worker_model()` — `_resolve_worker_model()` reads the `"worker"` key from `~/.claude/shared-rules/model_selection.json` (`MODEL_SELECTION_FILE`, env-overridable for tests), falling back to the hardcoded `"claude-sonnet-5"` on any error or a missing/empty key; never raises. `resolved_model` (always a concrete non-empty string, never the literal string `"None"`) is what actually reaches `spawn_workflow`/`tmux_spawn`. **Not load-bearing for `worker-cli spawn` today:** `bin/worker-cli`'s own `spawn)` case pre-resolves its 4th positional (`MODEL="${4:-claude-sonnet-5}"`) BEFORE ever invoking this module, so `args.model` is never actually `None` on that path and `_resolve_worker_model()` is never reached that way — this module's own resolution is exercised only by a caller of `python3 -m src.spawn.spawn` that omits the model argument directly (bypassing `bin/worker-cli`). See `process-docs/model_selector/` (cross-repo area, monitor-cc) for the full trace and the follow-up question of whether `bin/worker-cli` itself should be updated.
**Reads:** prompt file, project dir (`.claude/settings.local.json`, `venv/`), `~/.claude/shared-rules/model_selection.json` (worker model fallback, only when no CLI model argument is given).
**Writes:** git worktree at `.claude/worktrees/<name>`, copies `settings.local.json`, symlinks `venv/`, then calls `spawn_claude_worker_from_file` via bash subprocess.
**Called by:** `~/.local/bin/worker-cli spawn` (via `cd "$PLUGIN" && python3 -m src.spawn.spawn`).
**Calls out:** git (via subprocess), bash + tmux_spawn.sh (via subprocess).

## Usage

```bash
# Via worker-cli (standard)
worker-cli spawn <name> <prompt_file> <project_path> [model] [--no-worktree]

# Direct (from plugin root)
python3 -m src.spawn.spawn <name> <prompt_file> <project_path> [model] [--no-worktree]
```

### Cross-project Lifecycle

When a worker needs to operate in a DIFFERENT repo from the one it was spawned into:

```bash
# 1. Spawn worker in the spawn project (creates spawn-side worktree + registry entry)
worker-cli spawn <name> <prompt_file> <spawn-project> [model]

# 2. Create + register a worktree in the target project (default branch = <name>)
worker-cli worktree <name> <target-repo> [branch]
# → creates <target-repo>/.claude/worktrees/<name> on branch <name>
# → appends "<target-repo>\t<branch>" to $REGISTRY_DIR/<name>.worktrees (sidecar)
# → echoes the absolute worktree path for use in the worker prompt

# 3. Worker does its work in the target worktree (path echoed above)

# 4. Kill cleans BOTH sides (spawn-side + all entries in the sidecar)
worker-cli kill <name>
```

**Sidecar format:** `$REGISTRY_DIR/<name>.worktrees` — one `<target-repo>\t<branch>` per line (tab-separated). Multiple cross-project worktrees for the same worker are each on their own line. `kill` reads and deletes this file automatically; `list`/`status --all` skip `*.worktrees` files so they are never treated as worker names.

**Orphan cleanup** (worktrees that predate registration — no sidecar exists):
```bash
worker-cli worktree-rm <target-repo> <name> [branch]
# → removes <target-repo>/.claude/worktrees/<name> + deletes branch (best-effort)
# → no registry/sidecar involvement
```

## Gotchas

- `spawn.py` derives `PLUGIN_DIR` from `__file__` — call `python3 -m` from any cwd, `TMUX_SPAWN_SH` resolves correctly.
- `worker-cli spawn` converts relative paths to absolute before `cd "$PLUGIN"` to avoid path drift.
- Proxy injection: `spawn_claude_worker` reads `/tmp/.monitor_cc_proxy_<md5(project_path)>`. If marker absent → worker spawns without proxy (silent, no error).
