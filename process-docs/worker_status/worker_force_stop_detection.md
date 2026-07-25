# Worker Force-Stop Detection + Context-% Correctness

**Date:** 2026-06-19 · **Repo:** iterative-dev
**Commits:** `4146375` (window_activity demote) · `db4c2f3` (idle-demoted sentinel + context_pct sum + force-stop suppression)

## Trigger

Monitor_CC's planned kill-while-working guard (a PreToolUse hook that blocks `worker-cli kill` on a `working` worker) is blocked by a status-detection flaw: a worker that hits its context limit or is ESC-interrupted — CC process still alive, `Stop` hook never fired — was reported `working` forever by `worker-cli status`. A guard that blocks killing `working` workers could never kill such a zombie. Fix the detection first.

Two bugs surfaced while reproducing this.

## Bug 1 — false-`working`

### Root cause
`_worker_detect_status` (`src/spawn/tmux_spawn.sh`) returned `hooks.json[session_id].status` VERBATIM — no demote (the comment claimed it mirrored "the menubar's working/idle verbatim"). But the menubar (`Monitor_CC/src/menubar/discover.py:178-181`) does NOT display raw hooks.json — it demotes `working`→`idle` when tmux `#{window_activity}` is stale > `WORKING_THRESHOLD_SECS` (10s). worker-cli skipped that demote, so it diverged from the menubar exactly for stuck workers: `Stop` never fires on ESC/crash/ctx-limit → hooks.json stays `working`; process alive → the `exited` checks don't fire → worker-cli reports `working` indefinitely.

### This was DELIBERATE, not an oversight
`worker_status_hooks_source.md` documents the thin-client redesign: parallel sensors (window_activity demote, JSONL-mtime, a re-implementation of the menubar demote) were removed because they re-derive the menubar logic and drift on any change — a hooks.json app-support-path rename had exposed exactly that. The redesign EXPLICITLY accepted: "a worker stuck at the context limit reads `working` verbatim rather than being heuristically demoted to `idle`." So this is a **decision reversal**, not a regression fix.

### Why reverse it
The kill-guard requirement makes that accepted trade-off unacceptable (un-killable zombie). The reversal is justified because the drift that motivated the thin-client redesign was the hooks.json **path** (now fixed, stable hyphen path) — UNCHANGED by this fix; worker-cli still reads the same path. The re-added demote's only extra signal is tmux `#{window_activity}`, a primitive that cannot rename. Residual drift vector = menubar changes its 10s threshold or signal; mitigated by the in-code cross-reference comment (`Mirrors menubar discover.py:178-181 (WORKING_THRESHOLD_SECS=10)`).

### Why `window_activity`, not JSONL-mtime
window_activity is bumped by CC UI output (spinner frames) → stays fresh through long thinking phases → no false-idle. JSONL-mtime goes stale within 10s of turn-start during thinking → that is why the earlier mtime-demote was removed. window_activity goes stale only when the session truly stops producing output.

### Live evidence — `status-demo` (ESC-interrupted, full context, claude alive)
- hooks.json status = `working` (stale); jsonl age 340s→975s; `#{window_activity}` age 384s→975s (≫10s); claude PID alive under pane.
- Pre-fix: `worker-cli status status-demo` → `working`; menubar → idle (diverged).
- Fixed `_worker_detect_status` (sourced directly against the live session) → `idle`; post-publish via the deployed CLI → `idle`. ✓

## Bug 2 — context-% wrong (`100%` on early-stopped worker)

### Root cause
`context_pct` (`bin/worker-cli`) computed context-used as ONLY `cache_read_input_tokens` of the last usage entry. On turn 1 the input lives in `cache_creation_input_tokens` (nothing cached to read back yet) → cache_read=0 → `pct = 100*(170000-0)/170000 = 100%`. Live: `status-demo` usage = `{input_tokens:3, cache_read:0, cache_creation:19452}` → ~19.5k real tokens, displayed 100%. A multi-turn worker has cache_read populated (~37k) → realistic %.

**Important distinction:** the `100%` is the EARLY-stop artifact (cache_read≈0). A TRUE context-limit worker has a very high cache_read in its last request → `pct ≈ 0%`, never 100%. So "ESC and context-limit both show 100%" is false — only the early/low-cache_read case shows 100%.

### Fix
context-used = `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` (the total input of the last request = true occupied context). jq filter broadened from `select(.message.usage.cache_read_input_tokens? != null)` to `select(.message.usage != null)` (catches entries that have only cache_creation). `// 0` per field; null-guard on empty array → `—%`. `status-demo` → 88% (correct).

## Force-stop suppression (UX decision)

Requirement: a forcefully-stopped worker shows just `idle`, NO % (it will be killed/revived; the number is noise). A genuinely-working or normal-idle worker keeps the %. The force-stop signal = the demote condition itself (raw hook `working` + stale activity); a normal-idle worker has raw hook `idle`.

### Design: sentinel `idle-demoted` (chosen over a shared helper)
`_worker_detect_status` returns `idle-demoted` for the force-stop case — the condition is evaluated ONCE and encoded in the return value. Display callers (`worker_status`, `worker_list`) normalize `idle-demoted`→`idle`. `context_pct` — which already calls `_worker_detect_status` — reads the sentinel raw and returns `""` to suppress the %.

**Rejected:** a shared `_is_force_stopped` helper — it would add a 2nd tmux + hooks.json round-trip inside `context_pct`; the sentinel reuses the call `context_pct` already makes. Single source of truth preserved (the demote condition lives only in `_worker_detect_status`).

**Call graph verified:** `_worker_detect_status` has exactly 3 callers — `context_pct` (reads the sentinel), `worker_status` + `worker_list` (normalize). No leak to any consumer expecting the 4-value `working`/`idle`/`exited`/`unknown` vocabulary; the public `worker-cli status` output is always normalized.

### Display classes (post-fix)
| Case | `_worker_detect_status` | `context_pct` | display |
|---|---|---|---|
| genuinely working | `working` | `X%` | `working X%` |
| normal idle (Stop fired) | `idle` | `X%` | `idle X%` |
| force-stopped (demoted) | `idle-demoted` | `""` | `idle` |
| exited / unknown | `exited`/`unknown` | `—%` | `exited —%` |

Display sites use `${PCT:+ $PCT}` so an empty % adds no trailing space.

### Live verification (post-publish)
- `status-demo` (force-stop) → `idle` (no %). ✓
- `status-fix` (normal idle) → `idle 59%` (with %). ✓
- genuinely-working-first-turn % (working path) → code/formula-verified only (same `context_pct` path; sum math checked against status-demo data 19455→88%), not live-tested.

## Consequence
The kill-while-working guard is unblocked: it parses public `worker-cli status` → sees `idle` for a stopped zombie → can kill it. This reverses the earlier thin-client/no-demote decision (its accepted trade-off documented in this area); the earlier `context_pct` dead-worker fix (100% on dead workers) is untouched — its `—%` guards remain intact.
