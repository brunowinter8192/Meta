#!/bin/bash
# Integration tests for `worker-cli wait` (bin/worker-cli, wait case).
# Exercises the REAL worker-cli binary + REAL tmux_spawn.sh status detection against
# throwaway tmux sessions + a scoped hooks.json entry (backed up/restored, never left
# dirty). Run: bash dev/worker_wait/test_worker_wait.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
BIN="$PLUGIN_ROOT/bin/worker-cli"
HOOKS_FILE="$HOME/Library/Application Support/com.brunowinter.monitor-cc-menubar/hooks.json"
HOOKS_BACKUP="/tmp/wait-test-hooks-backup-$$.json"
RESULT=0
TEST_TAG="waittest$$"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; RESULT=1; }

# --- hooks.json scoping (backup original, restore on exit — never left mutated) ---

backup_hooks() {
    if [ -f "$HOOKS_FILE" ]; then
        cp "$HOOKS_FILE" "$HOOKS_BACKUP"
    else
        : > "$HOOKS_BACKUP.missing"
        mkdir -p "$(dirname "$HOOKS_FILE")"
        echo '{}' > "$HOOKS_FILE"
    fi
}

restore_hooks() {
    if [ -f "$HOOKS_BACKUP" ]; then
        mv "$HOOKS_BACKUP" "$HOOKS_FILE"
    elif [ -f "$HOOKS_BACKUP.missing" ]; then
        rm -f "$HOOKS_FILE" "$HOOKS_BACKUP.missing"
    fi
}

set_hook_status() {
    local session_id="$1" status="$2" cwd="$3"
    local tmp="$HOOKS_FILE.tmp.$$"
    jq --arg sid "$session_id" --arg st "$status" --arg cwd "$cwd" \
        '.[$sid] = {status: $st, cwd: $cwd, updated_ts: now}' "$HOOKS_FILE" > "$tmp" \
        && mv "$tmp" "$HOOKS_FILE"
}

# --- fake worker: real tmux session (claude-dummy child, optional bg grandchild) + hooks entry ---
# create_worker NAME PROJ_DIR SESSION_ID STATUS BG(0|1)
create_worker() {
    local name="$1" proj_dir="$2" session_id="$3" status="$4" bg="$5"
    mkdir -p "$proj_dir"
    local session="worker-$(basename "$proj_dir")-$name"
    tmux kill-session -t "$session" 2>/dev/null || true
    local wrap="$proj_dir/.wrap.sh"
    if [ "$bg" = "1" ]; then
        # claude-dummy forks a bg child (the "live background task"), then blocks on it.
        # Once that child is killed (kill_bg_grandchild), claude-dummy re-execs into a bare
        # sleep — SAME pid, still named "claude-dummy", but now with zero children — so the
        # claude-side process survives the grandchild's death instead of the whole chain
        # collapsing (which would misreport as "limit reached" instead of a true idle+no-bg).
        cat > "$wrap" <<'INNER'
#!/bin/bash
( exec -a claude-dummy bash -c 'sleep 100000 & wait; exec -a claude-dummy sleep 100000' ) &
CLAUDE_PID=$!
wait $CLAUDE_PID
INNER
    else
        cat > "$wrap" <<'INNER'
#!/bin/bash
( exec -a claude-dummy sleep 100000 ) &
CLAUDE_PID=$!
wait $CLAUDE_PID
INNER
    fi
    chmod +x "$wrap"
    tmux new-session -d -s "$session" -c "$proj_dir" "bash $wrap" \; \
        set-option -p -t "$session" remain-on-exit on
    # Real spawn_claude_worker always sets these; worker_list's tmux show-environment lookup
    # errors on a missing var, which (under tmux_spawn.sh's set -euo pipefail) aborts the
    # whole function silently — match a real worker's env so the fixture is representative.
    tmux set-environment -t "$session" WORKER_SPAWNED "$(date +%H:%M)"
    tmux set-environment -t "$session" WORKER_PURPOSE "test fixture"
    sleep 0.5
    # tmux reports pane_current_path canonicalized (e.g. macOS /tmp -> /private/tmp) —
    # encode from the REAL path so it matches what _worker_detect_status looks up.
    local real_proj_dir encoded
    real_proj_dir=$(cd "$proj_dir" && pwd -P)
    encoded=$(echo "$real_proj_dir" | tr '/_.' '-')
    mkdir -p "$HOME/.claude/projects/$encoded"
    touch "$HOME/.claude/projects/$encoded/$session_id.jsonl"
    set_hook_status "$session_id" "$status" "$proj_dir"
    echo "$session"
}

# destroy_worker NAME PROJ_DIR SESSION_ID
destroy_worker() {
    local name="$1" proj_dir="$2" session_id="$3"
    local session="worker-$(basename "$proj_dir")-$name"
    tmux kill-session -t "$session" 2>/dev/null || true
    jq --arg sid "$session_id" 'del(.[$sid])' "$HOOKS_FILE" > "$HOOKS_FILE.tmp.$$" 2>/dev/null \
        && mv "$HOOKS_FILE.tmp.$$" "$HOOKS_FILE"
    local real_proj_dir encoded
    real_proj_dir=$([ -d "$proj_dir" ] && (cd "$proj_dir" && pwd -P) || echo "$proj_dir")
    encoded=$(echo "$real_proj_dir" | tr '/_.' '-')
    rm -rf "$HOME/.claude/projects/$encoded"
    rm -rf "$proj_dir"
}

# kill_bg_grandchild NAME PROJ_DIR — terminates the live "background task" child under the
# claude-dummy pid (used by test 5 to observe the idle+no-bg transition).
kill_bg_grandchild() {
    local name="$1" proj_dir="$2"
    local session="worker-$(basename "$proj_dir")-$name"
    local pane_pid
    pane_pid=$(tmux display-message -t "${session}:^" -p "#{pane_pid}" 2>/dev/null) || return 0
    local cpid
    for cpid in $(pgrep -P "$pane_pid" 2>/dev/null || true); do
        if ps -o command= -p "$cpid" 2>/dev/null | grep -q claude; then
            local gcpid
            for gcpid in $(pgrep -P "$cpid" 2>/dev/null || true); do
                kill "$gcpid" 2>/dev/null || true
            done
        fi
    done
}

cleanup_all() {
    destroy_worker w1 "/tmp/${TEST_TAG}-1" "${TEST_TAG}-sess-1" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-3a" "${TEST_TAG}-sess-3a" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-4" "${TEST_TAG}-sess-4" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-5" "${TEST_TAG}-sess-5" 2>/dev/null || true
    restore_hooks
}
trap cleanup_all EXIT

backup_hooks

echo "=== worker-cli wait — integration tests ==="

# --- Test 1: idle worker -> exits promptly, reason "workers idle" ---
PROJ1="/tmp/${TEST_TAG}-1"
SID1="${TEST_TAG}-sess-1"
create_worker w1 "$PROJ1" "$SID1" idle 0 >/dev/null
T0=$(date +%s)
OUT1=$(bash "$BIN" wait "$PROJ1" --timeout 40)
T1=$(date +%s)
ELAPSED1=$((T1 - T0))
if [ "$OUT1" = "workers idle" ] && [ "$ELAPSED1" -ge 9 ] && [ "$ELAPSED1" -le 25 ]; then
    pass "test1 idle-worker: reason='$OUT1' elapsed=${ELAPSED1}s"
else
    fail "test1 idle-worker: reason='$OUT1' elapsed=${ELAPSED1}s (expected 'workers idle', 9-25s)"
fi
destroy_worker w1 "$PROJ1" "$SID1"

# --- Test 2: no worker + small timeout -> exits at timeout ---
T0=$(date +%s)
OUT2=$(bash "$BIN" wait "/tmp/${TEST_TAG}-nonexistent" --timeout 6)
T1=$(date +%s)
ELAPSED2=$((T1 - T0))
if [ "$OUT2" = "timeout" ] && [ "$ELAPSED2" -ge 6 ] && [ "$ELAPSED2" -le 15 ]; then
    pass "test2 no-worker-timeout: reason='$OUT2' elapsed=${ELAPSED2}s"
else
    fail "test2 no-worker-timeout: reason='$OUT2' elapsed=${ELAPSED2}s (expected 'timeout', 6-15s)"
fi

# --- Test 3: two concurrent wait processes exit cleanly on the same idle transition ---
PROJ3="/tmp/${TEST_TAG}-3a"
SID3="${TEST_TAG}-sess-3a"
create_worker w1 "$PROJ3" "$SID3" idle 0 >/dev/null
OUT3A_FILE="/tmp/${TEST_TAG}-3a.out"
OUT3B_FILE="/tmp/${TEST_TAG}-3b.out"
bash "$BIN" wait "$PROJ3" --timeout 40 > "$OUT3A_FILE" 2>&1 &
P3A=$!
bash "$BIN" wait "$PROJ3" --timeout 40 > "$OUT3B_FILE" 2>&1 &
P3B=$!
wait "$P3A"; RC3A=$?
wait "$P3B"; RC3B=$?
OUT3A=$(cat "$OUT3A_FILE"); OUT3B=$(cat "$OUT3B_FILE")
if [ "$RC3A" = 0 ] && [ "$RC3B" = 0 ] && [ "$OUT3A" = "workers idle" ] && [ "$OUT3B" = "workers idle" ]; then
    pass "test3 concurrent-wait: both exited 0 with 'workers idle'"
else
    fail "test3 concurrent-wait: rc=($RC3A,$RC3B) out=('$OUT3A','$OUT3B')"
fi
rm -f "$OUT3A_FILE" "$OUT3B_FILE"
destroy_worker w1 "$PROJ3" "$SID3"

# --- Test 4: probe target vanishes mid-wait (hard failure) -> never reports "workers idle" ---
PROJ4="/tmp/${TEST_TAG}-4"
SID4="${TEST_TAG}-sess-4"
create_worker w1 "$PROJ4" "$SID4" working 0 >/dev/null
OUT4_FILE="/tmp/${TEST_TAG}-4.out"
bash "$BIN" wait "$PROJ4" --timeout 12 > "$OUT4_FILE" 2>&1 &
P4=$!
sleep 3
SESSION4="worker-$(basename "$PROJ4")-w1"
tmux kill-session -t "$SESSION4" 2>/dev/null || true
sleep 1
if kill -0 "$P4" 2>/dev/null; then
    pass "test4a probe-vanishes: wait process still alive immediately after target killed"
else
    fail "test4a probe-vanishes: wait process already exited (early exit!) right after target killed"
fi
wait "$P4"; RC4=$?
OUT4=$(cat "$OUT4_FILE")
if [ "$OUT4" = "timeout" ] && [ "$RC4" = 0 ]; then
    pass "test4b probe-vanishes: final reason='$OUT4' (never 'workers idle')"
else
    fail "test4b probe-vanishes: rc=$RC4 reason='$OUT4' (expected 'timeout', never 'workers idle')"
fi
rm -f "$OUT4_FILE"
destroy_worker w1 "$PROJ4" "$SID4"

# --- Test 5: idle worker WITH a live worker-side background task -> not done until it ends ---
PROJ5="/tmp/${TEST_TAG}-5"
SID5="${TEST_TAG}-sess-5"
create_worker w1 "$PROJ5" "$SID5" idle 1 >/dev/null
OUT5_FILE="/tmp/${TEST_TAG}-5.out"
bash "$BIN" wait "$PROJ5" --timeout 40 > "$OUT5_FILE" 2>&1 &
P5=$!
sleep 12
if kill -0 "$P5" 2>/dev/null; then
    pass "test5a live-bg-task: still waiting after 12s while bg task alive (idle alone did not trigger exit)"
else
    fail "test5a live-bg-task: exited early while bg task was still alive — $(cat "$OUT5_FILE")"
fi
kill_bg_grandchild w1 "$PROJ5"
T0=$(date +%s)
wait "$P5"; RC5=$?
T1=$(date +%s)
OUT5=$(cat "$OUT5_FILE")
ELAPSED5=$((T1 - T0))
if [ "$OUT5" = "workers idle" ] && [ "$RC5" = 0 ] && [ "$ELAPSED5" -le 20 ]; then
    pass "test5b live-bg-task: exited 'workers idle' ${ELAPSED5}s after bg task ended"
else
    fail "test5b live-bg-task: rc=$RC5 reason='$OUT5' elapsed=${ELAPSED5}s"
fi
rm -f "$OUT5_FILE"
destroy_worker w1 "$PROJ5" "$SID5"

echo "=== $([ $RESULT -eq 0 ] && echo ALL PASSED || echo SOME FAILED) ==="
exit $RESULT
