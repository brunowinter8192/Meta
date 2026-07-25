# worker-cli status — Thin-Client of menubar hooks.json

## Problem

`worker-cli status <name>` returned `unknown` (and `context_pct` returned `—%`) for
EVERY worker, regardless of real state. The status machinery lives entirely in
`src/spawn/tmux_spawn.sh` (`_worker_detect_status`, `worker_status`, `worker_list`).

## Root cause — path divergence + set -e crash

Two compounding faults, both in `tmux_spawn.sh`:

1. **App-support dir rename, not propagated.** The Monitor_CC menubar renamed its
   application-support directory bundle-id from `com.brunowinter.monitor_cc_menubar`
   (underscores) to `com.brunowinter.monitor-cc-menubar` (hyphens) and added a
   migration in its `paths.py`. `tmux_spawn.sh` still hardcoded the OLD underscore path
   in TWO places: line 178 (`hooks.json` status read) and line 18
   (`_ORCHESTRATOR_SIGNALS_FILE`, the auto-abort signal-grace WRITE target). The status
   read targeted a non-existent file; the menubar reads signals from the new path, so
   worker-cli's signal writes also went unseen — the auto-abort signal-grace was
   silently dead too. One rename broke two cross-repo couplings.

2. **`set -e` turned "file missing" into a crash.** `tmux_spawn.sh` runs under
   `set -euo pipefail`. Line 179 was a BARE assignment `hook_status=$(jq … "$hook_file"
   2>/dev/null)` — no `local`, no `|| true`. `jq` on a missing file exits 2 (the
   `2>/dev/null` hides stderr, not the exit code). Under `set -e`, a bare assignment
   whose command-substitution fails aborts the subshell IMMEDIATELY — before the
   line-180 fallback (`[ -z "$hook_status" ]`) could run. The `worker-cli` wrapper
   catches the non-zero exit with `|| echo "unknown"`. So missing-file → crash →
   `unknown`. (The `ls … *.jsonl | head` pipe on line 171 had the same latent fault
   under `pipefail`.)

## Decision — thin client, no fallback chains

The status logic had accreted parallel sensors (tmux `window_activity` demote, JSONL
mtime, a re-implementation of the menubar's own demote rule). These were nominally
"the same source as the menubar" but were independent re-derivations that drift apart
on any change — exactly what the path rename exposed.

Redesign: `worker-cli` is a THIN CLIENT of the menubar's activity-status file. Single
source, no heuristic layers.

- **`working` / `idle`** — `hooks.json[session_id].status` returned VERBATIM. No demote,
  no `window_activity`, no JSONL-mtime. The menubar's CC lifecycle hooks
  (`UserPromptSubmit`→working, `Stop`/`StopFailure`→idle) are the authority.
- **`exited`** — kept as a LOCAL, orthogonal process-liveness check (`pane_dead=1`, no
  child PIDs, no `claude` descendant). This is a fact not present in `hooks.json` and the
  revive/successor flow needs it. Not a fallback — an independent signal.
- **`unknown`** — honest verdict: hooks.json missing, no entry for session_id, no JSONL
  yet, or pane unreadable. Means "the menubar tells me nothing about this session" —
  one precise, debuggable meaning. NO guessed `idle` default.

Accepted trade-off: a worker stuck at the context limit (CC alive, `Stop` hook never
fired) reads `working` verbatim rather than being heuristically demoted to `idle`. That
is the truthful reflection of the hook state; a genuine process death is still caught
by the `exited` checks.

> **SUPERSEDED (2026-06-19):** this accepted trade-off was reversed. The kill-while-working
> guard requires forcefully-stopped workers to resolve to idle (an un-killable `working`
> zombie is worse than the drift). A `#{window_activity}` demote was re-added (rename-proof
> signal; the hooks.json path that caused the original drift is unchanged).

### unknown is a verdict, not an error (return 0)

All `unknown` paths originally did `echo "unknown"; return 1`. Combined with the
wrapper's `… || echo "unknown"` capture, the non-zero exit fired the `|| echo` ON TOP of
the already-printed verdict → `STATUS="unknown\nunknown"` (two lines). This broke
`context_pct`'s `[ "$status" = "unknown" ]` check (multiline mismatch → could read a
wrong %). Fix: all status paths return exit 0 (the echo IS the verdict, consistent with
`exited`/`working`/`idle`). The wrapper's `|| echo "unknown"` now only fires on genuine
crashes — a real safety net, not a duplicate.

## Path is a cross-repo contract

The lasting fragility is the hardcoded app-support path duplicated across two repos
(Monitor_CC menubar writes it, iterative-dev worker-cli reads it). The fix points both
`tmux_spawn.sh` references at the live hyphen path; that path must be treated as a frozen
contract — a future rename requires updating both sides together.

## Scope note

The activity-`hooks.json` consumed here is unrelated to Monitor_CC's `src/hooks/`
tool-safety hooks: the former is the CC-lifecycle activity state file, the latter a
safety fire log — two separate hook families.

## Live verification (post-publish)

`worker-cli status status-fix` → `idle 68%` (was `unknown —%`). `worker-cli status --all`
single-line clean output. Cache (`plugin-publish`-synced) has 2 hyphen-path refs, 0
underscore refs.
