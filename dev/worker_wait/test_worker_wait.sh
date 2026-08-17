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

# --- fake worker: real tmux session (claude-dummy child, optional persistent tooling grandchild) + hooks entry ---
# create_worker NAME PROJ_DIR SESSION_ID STATUS BG(0|1)
# BG=1: claude-dummy forks a persistent grandchild (simulates a long-lived tooling child — e.g.
# pyright-langserver, the live incident this fixture regression-guards) that is NEVER killed
# during a test using it — the handle-based bg-task check must ignore it entirely, unlike the
# old process-tree walk this replaced (any grandchild = "busy", forever).
create_worker() {
    local name="$1" proj_dir="$2" session_id="$3" status="$4" bg="$5"
    mkdir -p "$proj_dir"
    local session="worker-$(basename "$proj_dir")-$name"
    tmux kill-session -t "$session" 2>/dev/null || true
    local wrap="$proj_dir/.wrap.sh"
    if [ "$bg" = "1" ]; then
        # claude-dummy stays alive as a real bash process (must NOT itself be exec'd away, or
        # _worker_detect_status finds no "claude"-named descendant at all and misreports "limit
        # reached" instead of "idle" — the tooling child is a genuine FORKED grandchild, not a
        # further exec-replace of the claude-dummy identity).
        cat > "$wrap" <<'INNER'
#!/bin/bash
( exec -a claude-dummy bash -c '(exec -a pyright-langserver-dummy sleep 100000) & wait' ) &
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

# real_tasks_dir PROJ_DIR SESSION_ID — resolved (/private/tmp on macOS) tasks dir path a fixture
# worker's background tasks would live under; mirrors _wait_has_live_bg_task's own derivation.
real_tasks_dir() {
    local proj_dir="$1" session_id="$2"
    local real_proj_dir encoded real_tmp
    real_proj_dir=$(cd "$proj_dir" && pwd -P)
    encoded=$(echo "$real_proj_dir" | tr '/_.' '-')
    real_tmp=$(cd /tmp && pwd -P)
    echo "${real_tmp}/claude-$(id -u)/${encoded}/${session_id}/tasks"
}

# raw_tasks_dir PROJ_DIR SESSION_ID — same as real_tasks_dir but WITHOUT resolving /tmp (stays
# with the literal unresolved "/tmp/..." prefix) — used to deliberately open a fixture file via
# the unresolved path while the hook internally resolves to /private/tmp/..., proving detection
# still matches (same underlying file, OS-transparent symlink).
raw_tasks_dir() {
    local proj_dir="$1" session_id="$2"
    local real_proj_dir encoded
    real_proj_dir=$(cd "$proj_dir" && pwd -P)
    encoded=$(echo "$real_proj_dir" | tr '/_.' '-')
    echo "/tmp/claude-$(id -u)/${encoded}/${session_id}/tasks"
}

# start_fake_bg_task TASKS_DIR TASK_ID — opens a genuine long-lived write handle on
# <TASKS_DIR>/<TASK_ID>.output (mirrors what Claude Code itself does for a real backgrounded Bash
# call — `exec` preserves the just-opened FD across the image replace, so the resulting `sleep`
# process itself holds the handle open, same PID `$!` captures). Records that pid to a sidecar
# file for kill_fake_bg_task to clean up.
start_fake_bg_task() {
    local tdir="$1" task_id="$2"
    mkdir -p "$tdir"
    ( exec sleep 100000 > "$tdir/$task_id.output" ) &
    disown
    echo $! > "/tmp/${TEST_TAG}-fakebg-${task_id}.pid"
}

# kill_fake_bg_task TASK_ID — closes the handle opened by start_fake_bg_task.
kill_fake_bg_task() {
    local task_id="$1"
    local pidfile="/tmp/${TEST_TAG}-fakebg-${task_id}.pid"
    if [ -f "$pidfile" ]; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    fi
}

cleanup_all() {
    destroy_worker w1 "/tmp/${TEST_TAG}-1" "${TEST_TAG}-sess-1" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-1b" "${TEST_TAG}-sess-1b" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-3a" "${TEST_TAG}-sess-3a" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-4" "${TEST_TAG}-sess-4" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-5" "${TEST_TAG}-sess-5" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-6" "${TEST_TAG}-sess-6" 2>/dev/null || true
    kill_fake_bg_task "${TEST_TAG}task5" 2>/dev/null || true
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

# --- Test 1b (2026-08 incident regression): idle worker WITH a persistent tooling child (never
# killed) -> must STILL exit promptly. Under the old process-tree walk this worker would never
# have been detected as idle — every grandchild counted as "busy" forever, which is exactly the
# live incident (pyright-langserver, 36+ min) this handle-based rewrite fixes. ---
PROJ1B="/tmp/${TEST_TAG}-1b"
SID1B="${TEST_TAG}-sess-1b"
create_worker w1 "$PROJ1B" "$SID1B" idle 1 >/dev/null
T0=$(date +%s)
OUT1B=$(bash "$BIN" wait "$PROJ1B" --timeout 40)
T1=$(date +%s)
ELAPSED1B=$((T1 - T0))
if [ "$OUT1B" = "workers idle" ] && [ "$ELAPSED1B" -ge 9 ] && [ "$ELAPSED1B" -le 25 ]; then
    pass "test1b tooling-child-incident: reason='$OUT1B' elapsed=${ELAPSED1B}s (persistent grandchild correctly ignored)"
else
    fail "test1b tooling-child-incident: reason='$OUT1B' elapsed=${ELAPSED1B}s (expected 'workers idle', 9-25s — the incident regression)"
fi
destroy_worker w1 "$PROJ1B" "$SID1B"

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

# --- Test 5: idle worker WITH a genuinely open *.output write handle -> holds until it closes.
# Also covers the /tmp vs /private/tmp resolution gotcha: the handle is opened via the
# UNRESOLVED raw_tasks_dir path while the hook internally resolves to /private/tmp/... ---
PROJ5="/tmp/${TEST_TAG}-5"
SID5="${TEST_TAG}-sess-5"
create_worker w1 "$PROJ5" "$SID5" idle 0 >/dev/null
TDIR_RAW=$(raw_tasks_dir "$PROJ5" "$SID5")
TDIR_REAL=$(real_tasks_dir "$PROJ5" "$SID5")
TASK_ID="${TEST_TAG}task5"

case "$TDIR_REAL" in
    /private/tmp/*)
        pass "test5a tmp-resolution: real tasks dir resolves under /private/tmp ($TDIR_REAL)" ;;
    *)
        fail "test5a tmp-resolution: real tasks dir did NOT resolve under /private/tmp ($TDIR_REAL)" ;;
esac

start_fake_bg_task "$TDIR_RAW" "$TASK_ID"
sleep 0.5
OUT5_FILE="/tmp/${TEST_TAG}-5.out"
bash "$BIN" wait "$PROJ5" --timeout 40 > "$OUT5_FILE" 2>&1 &
P5=$!
sleep 12
if kill -0 "$P5" 2>/dev/null; then
    pass "test5b open-handle: still waiting after 12s while .output handle open (opened via unresolved /tmp path, must be detected via the resolved /private/tmp path)"
else
    fail "test5b open-handle: exited early while handle was still open — $(cat "$OUT5_FILE")"
fi
kill_fake_bg_task "$TASK_ID"
T0=$(date +%s)
wait "$P5"; RC5=$?
T1=$(date +%s)
OUT5=$(cat "$OUT5_FILE")
ELAPSED5=$((T1 - T0))
if [ "$OUT5" = "workers idle" ] && [ "$RC5" = 0 ] && [ "$ELAPSED5" -le 20 ]; then
    pass "test5c open-handle: exited 'workers idle' ${ELAPSED5}s after handle closed"
else
    fail "test5c open-handle: rc=$RC5 reason='$OUT5' elapsed=${ELAPSED5}s"
fi
rm -f "$OUT5_FILE"
destroy_worker w1 "$PROJ5" "$SID5"

# --- Test 6: lsof unresolvable mid-check (PATH stripped of /usr/sbin) -> bg-check probe error ->
# never reports "workers idle" even though the worker IS genuinely idle with zero real bg tasks,
# ends in timeout. Isolates the bg-check's OWN error path (distinct from Test 4's status-check
# target-vanishes case) — same PATH-stripping technique the (now-removed) block_timer_no_
# worker_working hook's tmux-unresolvable case used. ---
PROJ6="/tmp/${TEST_TAG}-6"
SID6="${TEST_TAG}-sess-6"
create_worker w1 "$PROJ6" "$SID6" idle 0 >/dev/null
OUT6_FILE="/tmp/${TEST_TAG}-6.out"
env PATH="/opt/homebrew/bin:/usr/bin:/bin" bash "$BIN" wait "$PROJ6" --timeout 12 > "$OUT6_FILE" 2>&1
RC6=$?
OUT6=$(cat "$OUT6_FILE")
if [ "$OUT6" = "timeout" ] && [ "$RC6" = 0 ]; then
    pass "test6 lsof-unresolvable: final reason='$OUT6' (never 'workers idle' despite a genuinely idle, bg-task-free worker)"
else
    fail "test6 lsof-unresolvable: rc=$RC6 reason='$OUT6' (expected 'timeout', never 'workers idle')"
fi
rm -f "$OUT6_FILE"
destroy_worker w1 "$PROJ6" "$SID6"

echo "=== $([ $RESULT -eq 0 ] && echo ALL PASSED || echo SOME FAILED) ==="
exit $RESULT
