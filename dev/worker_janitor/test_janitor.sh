#!/usr/bin/env bash
# Smoke test: worker-cli janitor (stale-worker cleanup).
# Uses WORKER_REGISTRY_DIR + a throwaway git repo (no real registry touched) AND an
# ISOLATED tmux server (`tmux -L`, via a PATH-shadowing wrapper script) so the "run for
# real" pass can never see/touch live sessions (keep-filters, menubar-remote, this
# worker's own session, repro1b58790-w1) even with --max-age-hours 0 matching everything.
# session_created cannot be faked, so the age gate is exercised via --max-age-hours 0
# for the "should be killed" case and the real default (12h) for the "spared" case.
#
# Usage: bash dev/worker_janitor/test_janitor.sh

set -uo pipefail

WCLI="$(cd "$(dirname "$0")/../.." && pwd)/bin/worker-cli"
REAL_TMUX="$(command -v tmux)"

TMPREG=$(mktemp -d)
TMPBASE=$(mktemp -d)
# Subdir with a dot-free basename: mktemp's default "tmp.XXXXXXXX" naming contains a
# "." — tmux silently rewrites "." (reserved target-spec separator) to "_" in session
# names, which would desync the actual live session name from what
# _worker_session_name computes from this path's basename.
TMPPROJ="$TMPBASE/janitorproj"
mkdir -p "$TMPPROJ"
TMPLOGS=$(mktemp -d)
TMPBIN=$(mktemp -d)

export WORKER_REGISTRY_DIR="$TMPREG"
export WORKER_LOGGER_DIR="$TMPLOGS"
export PATH="$TMPBIN:$PATH"

cat > "$TMPBIN/tmux" <<WRAP
#!/usr/bin/env bash
exec "$REAL_TMUX" -L janitor_smoke_test_$$ "\$@"
WRAP
chmod +x "$TMPBIN/tmux"

cleanup() {
    tmux kill-server 2>/dev/null || true
    rm -rf "$TMPREG" "$TMPBASE" "$TMPLOGS" "$TMPBIN"
}
trap cleanup EXIT

pass=0; fail=0
check() {
    local label="$1" result="$2"
    if [ "$result" = "ok" ]; then
        echo "  PASS: $label"; ((pass++)) || true
    else
        echo "  FAIL: $label — $result"; ((fail++)) || true
    fi
}

git init "$TMPPROJ" -b main -q
git -C "$TMPPROJ" commit --allow-empty -m "init" -q
PROJ_BASENAME=$(basename "$TMPPROJ")

# ── Case 1: dry-run lists a synthetic session as a candidate ────────────────
echo "=== Case 1: janitor --max-age-hours 0 --dry-run — candidate listed ==="

git -C "$TMPPROJ" worktree add ".claude/worktrees/stale1" -b stale1 -q
SESSION1="worker-${PROJ_BASENAME}-stale1"
tmux new-session -d -s "$SESSION1" -c "$TMPPROJ/.claude/worktrees/stale1" 'sleep 300'
sleep 1  # let tmux settle session_created / pane state

DRYRUN_OUT=$("$WCLI" janitor --max-age-hours 0 --dry-run 2>&1)
echo "$DRYRUN_OUT" | sed 's/^/  /'

if echo "$DRYRUN_OUT" | grep -q "DRY-RUN candidate: $SESSION1"; then
    check "stale1 listed as dry-run candidate" "ok"
else
    check "stale1 listed as dry-run candidate" "not found in output"
fi

if tmux has-session -t "$SESSION1" 2>/dev/null; then
    check "dry-run did not kill the session" "ok"
else
    check "dry-run did not kill the session" "session gone after dry-run!"
fi

# ── Case 2: real run kills the stale synthetic session ───────────────────────
echo ""
echo "=== Case 2: janitor --max-age-hours 0 (real) — session killed ==="

REAL_OUT=$("$WCLI" janitor --max-age-hours 0 2>&1)
echo "$REAL_OUT" | sed 's/^/  /'

if ! tmux has-session -t "$SESSION1" 2>/dev/null; then
    check "stale1 tmux session gone" "ok"
else
    check "stale1 tmux session gone" "still exists"
fi

if [ ! -d "$TMPPROJ/.claude/worktrees/stale1" ]; then
    check "stale1 worktree removed" "ok"
else
    check "stale1 worktree removed" "still exists"
fi

if ! git -C "$TMPPROJ" rev-parse --verify stale1 >/dev/null 2>&1; then
    check "stale1 branch deleted" "ok"
else
    check "stale1 branch deleted" "still exists"
fi

if [ -f "$TMPLOGS/janitor.log" ] && grep -q "action=kill.*name=stale1" "$TMPLOGS/janitor.log"; then
    check "janitor.log has kill line for stale1" "ok"
else
    check "janitor.log has kill line for stale1" "not found"
fi

# ── Case 3: fresh synthetic session is spared by the age gate ────────────────
echo ""
echo "=== Case 3: fresh session spared (default 12h threshold) ==="

git -C "$TMPPROJ" worktree add ".claude/worktrees/fresh1" -b fresh1 -q
SESSION2="worker-${PROJ_BASENAME}-fresh1"
tmux new-session -d -s "$SESSION2" -c "$TMPPROJ/.claude/worktrees/fresh1" 'sleep 300'
sleep 1

FRESH_OUT=$("$WCLI" janitor 2>&1)  # default --max-age-hours 12
echo "$FRESH_OUT" | sed 's/^/  /'

if tmux has-session -t "$SESSION2" 2>/dev/null; then
    check "fresh1 session spared (not killed)" "ok"
else
    check "fresh1 session spared (not killed)" "was killed!"
fi

if echo "$FRESH_OUT" | grep -q "$SESSION2"; then
    check "fresh1 not mentioned in real-run output (below age threshold)" "mentioned — $(echo "$FRESH_OUT" | grep "$SESSION2")"
else
    check "fresh1 not mentioned in real-run output (below age threshold)" "ok"
fi

# ── Case 4: orphan registry entry (no tmux session) cleaned ──────────────────
echo ""
echo "=== Case 4: orphan registry entry — no tmux session, past grace window ==="

git -C "$TMPPROJ" worktree add ".claude/worktrees/orphan1" -b orphan1 -q
echo "$TMPPROJ" > "$TMPREG/orphan1"
touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '-1 hour' +%Y%m%d%H%M.%S)" "$TMPREG/orphan1"

ORPHAN_OUT=$("$WCLI" janitor --max-age-hours 0 2>&1)
echo "$ORPHAN_OUT" | sed 's/^/  /'

if [ ! -f "$TMPREG/orphan1" ]; then
    check "orphan1 registry entry removed" "ok"
else
    check "orphan1 registry entry removed" "still exists"
fi

if [ ! -d "$TMPPROJ/.claude/worktrees/orphan1" ]; then
    check "orphan1 worktree removed" "ok"
else
    check "orphan1 worktree removed" "still exists"
fi

if grep -q "action=orphan-clean.*name=orphan1" "$TMPLOGS/janitor.log"; then
    check "janitor.log has orphan-clean line" "ok"
else
    check "janitor.log has orphan-clean line" "not found"
fi

echo ""
echo "=== Summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
