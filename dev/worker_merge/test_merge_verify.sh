#!/usr/bin/env bash
# Test: worker-cli merge's built-in outcome verification (bin/worker-cli, merge case).
# Uses a throwaway git repo + the explicit project_path argument — no registry, no tmux.
#
# Usage: bash dev/worker_merge/test_merge_verify.sh

set -uo pipefail

WCLI="$(cd "$(dirname "$0")/../.." && pwd)/bin/worker-cli"

TMPPROJ=$(mktemp -d)
TMPREG=$(mktemp -d)
export WORKER_REGISTRY_DIR="$TMPREG"

cleanup() { rm -rf "$TMPPROJ" "$TMPREG"; }
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

# ── Init throwaway repo on main, with a real commit ──────────────────────────
git init "$TMPPROJ" -b main -q
echo "a" > "$TMPPROJ/a.txt"
git -C "$TMPPROJ" add a.txt
git -C "$TMPPROJ" commit -q -m init

# ── Case 1: real merge — branch with a commit brings in a file ──────────────
echo "=== Case 1: merge a branch that carries a commit ==="

git -C "$TMPPROJ" checkout -q -b feat1
echo "b" > "$TMPPROJ/b.txt"
git -C "$TMPPROJ" add b.txt
git -C "$TMPPROJ" commit -q -m "feat1 commit"
git -C "$TMPPROJ" checkout -q main

OUT=$("$WCLI" merge feat1 "$TMPPROJ" 2>/tmp/merge_case1_err.txt)
RC=$?
ERR=$(cat /tmp/merge_case1_err.txt)
echo "  stdout:"
echo "$OUT" | sed 's/^/    /'
echo "  stderr: $ERR"
echo "  rc: $RC"

[ "$RC" -eq 0 ] && check "exit code 0" "ok" || check "exit code 0" "rc=$RC"

if echo "$OUT" | grep -qF "=== Files merged ==="; then
    check "'=== Files merged ===' header present" "ok"
else
    check "'=== Files merged ===' header present" "missing from stdout"
fi

if echo "$OUT" | grep -qxF "b.txt"; then
    check "b.txt listed as merged file" "ok"
else
    check "b.txt listed as merged file" "not found in stdout"
fi

if git -C "$TMPPROJ" rev-parse --verify main >/dev/null 2>&1 && \
   [ "$(git -C "$TMPPROJ" log -1 --pretty=%s)" = "merge: worker feat1" ]; then
    check "merge commit landed on main" "ok"
else
    check "merge commit landed on main" "not found"
fi

# ── Case 2: re-running merge on the same branch — no commits left, no-op ─────
echo ""
echo "=== Case 2: merge again — branch already fully merged (Already up to date) ==="

OUT2=$("$WCLI" merge feat1 "$TMPPROJ" 2>/tmp/merge_case2_err.txt)
RC2=$?
ERR2=$(cat /tmp/merge_case2_err.txt)
echo "  stdout:"
echo "$OUT2" | sed 's/^/    /'
echo "  stderr: $ERR2"
echo "  rc: $RC2"

[ "$RC2" -ne 0 ] && check "exit code non-zero" "ok" || check "exit code non-zero" "rc=$RC2"

if echo "$ERR2" | grep -qF "carried no commits"; then
    check "stderr names the no-op" "ok"
else
    check "stderr names the no-op" "missing from stderr"
fi

if echo "$ERR2" | grep -qF "project_path" && echo "$ERR2" | grep -qF "never committed"; then
    check "stderr names both known causes" "ok"
else
    check "stderr names both known causes" "missing from stderr"
fi

# ── Case 3: real conflict — git's own conflict output must reach the caller ──
echo ""
echo "=== Case 3: merge a branch that conflicts with main ==="

git -C "$TMPPROJ" checkout -q -b conflict1
echo "conflict-from-branch" > "$TMPPROJ/a.txt"
git -C "$TMPPROJ" add a.txt
git -C "$TMPPROJ" commit -q -m "conflict1 commit"
git -C "$TMPPROJ" checkout -q main
echo "conflict-from-main" > "$TMPPROJ/a.txt"
git -C "$TMPPROJ" add a.txt
git -C "$TMPPROJ" commit -q -m "main-side conflicting change"

OUT3=$("$WCLI" merge conflict1 "$TMPPROJ" 2>/tmp/merge_case3_err.txt)
RC3=$?
ERR3=$(cat /tmp/merge_case3_err.txt)
echo "  stdout:"
echo "$OUT3" | sed 's/^/    /'
echo "  stderr: $ERR3"
echo "  rc: $RC3"
git -C "$TMPPROJ" merge --abort 2>/dev/null || true

[ "$RC3" -ne 0 ] && check "exit code non-zero" "ok" || check "exit code non-zero" "rc=$RC3"

if echo "$OUT3" | grep -qF "CONFLICT"; then
    check "git's conflict text reaches stdout" "ok"
else
    check "git's conflict text reaches stdout" "missing from stdout"
fi

if echo "$OUT3" | grep -qF "=== Files merged ==="; then
    check "'=== Files merged ===' NOT printed on conflict" "printed despite conflict"
else
    check "'=== Files merged ===' NOT printed on conflict" "ok"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
rm -f /tmp/merge_case1_err.txt /tmp/merge_case2_err.txt /tmp/merge_case3_err.txt
echo ""
echo "=== Summary ==="
echo "  PASS: $pass"
echo "  FAIL: $fail"
[ "$fail" -eq 0 ] && exit 0 || exit 1
