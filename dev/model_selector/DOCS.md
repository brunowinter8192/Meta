# dev/model_selector/

## Role

Verification scripts for the model-selector line of work's plugin-side half (milestone 3,
cross-repo with monitor-cc): worker-model resolution in `src/spawn/tmux_spawn.sh` and
`src/spawn/spawn.py` from `~/.claude/shared-rules/model_selection.json`.

## Modules

### verify_worker_model_precedence.sh (126 LOC)

**Purpose:** Verifies `tmux_spawn.sh`'s shared `_resolve_worker_model()` and the real
`${4:-$(_resolve_worker_model)}`/`[ -z "$model" ] && model="$(_resolve_worker_model)"` expansion
patterns used at its 3 call sites (`spawn_claude_worker`, `spawn_claude_worker_from_file`,
`worker_revive`'s fallback) — by sourcing the real file and calling the real function, not
reimplementing the resolution logic. Covers: config hit/missing/malformed/missing-key/empty-key
(5 cases against `_resolve_worker_model` directly); explicit-arg-wins, empty-arg-falls-to-config,
omitted-arg-falls-to-config (3 cases against the real spawn-site expansion pattern);
stored-value-wins, stored-absent-falls-to-config, stored-and-config-both-absent (3 cases against
the real revive fallback pattern); a structural grep confirming all 3 call sites plus the
definition reference `_resolve_worker_model`. Runs under `set -uo pipefail` (deliberately NOT
`-e` — assertion mismatches must not abort the script; the sourced `tmux_spawn.sh` keeps its own
`set -euo pipefail` for the functions it defines).
**Reads:** nothing persistent — all config cases use a `mktemp -d` path via `MODEL_SELECTION_FILE`.
**Writes:** stdout only (no report file).
**Called by:** run manually — regression guard; re-run after any change to `_resolve_worker_model`
or its 3 call sites.
**Calls out:** `jq`, `src/spawn/tmux_spawn.sh` (sourced for real).

---

### verify_spawn_model_resolution.py (94 LOC)

**Purpose:** Verifies `spawn.py`'s `_resolve_worker_model()` (config hit/missing/malformed/
missing-key, same 4 cases as the bash side) and, separately, that argparse's `model` positional
— default changed from the hardcoded `"claude-sonnet-5"` literal to `None` — never lets the
literal string `"None"` leak into the resolved model: an omitted CLI arg produces real `None`
(not the string), and `args.model or _resolve_worker_model()` always yields a concrete non-empty
string. Loads `spawn.py` via `importlib.util.spec_from_file_location` (it has zero relative
imports — stdlib only — so file-path loading works without package context).
**Reads:** nothing persistent — all config cases use a `tempfile.TemporaryDirectory()`.
**Writes:** `md/verify_spawn_model_resolution.md`.
**Called by:** run manually — regression guard; re-run after any change to `spawn.py`'s model
resolution or argparse setup.
**Calls out:** `src/spawn/spawn.py` (loaded by path).

## Gotchas

**Neither script touches the real `~/.claude/shared-rules/model_selection.json`.** Both use the
`MODEL_SELECTION_FILE` env-var / module-attribute override pointed at a temp path.

**`worker-cli spawn` does not exercise either resolution path verified here.**
`bin/worker-cli`'s own `spawn)` case pre-resolves its 4th positional
(`MODEL="${4:-claude-sonnet-5}"`) BEFORE ever calling `spawn.py`, so `spawn.py`'s `args.model` is
never actually `None` on that path, and `spawn.py` in turn always hands `tmux_spawn.sh` a
concrete value, so `tmux_spawn.sh`'s own `_resolve_worker_model()` is never reached there either.
Both resolutions verified here are real and load-bearing for their own direct-caller cases
(a bare `python3 -m src.spawn.spawn` invocation without a model arg for `spawn.py`'s; a direct
`source tmux_spawn.sh` caller or `worker_revive` for the bash side's) — just not for the primary
`worker-cli spawn` entry point as it stands today. See `process-docs/model_selector/` (monitor-cc
repo) for the full trace.
