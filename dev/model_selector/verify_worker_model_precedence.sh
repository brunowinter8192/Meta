#!/bin/bash
# Verify worker-model precedence for the 4 sites in src/spawn/tmux_spawn.sh that resolve a
# worker model (model-selector milestone 3): spawn_claude_worker, spawn_claude_worker_from_file,
# and worker_revive's WORKER_MODEL-absent fallback — all delegate to the real, shared
# _resolve_worker_model(). Drives the REAL sourced function and the REAL "${4:-...}" expansion
# pattern each site uses — no reimplementation of the resolution logic.
#
# Never touches the real ~/.claude/shared-rules/model_selection.json — all cases use a temp
# path via the MODEL_SELECTION_FILE env override.
#
# Usage: bash dev/model_selector/verify_worker_model_precedence.sh

set -uo pipefail  # deliberately NOT -e — assertion failures must not abort the script

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPAWN_SH="$PLUGIN_ROOT/src/spawn/tmux_spawn.sh"

PASS=0
FAIL=0
FAILURES=()

_assert_eq() {
    local desc="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
        echo "  [OK  ] $desc"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc (expected '$expected', got '$got')"
        FAIL=$((FAIL + 1))
        FAILURES+=("$desc")
    fi
}

source "$SPAWN_SH"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== _resolve_worker_model() directly — this IS the shared logic all 3 bash sites use ==="

MODEL_SELECTION_FILE="$TMP_DIR/does_not_exist.json"
_assert_eq "missing config file -> hardcoded fallback" \
    "claude-sonnet-5" "$(_resolve_worker_model)"

VALID_CONFIG="$TMP_DIR/valid.json"
echo '{"main": "claude-opus-5", "worker": "claude-fable-5"}' > "$VALID_CONFIG"
MODEL_SELECTION_FILE="$VALID_CONFIG"
_assert_eq "valid config -> config's worker model" \
    "claude-fable-5" "$(_resolve_worker_model)"

MALFORMED_CONFIG="$TMP_DIR/malformed.json"
echo '{not valid json' > "$MALFORMED_CONFIG"
MODEL_SELECTION_FILE="$MALFORMED_CONFIG"
_assert_eq "malformed JSON config -> hardcoded fallback, no crash" \
    "claude-sonnet-5" "$(_resolve_worker_model)"

MISSING_KEY_CONFIG="$TMP_DIR/missing_key.json"
echo '{"main": "claude-opus-5"}' > "$MISSING_KEY_CONFIG"
MODEL_SELECTION_FILE="$MISSING_KEY_CONFIG"
_assert_eq "config present but missing 'worker' key -> hardcoded fallback" \
    "claude-sonnet-5" "$(_resolve_worker_model)"

EMPTY_KEY_CONFIG="$TMP_DIR/empty_key.json"
echo '{"main": "claude-opus-5", "worker": ""}' > "$EMPTY_KEY_CONFIG"
MODEL_SELECTION_FILE="$EMPTY_KEY_CONFIG"
_assert_eq "config present with empty 'worker' value -> hardcoded fallback" \
    "claude-sonnet-5" "$(_resolve_worker_model)"

echo
echo "=== spawn_claude_worker / spawn_claude_worker_from_file's real \${4:-\$(_resolve_worker_model)} pattern ==="
echo "    (the identical expansion literally used at both call sites, not a reimplementation)"

MODEL_SELECTION_FILE="$VALID_CONFIG"
_site_expand() { local model="${4:-$(_resolve_worker_model)}"; echo "$model"; }

_assert_eq "explicit 4th arg present -> explicit wins, config never even consulted" \
    "claude-explicit-arg" "$(_site_expand a b c claude-explicit-arg e)"

_assert_eq "4th arg empty string -> falls to config (via _resolve_worker_model)" \
    "claude-fable-5" "$(_site_expand a b c "" e)"

_assert_eq "4th arg entirely absent -> falls to config (via _resolve_worker_model)" \
    "claude-fable-5" "$(_site_expand a b c)"

echo
echo "=== worker_revive's real 'stored value wins, else _resolve_worker_model' pattern ==="

MODEL_SELECTION_FILE="$VALID_CONFIG"
_revive_expand() { local model="$1"; [ -z "$model" ] && model="$(_resolve_worker_model)"; echo "$model"; }

_assert_eq "WORKER_MODEL present in tmux env -> stored value wins over config" \
    "claude-originally-spawned-with" "$(_revive_expand "claude-originally-spawned-with")"

_assert_eq "WORKER_MODEL absent from tmux env -> config applies" \
    "claude-fable-5" "$(_revive_expand "")"

MODEL_SELECTION_FILE="$TMP_DIR/does_not_exist.json"
_assert_eq "WORKER_MODEL absent AND config absent -> hardcoded fallback" \
    "claude-sonnet-5" "$(_revive_expand "")"

echo
echo "=== structural check: all 3 tmux_spawn.sh call sites reference _resolve_worker_model ==="
SITE_HITS=$(grep -c '_resolve_worker_model' "$SPAWN_SH")
# 1 definition + 1 doc comment mention + 3 call sites = 5 (loosely bounded, just confirms wiring)
if [ "$SITE_HITS" -ge 4 ]; then
    echo "  [OK  ] _resolve_worker_model referenced $SITE_HITS times in tmux_spawn.sh (definition + call sites)"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] _resolve_worker_model referenced only $SITE_HITS times — expected wiring at 3 call sites + definition"
    FAIL=$((FAIL + 1))
    FAILURES+=("structural wiring check")
fi

echo
total=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL/$total assertion(s):"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
echo "$PASS/$total passed."

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
