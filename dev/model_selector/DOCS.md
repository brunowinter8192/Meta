# dev/model_selector/

## Role

Verification scripts for the model-selector line of work's plugin-side half (milestone 3,
cross-repo with monitor-cc): worker-model resolution in `bin/worker-cli`, `src/spawn/spawn.py`,
and `src/spawn/tmux_spawn.sh` from `~/.claude/shared-rules/model_selection.json`.

## Modules

### verify_worker_model_precedence.sh (207 LOC)

**Purpose:** Verifies `tmux_spawn.sh`'s shared `_resolve_worker_model()` and the real
`${4:-$(_resolve_worker_model)}`/`[ -z "$model" ] && model="$(_resolve_worker_model)"` expansion
patterns used at its 3 call sites (`spawn_claude_worker`, `spawn_claude_worker_from_file`,
`worker_revive`'s fallback) — by sourcing the real file and calling the real function, not
reimplementing the resolution logic. Covers: config hit/missing/malformed/missing-key/empty-key
(5 cases against `_resolve_worker_model` directly); explicit-arg-wins, empty-arg-falls-to-config,
omitted-arg-falls-to-config (3 cases against the real spawn-site expansion pattern);
stored-value-wins, stored-absent-falls-to-config, stored-and-config-both-absent (3 cases against
the real revive fallback pattern); a structural grep confirming all 3 call sites plus the
definition reference `_resolve_worker_model`. **Real entry-point section (2026-08 fix
follow-up):** drives the actual `bin/worker-cli spawn` binary via subprocess — the only kind of
check that caught the 5th hardcode site (see Gotchas) after the isolated checks above all passed
while the assembled path was still dead code. 2 cases: no model arg (config's `worker` value must
reach both the generated runner script's `--model` and the tmux `WORKER_MODEL` env var) and an
explicit model arg (must still win). Overrides `WORKER_REGISTRY_DIR` (never touches the real
worker registry), `CLAUDE_BIN` (points at a tiny mock that prints `❯` and sleeps — never spawns a
real Claude process), `CLAUDE_PLUGIN_ROOT` (points `bin/worker-cli`'s own `$PLUGIN` resolution at
THIS worktree instead of the installed plugin cache — see Gotchas), and unsets
`PROXY_PROJECT_PATH` (so an ambient proxied session never redirects the scratch project path).
Runs under `set -uo pipefail` (deliberately NOT `-e` — assertion mismatches must not abort the
script; the sourced `tmux_spawn.sh` keeps its own `set -euo pipefail` for the functions it
defines).
**Reads:** nothing persistent — all config cases use a `mktemp -d` path via `MODEL_SELECTION_FILE`.
**Writes:** stdout only (no report file); real-entry-point section creates and cleans up its own
tmux sessions, runner scripts, and `/tmp/worker-<name>.done` markers.
**Called by:** run manually — regression guard; re-run after any change to `_resolve_worker_model`,
its 3 call sites, or `bin/worker-cli`'s `spawn)` case.
**Calls out:** `jq`, `tmux`, `src/spawn/tmux_spawn.sh` (sourced for real), `bin/worker-cli`
(invoked for real via subprocess).

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

**Neither script touches the real `~/.claude/shared-rules/model_selection.json` or the real
`~/.claude/.worker-registry`.** Config cases use a temp path via `MODEL_SELECTION_FILE`; the real
entry-point section overrides `WORKER_REGISTRY_DIR` too.

**The 5th hardcode site, found by tracing (not by grep scoped to `src/`) — fixed.**
`bin/worker-cli`'s own `spawn)` case used to pre-resolve its 4th positional to a hardcoded literal
(`MODEL="${4:-claude-sonnet-5}"`) BEFORE ever calling `spawn.py`, so `spawn.py`'s `args.model` was
never actually `None` on that path, and `spawn.py` in turn always handed `tmux_spawn.sh` a
concrete value — `tmux_spawn.sh`'s own `_resolve_worker_model()` was never reached there either.
**Every individual piece verified correctly in isolation while the assembled real path
(`worker-cli spawn` with no model arg) was still dead code** — the isolated `_resolve_worker_model`
and expansion-pattern checks above could not have caught this; only a real subprocess call to
`bin/worker-cli spawn` could, and did. Fixed: `MODEL="${4:-}"` (empty string passes through,
`args.model or _resolve_worker_model()` correctly treats it as falsy). See
`process-docs/model_selector/` (monitor-cc repo) for the full trace and the whole-repo grep that
confirmed no 6th site.

**`CLAUDE_PLUGIN_ROOT` must be set for a real-entry-point test to exercise THIS worktree.**
`bin/worker-cli` resolves its own `$PLUGIN` variable from `CLAUDE_PLUGIN_ROOT`, falling back to
the INSTALLED plugin cache copy (`~/.claude/plugins/cache/.../iterative-dev/1.0.0/`) if unset —
confirmed live that the installed copy still carries the pre-fix code, so a real-entry-point test
run without this override silently verifies the wrong `spawn.py`/`tmux_spawn.sh`, passing or
failing for the wrong reason. `verify_worker_model_precedence.sh`'s real-entry-point section sets
`CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"` (this worktree) before invoking `bin/worker-cli`.
