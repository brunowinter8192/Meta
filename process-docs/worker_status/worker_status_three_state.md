# Worker Status — Three-State Simplification

The worker status surface carried (a) a context-remaining percentage and (b) a 5-token internal state machine whose `idle-demoted` token was opaque. Both removed/collapsed: an orchestrator only needs to know whether a worker is **working**, **waiting**, or **done/gone**.

## Decision

Remove the context-% feature entirely. Collapse displayed worker status to three states + one transient fallback.

Why:
- The percentage was pseudo-precision the orchestrator (Opus) cannot meaningfully act on — it led to spurious statements like "Worker bei 55% — reicht für Stage 4". Opus has no reliable way to assess a worker's remaining context; the number invited false decisions.
- The internal token `idle-demoted` was meaningless to readers ("nobody knows what it means").

## State mapping

| Old internal token | Detection source | New display |
|---|---|---|
| `working` | hook=working + activity fresh ≤10s | `working` |
| `idle` | hook=idle (Stop hook fired, normal finish) | `idle` |
| `idle-demoted` | hook=working + `window_activity` stale >10s (ESC / ctx-limit, CC alive) | `limit reached` |
| `exited` | `pane_dead` / no children / no `claude` descendant (ctx-death / crash / quit) | `limit reached` |
| `unknown` | no JSONL / no hook entry yet | `unknown` (transient) |

Rule: anything forcefully/abnormally stopped — process alive-but-interrupted OR process gone — collapses into the single state `limit reached`. The orchestrator reacts uniformly: capture the pane → decide (re-`send` vs spawn successor). The alive-vs-dead distinction is resolved by the capture, not by the status. ESC-interrupt is technically not a context limit, but it is rare in this workflow and the orchestrator's reaction is identical — no separate label warranted.

`unknown` retained as the honest "no data yet" fallback during spawn-init; it is NOT one of the three decision states.

## Detection logic unchanged

The `pane_dead` / process-tree / `window_activity` (>10s) checks in `_worker_detect_status` are correct and stay. Only the RETURNED token and its display changed (`idle-demoted`/`exited` → `limit reached`; internal representation is the literal string `limit reached`, safe because all comparison sites are quoted). The kill-while-working guard rationale is preserved and improved: a force-stopped worker no longer masquerades as `idle` (the original confusion) — it surfaces as `limit reached`, which is clearly actionable / killable.

## Superseded — context_pct (removed)

Preserved for attribution. Former `bin/worker-cli:context_pct`:
- context-used = `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` (last usage entry; summed because cache_read-only undercounted turn-1 where input sits in cache_creation → false 100%).
- `pct = 100 * (170000 - used) / 170000`, clamped ≥ 0.
- 170k baseline = empirical Sonnet death-zone (CC aborts when cache-read approaches ~170k, below the advertised 200k) — observed across multiple workers.
- Output: `—%` for exited/unknown/no-usage; empty (suppressed) for `idle-demoted`; `<pct>%` otherwise.

The whole function + its 4 call sites + the `usage()` help text ("context remaining %") removed. No percentage is emitted anywhere.

## Rules impact (shared-rules)

`opus/workers-1.md`, `workers-2.md`, `workers-3.md` stripped of every context-% / context-budget reference ("Low context (any remaining %)", "regardless of context %", "Y% Context", "Context-% visibility", "context blowout", "burn the worker through its context"). Replaced by strict what/how: a worker may die at its limit → status shows `limit reached` → spawn a successor; the reuse-vs-fresh decision is thematic continuity only. `global/tool-use.md` "Context window hygiene" (Opus's OWN output-redirection discipline) is a different concept and was deliberately left untouched.

## Doc surfaces updated at the time

- `src/spawn/DOCS.md` — status-detection description.
