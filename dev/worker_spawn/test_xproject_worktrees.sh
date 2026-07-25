#!/usr/bin/env bash
# Smoke test: cross-project worktree tracking in worker-cli.
# Uses WORKER_REGISTRY_DIR + throwaway git repos — no tmux, no spawn, no live registry.
#
# Usage: bash dev/spawn/test_xproject_worktrees.sh

set -uo pipefail

WCLI="$(cd "$(dirname "$0")/../.." && pwd)/bin/worker-cli"

# Temp dirs
TMPREG=$(mktemp -d)
TMPTARGET=$(mktemp -d)
TMPSPAWN=$(mktemp -d)

export WORKER_REGISTRY_DIR="$TMPREG"

cleanup() { rm -rf "$TMPREG" "$TMPTARGET" "$TMPSPAWN"; }
trap cleanup EXIT

pass=0; fail=0

check() {
    local label="$1" result="$2"
    if [ "$result" = "ok" ]; then
        echo "  PASS: $label"
        ((pass++)) || true
    else
        echo "  FAIL: $label — $result"
        ((fail++)) || true
    fi
}

# ── Init throwaway git repos ─────────────────────────────────────────────────
git init "$TMPTARGET" -b main -q
git -C "$TMPTARGET" commit --allow-empty -m "init" -q

git init "$TMPSPAWN" -b main -q
git -C "$TMPSPAWN" commit --allow-empty -m "init" -q

# ── Case 1: worker-cli worktree tw1 <target> ─────────────────────────────────
echo "=== Case 1: worker-cli worktree tw1 <target> ==="

OUTPUT=$("$WCLI" worktree tw1 "$TMPTARGET" 2>&1)
echo "  output: $OUTPUT"

if [ -d "$TMPTARGET/.claude/worktrees/tw1" ]; then
    check "worktree dir exists in target" "ok"
else
    check "worktree dir exists in target" "not found at $TMPTARGET/.claude/worktrees/tw1"
fi

if git -C "$TMPTARGET" rev-parse --verify tw1 >/dev/null 2>&1; then
    check "branch tw1 exists in target" "ok"
else
    check "branch tw1 exists in target" "branch not found"
fi

if [ -f "$TMPREG/tw1.worktrees" ]; then
    SIDECAR_CONTENT=$(cat "$TMPREG/tw1.worktrees")
    if printf '%s' "$SIDECAR_CONTENT" | grep -qF "$TMPTARGET"; then
        check "sidecar contains target path" "ok"
    else
        check "sidecar contains target path" "content was: $SIDECAR_CONTENT"
    fi
else
    check "sidecar file exists" "not found at $TMPREG/tw1.worktrees"
fi

# ── Case 2: kill tw1 cleans BOTH spawn-side AND cross-project ────────────────
echo ""
echo "=== Case 2: worker-cli kill tw1 cleans both spawn + cross-project ==="

# Seed spawn-side: real worktree + branch in TMPSPAWN, registry entry
git -C "$TMPSPAWN" worktree add "$TMPSPAWN/.claude/worktrees/tw1" -b tw1 -q
echo "$TMPSPAWN" > "$TMPREG/tw1"

# Cross-project worktree from case 1 still exists (sidecar already written)
# Run kill — no tmux so session-kill is a no-op, spawn helpers have || true
"$WCLI" kill tw1 2>&1 | sed 's/^/  /'

# Spawn side
if [ ! -d "$TMPSPAWN/.claude/worktrees/tw1" ]; then
    check "spawn worktree removed" "ok"
else
    check "spawn worktree removed" "still exists at $TMPSPAWN/.claude/worktrees/tw1"
fi

if ! git -C "$TMPSPAWN" rev-parse --verify tw1 >/dev/null 2>&1; then
    check "spawn branch deleted" "ok"
else
    check "spawn branch deleted" "still exists"
fi

# Cross-project side
if [ ! -d "$TMPTARGET/.claude/worktrees/tw1" ]; then
    check "cross-project worktree removed" "ok"
else
    check "cross-project worktree removed" "still exists at $TMPTARGET/.claude/worktrees/tw1"
fi

if ! git -C "$TMPTARGET" rev-parse --verify tw1 >/dev/null 2>&1; then
    check "cross-project branch deleted" "ok"
else
    check "cross-project branch deleted" "still exists"
fi

# Sidecar + registry
if [ ! -f "$TMPREG/tw1.worktrees" ]; then
    check "sidecar removed" "ok"
else
    check "sidecar removed" "still exists"
fi

if [ ! -f "$TMPREG/tw1" ]; then
    check "registry entry removed" "ok"
else
    check "registry entry removed" "still exists"
fi

# ── Case 3: list + status --all skip *.worktrees sidecars ────────────────────
echo ""
echo "=== Case 3: list / status --all skip sidecar files ==="

TMPSPAWN2=$(mktemp -d)
git init "$TMPSPAWN2" -b main -q
git -C "$TMPSPAWN2" commit --allow-empty -m "init" -q

echo "$TMPSPAWN2" > "$TMPREG/realworker"
# Plant a sidecar alongside it — should NOT appear as a worker
touch "$TMPREG/realworker.worktrees"

LIST_OUT=$("$WCLI" list 2>&1)
echo "  list output:"
echo "$LIST_OUT" | sed 's/^/    /'

if echo "$LIST_OUT" | grep -qE "^realworker:"; then
    check "list shows realworker" "ok"
else
    check "list shows realworker" "not found in list output"
fi

if echo "$LIST_OUT" | grep -qE "^realworker\.worktrees:"; then
    check "list does NOT show sidecar as worker" "sidecar appeared as worker"
else
    check "list does NOT show sidecar as worker" "ok"
fi

STATUS_OUT=$("$WCLI" status --all 2>&1)
echo "  status --all output:"
echo "$STATUS_OUT" | sed 's/^/    /'

if echo "$STATUS_OUT" | grep -qE "^realworker\.worktrees:"; then
    check "status --all does NOT show sidecar as worker" "sidecar appeared as worker"
else
    check "status --all does NOT show sidecar as worker" "ok"
fi

rm -f "$TMPREG/realworker" "$TMPREG/realworker.worktrees"
rm -rf "$TMPSPAWN2"

# ── Case 4: worktree-rm removes orphaned cross-project worktree+branch ────────
echo ""
echo "=== Case 4: worktree-rm removes orphaned worktree + branch ==="

TMPTARGET2=$(mktemp -d)
git init "$TMPTARGET2" -b main -q
git -C "$TMPTARGET2" commit --allow-empty -m "init" -q
git -C "$TMPTARGET2" worktree add "$TMPTARGET2/.claude/worktrees/orphan" -b orphan -q

"$WCLI" worktree-rm "$TMPTARGET2" orphan 2>&1 | sed 's/^/  /'

if [ ! -d "$TMPTARGET2/.claude/worktrees/orphan" ]; then
    check "worktree-rm: worktree removed" "ok"
else
    check "worktree-rm: worktree removed" "still exists"
fi

if ! git -C "$TMPTARGET2" rev-parse --verify orphan >/dev/null 2>&1; then
    check "worktree-rm: branch deleted" "ok"
else
    check "worktree-rm: branch deleted" "still exists"
fi

rm -rf "$TMPTARGET2"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "  PASS: $pass"
echo "  FAIL: $fail"
[ "$fail" -eq 0 ] && exit 0 || exit 1
