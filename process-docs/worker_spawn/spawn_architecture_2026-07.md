# Worker Spawning — Architecture Snapshot

*Snapshot as of 2026-07 — historical process record; the live current state is the source code (`src/spawn/`, `bin/worker-cli`), not this file.*

## Architecture as of 2026-07

One tmux session per worker, named `worker-<project>-<name>`. Project-scoped — workers from different projects never collide.

**Spawning:**
- `spawn_claude_worker()` — creates tmux session with direct command arg (no shell-ready polling), writes prompt to temp file, launches `claude-patched --model <model>` with prompt from file
- `spawn_claude_worker_from_file()` — same but reads prompt from existing file
- Default model: `claude-sonnet-5` (Sonnet 5, native 1M context, no beta header / env var needed — model name alone selects it) — set in `spawn.py` argparse default, both `tmux_spawn.sh` shell defaults, and the `worker_revive` fallback. `opus` remains selectable via the `model` arg/param at every call site; `spawn.py`'s argparse carries no `choices=` allowlist — the value passes straight through to `claude --model '<model>'`.
- Direct command execution: command passed as arg to `tmux new-session` — env vars inherited automatically
- `remain-on-exit on` set atomically via `;` chain — pane stays open after process exit for status detection
- `history-limit 50000` set at spawn and revive — ensures the prompt anchor (`❯ <non-whitespace>`) stays in scrollback even after a long worker turn
- After Claude exits: `touch /tmp/worker-<name>.done` (semicolon-chained, fires even on crash)

**Viewer:**
- `open_tmux_viewer()` — opens Ghostty window attached to worker's tmux session
- Ghostty 1.3+: native AppleScript API (`new window`, `input text`, `send key`)
- Ghostty 1.2.x: fallback via `open -na` with `--quit-after-last-window-closed` and `--window-save-state=never`

**Orchestration:**
- `worker_list()` — lists active workers with status (working/idle/limit reached/unknown) for current project
- `worker_status()` — returns status of a single worker (working/idle/limit reached/unknown); reads Monitor_CC menubar's `hooks.json` + detects force-stops via `#{window_activity}` stale > 10s
- `worker_capture()` — captures raw pane to `/tmp/worker-<name>-pane.txt`; legacy / `--raw` fallback
- `worker_capture_clean()` — scoped+cleaned capture: slices to output since last real `❯` prompt, applies clean filter (strip: boot box, spinners, diff body, widget chrome; keep: tool headers, counters, prose, Bash output); prints to stdout. Default for `worker-cli capture`.
- `worker_send()` — sends text input to worker's Claude session (tmux send-keys + Enter)

**Cross-project worktree tracking (`bin/worker-cli`):**
Registry dir: `${WORKER_REGISTRY_DIR:-$HOME/.claude/.worker-registry}` — env-overridable (test isolation).
- `worker-cli worktree <name> <target-repo> [branch]` — creates `.claude/worktrees/<name>` in target repo on `<branch>` (default `<name>`); validates target is a git repo and worktree doesn't already exist (fails non-zero); appends `<target-repo>\t<branch>` to `$REGISTRY_DIR/<name>.worktrees` (sidecar); echoes the absolute worktree path.
- `worker-cli kill <name>` (extended) — after spawn-side cleanup, reads `$REGISTRY_DIR/<name>.worktrees` line-by-line; for each entry: `git worktree remove --force` + `git branch -D` in the target repo (both best-effort: `2>/dev/null || echo not-found`); deletes the sidecar file. `registry_delete` always executes regardless of sidecar results.
- `worker-cli worktree-rm <target-repo> <name> [branch]` — removes cross-project worktree + branch directly (best-effort); for orphans predating sidecar registration.
- `list` / `status --all` — skip `*.worktrees` files in registry dir loop; only plain-name files are treated as worker entries.

Sidecar format: `$REGISTRY_DIR/<name>.worktrees`, one `<abs-target-path>\t<branch>` per line (tab-separated). Multiple cross-project worktrees for one worker = multiple lines.

**`worker-cli capture`:** defaults to `worker_capture_clean` (clean+scoped output to stdout). `--raw` falls back to `worker_capture` (raw pane to file, prints path). Implemented in `_capture_clean.py` (`src/spawn/`), called from `worker_capture_clean()` in `tmux_spawn.sh`.

**Status detection:**
Single authoritative source: `~/Library/Application Support/com.brunowinter.monitor-cc-menubar/hooks.json`.
Schema: `{ "<session_id>": { "status": "working"|"idle", ... } }` — written by Monitor_CC lifecycle hooks.
`_worker_detect_status` logic:
- **limit reached** — local process checks: `pane_dead=1`, OR no child PIDs under pane PID, OR no `claude` descendant (process gone: context-limit death, crash, quit); OR hook status `working` BUT `#{window_activity}` stale (> 10s) — forcefully stopped (ESC / crash / context-limit with alive process). Mirrors Monitor_CC menubar `discover.py:178-181`.
- **working** — hook status `working` AND tmux `#{window_activity}` fresh (≤ 10s)
- **idle** — hook status `idle` (Stop hook fired — normal finish)
- **unknown** — honest: hooks.json missing, no entry for session_id, no JSONL yet, or pane unreadable
Fail-open: `#{window_activity}` unreadable → no demote (status stays `working`). All paths return exit 0 (verdict, not error).

**Signal:**
- `.done` file written on Claude exit for manual checking (`ls /tmp/worker-*.done`)
- No automatic notification to parent session (PostToolUse hook removed — overhead without value)

**Communication — Main → Worker:**
- Main spawns the worker with a task prompt (CLI argument or prompt file)
- `worker_send()` can send text to a running worker (tmux send-keys)
- Works ONLY when the worker is waiting for user input (Claude Code idle)
- Constraint: tmux send-keys sends keystrokes; Claude Code recognizes them as user input — works in practice

**Communication — Worker → Main: NOT POSSIBLE (as of 2026-07):**
- No mechanism to programmatically tell the parent agent that the worker is done
- The `.done` file exists, but there is no automatic consumer in the parent
- The PostToolUse hook (worker-done-check.sh) was removed — overhead on every tool call without benefit
- `claude inject` (anthropics/claude-code#24947) would solve this: programmatic input to a running session. OPEN at the time, high-priority, no implementation timeline.
- Programmatic Input Submission (#15553) confirmed: Claude Code ignores programmatic stdin as submit
- Community consensus (Reddit, GitHub) at the time: nobody had a working workaround; everyone was waiting for `claude inject`.

**Dev-branch workflow:**
- Opus works on `dev` branch during IMPLEMENT. Workers branch from `dev` (worktrees at `.claude/worktrees/<name>/`).
- `worker_merge` merges worker branch into whatever branch is currently checked out (dynamic via `git rev-parse --abbrev-ref HEAD`). No hardcoded `main`.
- Opus reviews on `dev` — shared-rules use `.claude/worktrees/**` paths, so reading files on `dev` (normal project path) does NOT trigger execution rules.
- Session end: `dev_sync` MCP tool updates main/master ref to dev HEAD via `git update-ref` (no checkout needed).

**`claude-patched` (MANDATORY):**
- Workers ALWAYS use `claude-patched` instead of `claude`. The patch fixes cache behavior (Cache Read instead of Cache Create per turn), preventing massive usage spikes.

**Files:** `src/spawn/tmux_spawn.sh` (785 LOC at snapshot time), `src/spawn/_capture_clean.py` (153 LOC)

## Open questions at snapshot time

- `claude inject` timeline: the issue was high-priority but without ETA.

## Evidence

- Live repro 2026-06-19 (`status-demo`, ESC-interrupted, full context, claude alive): hooks.json=`working`, `#{window_activity}` age 384s→975s (≫10s) → pre-fix `worker-cli status` = `working`, menubar = `idle` (diverged); post-fix = `limit reached`.
- agent-of-empires: shell-ready pattern + status detection
- cmux: community validation of the tmux+worktree pattern
- recon: tmux-native status monitoring
- claude-tmux: capture-pane status detection
- #24947, #15553: upstream blockers for Worker→Main
