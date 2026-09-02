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
# Shared, growing, gitignored trace file `wait` itself writes to (C1, 2026-08-18) — real default
# path, not test-isolated (same file real live wait invocations use); checked via a before/after
# size diff, never overwritten or truncated by this suite.
TRACE_FILE="${WORKER_LOGGER_DIR:-$HOME/Documents/ai/Meta/blank/src/logs}/wait_trace.log"
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

# --- fake worker: real tmux session (claude-dummy child, optional persistent tooling grandchild
# or chatty print-loop) + hooks entry ---
# create_worker NAME PROJ_DIR SESSION_ID STATUS BG(0|1) [CHATTY(0|1)]
# BG=1: claude-dummy forks a persistent grandchild (simulates a long-lived tooling child — e.g.
# pyright-langserver, the live incident this fixture regression-guards) that is NEVER killed
# during a test using it — the handle-based bg-task check must ignore it entirely, unlike the
# old process-tree walk this replaced (any grandchild = "busy", forever).
# CHATTY=1 (mutually exclusive with BG=1): claude-dummy loops printing to the pane every 1-2s
# until go_quiet() touches PROJ_DIR/.chatty-quiet, then falls silent (stays alive). This is the
# ONLY way to keep #{window_activity} fresh past 10s — the signal _worker_detect_status demotes
# hook_status=working on once stale (tmux_spawn.sh:172-186) — needed for any fixture that must
# read back as genuinely "working" for longer than a few seconds, or after a status flip that
# happens well after creation (the plain/BG=1 wrapper is silent, so window_activity goes stale
# the moment ~10s pass with no further pane output, independent of what hooks.json says).
create_worker() {
    local name="$1" proj_dir="$2" session_id="$3" status="$4" bg="$5" chatty="${6:-0}"
    mkdir -p "$proj_dir"
    local session="worker-$(basename "$proj_dir")-$name"
    tmux kill-session -t "$session" 2>/dev/null || true
    rm -f "$proj_dir/.claude.pid" "$proj_dir/.chatty-quiet"
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
echo "$CLAUDE_PID" > "$(dirname "$0")/.claude.pid"
wait $CLAUDE_PID
INNER
    elif [ "$chatty" = "1" ]; then
        cat > "$proj_dir/.chatty.sh" <<'INNER'
#!/bin/bash
QUIET_FILE="$1"
while [ ! -f "$QUIET_FILE" ]; do
    echo "tick $(date +%s)"
    sleep $(( (RANDOM % 2) + 1 ))
done
sleep 100000
INNER
        chmod +x "$proj_dir/.chatty.sh"
        cat > "$wrap" <<'INNER'
#!/bin/bash
( exec -a claude-dummy bash "$(dirname "$0")/.chatty.sh" "$(dirname "$0")/.chatty-quiet" ) &
CLAUDE_PID=$!
echo "$CLAUDE_PID" > "$(dirname "$0")/.claude.pid"
wait $CLAUDE_PID
INNER
    else
        cat > "$wrap" <<'INNER'
#!/bin/bash
( exec -a claude-dummy sleep 100000 ) &
CLAUDE_PID=$!
echo "$CLAUDE_PID" > "$(dirname "$0")/.claude.pid"
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

# go_quiet PROJ_DIR — stops a CHATTY=1 worker's print loop (touches the control file
# create_worker's chatty wrapper polls for). No-op if the worker wasn't created chatty.
go_quiet() {
    local proj_dir="$1"
    touch "$proj_dir/.chatty-quiet"
}

# kill_claude_child PROJ_DIR — kills just the claude-dummy process (pid recorded by
# create_worker), leaving the tmux session/pane alive. remain-on-exit then marks the pane
# dead once the wrapper's own `wait $CLAUDE_PID` returns and the wrapper script itself exits
# — _worker_detect_status reads that as pane_dead=1 -> dead: the "claude child gone"
# terminal path, distinct from killing the whole SESSION (which instead empties
# worker_list's NAMES entirely and never classifies as dead).
kill_claude_child() {
    local proj_dir="$1"
    local pf="$proj_dir/.claude.pid"
    [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null
    return 0
}

# delete_hook_entry SESSION_ID — removes the hooks.json entry while the tmux session/process
# stay alive, reproducing "no hook data". By itself this is NOT a dead signal under the
# working/idle/dead vocabulary (2026-09-02) — it just falls into the same shared
# working/idle window-activity check as any other no-hook-entry worker (working while
# fresh, idle once quiet > 10s). Used in Test 10 alongside kill_claude_child to build a
# realistic dead-AND-hook-orphaned worker, not on its own.
delete_hook_entry() {
    local sid="$1"
    jq --arg sid "$sid" 'del(.[$sid])' "$HOOKS_FILE" > "$HOOKS_FILE.tmp.$$" 2>/dev/null \
        && mv "$HOOKS_FILE.tmp.$$" "$HOOKS_FILE"
}

# create_worker_no_hook NAME PROJ_DIR SESSION_ID
#   Mirrors create_worker (claude-dummy child alive + JSONL present) but deliberately skips
#   set_hook_status — no hooks.json entry ever exists for this session_id. Session/pane ALIVE
#   (tmux session found by worker_list, claude-dummy child present), no dead signal fires, so
#   this resolves via the shared no-hook-entry window-activity check: "working" while the pane
#   is still fresh (just created), "idle" once quiet > 10s — NOT "dead" (2026-09-02 vocabulary
#   change; this fixture used to read as the old "unknown" placeholder). Distinct from Test 4's
#   session-GONE fixture (tmux session itself killed — routes through the empty-NAMES path
#   instead, untouched by this feature).
create_worker_no_hook() {
    local name="$1" proj_dir="$2" session_id="$3"
    mkdir -p "$proj_dir"
    local session="worker-$(basename "$proj_dir")-$name"
    tmux kill-session -t "$session" 2>/dev/null || true
    local wrap="$proj_dir/.wrap.sh"
    cat > "$wrap" <<'INNER'
#!/bin/bash
( exec -a claude-dummy sleep 100000 ) &
CLAUDE_PID=$!
wait $CLAUDE_PID
INNER
    chmod +x "$wrap"
    tmux new-session -d -s "$session" -c "$proj_dir" "bash $wrap" \; \
        set-option -p -t "$session" remain-on-exit on
    tmux set-environment -t "$session" WORKER_SPAWNED "$(date +%H:%M)"
    tmux set-environment -t "$session" WORKER_PURPOSE "test fixture"
    sleep 0.5
    local real_proj_dir encoded
    real_proj_dir=$(cd "$proj_dir" && pwd -P)
    encoded=$(echo "$real_proj_dir" | tr '/_.' '-')
    mkdir -p "$HOME/.claude/projects/$encoded"
    touch "$HOME/.claude/projects/$encoded/$session_id.jsonl"
    # Deliberately no set_hook_status call.
    echo "$session"
}

# create_worker_dead NAME PROJ_DIR
#   Wrapper exits immediately (no claude-dummy child ever forked); pane stays alive via
#   remain-on-exit, so #{pane_dead} flips to 1 and _worker_detect_status returns "dead"
#   directly — returns before the JSONL/hooks lookups, so neither is needed for this fixture.
create_worker_dead() {
    local name="$1" proj_dir="$2"
    mkdir -p "$proj_dir"
    local session="worker-$(basename "$proj_dir")-$name"
    tmux kill-session -t "$session" 2>/dev/null || true
    tmux new-session -d -s "$session" -c "$proj_dir" "true" \; \
        set-option -p -t "$session" remain-on-exit on
    tmux set-environment -t "$session" WORKER_SPAWNED "$(date +%H:%M)"
    tmux set-environment -t "$session" WORKER_PURPOSE "test fixture"
    sleep 0.5
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
    destroy_worker w1 "/tmp/${TEST_TAG}-3" "${TEST_TAG}-sess-3" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-3b" "${TEST_TAG}-sess-3b" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-4" "${TEST_TAG}-sess-4" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-5" "${TEST_TAG}-sess-5" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-6" "${TEST_TAG}-sess-6" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-7" "${TEST_TAG}-sess-7" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-8" "${TEST_TAG}-sess-8" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-8b" "${TEST_TAG}-sess-8b" 2>/dev/null || true
    destroy_worker wA "/tmp/${TEST_TAG}-9" "${TEST_TAG}-sess-9a" 2>/dev/null || true
    destroy_worker wB "/tmp/${TEST_TAG}-9" "${TEST_TAG}-sess-9b" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-10" "${TEST_TAG}-sess-10" 2>/dev/null || true
    destroy_worker w1 "/tmp/${TEST_TAG}-11" "${TEST_TAG}-sess-11" 2>/dev/null || true
    kill_fake_bg_task "${TEST_TAG}task5" 2>/dev/null || true
    kill_fake_bg_task "${TEST_TAG}task10" 2>/dev/null || true
    restore_hooks
}
trap cleanup_all EXIT

backup_hooks

echo "=== worker-cli wait — integration tests ==="
echo "(2026-09-02 transition-gate change: 'wait' may only exit idle/dead after observing a"
echo " real 'working' poll in THIS invocation — see bin/worker-cli wait case + SAW_WORKING)"

# --- Test 1 (transition-gate core proof, New Case 1): idle worker FROM THE START, never
# observed "working" in this invocation -> must NOT exit "workers idle"; runs to timeout.
# Was: "idle worker -> exits promptly, reason 'workers idle'" (the pre-gate, level-triggered
# contract) — an idle-at-arm worker no longer looks like a finished transition. ---
PROJ1="/tmp/${TEST_TAG}-1"
SID1="${TEST_TAG}-sess-1"
create_worker w1 "$PROJ1" "$SID1" idle 0 >/dev/null
TRACE_SIZE_BEFORE1=$([ -f "$TRACE_FILE" ] && wc -c < "$TRACE_FILE" || echo 0)
T0=$(date +%s)
OUT1=$(bash "$BIN" wait "$PROJ1" --timeout 25)
T1=$(date +%s)
ELAPSED1=$((T1 - T0))
if [ "$OUT1" = "timeout" ] && [ "$ELAPSED1" -ge 25 ] && [ "$ELAPSED1" -le 32 ]; then
    pass "test1 idle-from-start-never-exits: reason='$OUT1' elapsed=${ELAPSED1}s"
else
    fail "test1 idle-from-start-never-exits: reason='$OUT1' elapsed=${ELAPSED1}s (expected 'timeout', ~25-32s)"
fi

# --- Test 1c (C1, 2026-08-18, adapted): trace shows the run started, never observed a
# "working" poll (saw_working never reaches 1), and exited on the timeout ceiling. ---
if [ -f "$TRACE_FILE" ]; then
    # Scoped to THIS test's project tag — the trace file is shared with any concurrently
    # running real `wait` invocation on the machine, whose own lines (different project=)
    # would otherwise pollute a byte-offset-only diff.
    TRACE_NEW1=$(tail -c "+$((TRACE_SIZE_BEFORE1 + 1))" "$TRACE_FILE" | grep "project=$(basename "$PROJ1")")
    if [[ "$TRACE_NEW1" == *"event=start"* ]] && [[ "$TRACE_NEW1" == *"event=exit reason=timeout"* ]] \
        && [[ "$TRACE_NEW1" != *"saw_working=1"* ]]; then
        pass "test1c trace-observability: event=start + event=exit reason=timeout, saw_working never 1"
    else
        fail "test1c trace-observability: got: $TRACE_NEW1"
    fi
else
    fail "test1c trace-observability: $TRACE_FILE does not exist after a wait run"
fi
destroy_worker w1 "$PROJ1" "$SID1"

# --- Test 1b (2026-08 incident regression, adapted for the transition gate): worker starts
# genuinely "working" WITH a persistent tooling grandchild (never killed) — observed working
# at least once — then flips to idle -> exits "workers idle" promptly once stable. Preserves
# BOTH the original grandchild-ignored-by-the-bg-probe regression AND proves the gate
# correctly unlocks after a real working poll (window_activity is fresh at t=0, well inside
# the 2s pre-flip window here, so no chatty loop is needed for this brief a working phase). ---
PROJ1B="/tmp/${TEST_TAG}-1b"
SID1B="${TEST_TAG}-sess-1b"
create_worker w1 "$PROJ1B" "$SID1B" working 1 >/dev/null
OUT1B_FILE="/tmp/${TEST_TAG}-1b.out"
bash "$BIN" wait "$PROJ1B" --timeout 40 > "$OUT1B_FILE" 2>&1 &
P1B=$!
sleep 2
set_hook_status "$SID1B" idle "$PROJ1B"
T0=$(date +%s)
wait "$P1B"; RC1B=$?
T1=$(date +%s)
OUT1B=$(cat "$OUT1B_FILE")
ELAPSED1B=$((T1 - T0))
if [ "$OUT1B" = "workers idle" ] && [ "$RC1B" = 0 ] && [ "$ELAPSED1B" -le 25 ]; then
    pass "test1b tooling-child-incident: reason='$OUT1B' ${ELAPSED1B}s after the idle edge (persistent grandchild correctly ignored)"
else
    fail "test1b tooling-child-incident: rc=$RC1B reason='$OUT1B' elapsed=${ELAPSED1B}s (expected 'workers idle', <=25s after edge)"
fi
rm -f "$OUT1B_FILE"
destroy_worker w1 "$PROJ1B" "$SID1B"

# --- Test 2 (transition-gate core proof, New Case 2): no worker EVER registered for this
# project -> the removed "no workers" fast-exit must never fire; `wait` just keeps polling an
# empty roster (a non-exiting state, same as idle-from-start above) until the timeout ceiling.
# Was: "no worker ever registered + long timeout -> fast-exits 'no workers'" (the C3,
# 2026-08-18 contract this supersedes) — that whole exit path is now removed entirely. ---
T0=$(date +%s)
OUT2=$(bash "$BIN" wait "/tmp/${TEST_TAG}-nonexistent" --timeout 25)
T1=$(date +%s)
ELAPSED2=$((T1 - T0))
if [ "$OUT2" = "timeout" ] && [ "$ELAPSED2" -ge 25 ] && [ "$ELAPSED2" -le 32 ]; then
    pass "test2 no-worker-never-exits: reason='$OUT2' elapsed=${ELAPSED2}s"
else
    fail "test2 no-worker-never-exits: reason='$OUT2' elapsed=${ELAPSED2}s (expected 'timeout', ~25-32s, never 'no workers')"
fi

# --- Test 2b: short timeout with zero workers -> ordinary timeout. The old "two exit paths
# don't interfere" rationale no longer applies (there is only ONE exit path for an empty
# roster now: the timeout ceiling) — kept as a minimal short-timeout smoke test. ---
T0=$(date +%s)
OUT2B=$(bash "$BIN" wait "/tmp/${TEST_TAG}-nonexistent-2b" --timeout 3)
T1=$(date +%s)
ELAPSED2B=$((T1 - T0))
if [ "$OUT2B" = "timeout" ] && [ "$ELAPSED2B" -ge 3 ] && [ "$ELAPSED2B" -le 10 ]; then
    pass "test2b timeout-short: reason='$OUT2B' elapsed=${ELAPSED2B}s"
else
    fail "test2b timeout-short: reason='$OUT2B' elapsed=${ELAPSED2B}s (expected 'timeout', 3-10s)"
fi

# --- Test 3 (New Case 3): worker genuinely "working" (chatty, keeps #{window_activity} fresh)
# for ~10s, then goes quiet and edges to idle -> exits "workers idle" within the existing
# 3-sample/5s-poll stability window after the edge. Core positive-path proof of the transition
# gate: a real working phase DOES unlock the exit. ---
PROJ3="/tmp/${TEST_TAG}-3"
SID3="${TEST_TAG}-sess-3"
create_worker w1 "$PROJ3" "$SID3" working 0 1 >/dev/null
OUT3_FILE="/tmp/${TEST_TAG}-3.out"
bash "$BIN" wait "$PROJ3" --timeout 40 > "$OUT3_FILE" 2>&1 &
P3=$!
sleep 10
go_quiet "$PROJ3"
set_hook_status "$SID3" idle "$PROJ3"
T0=$(date +%s)
wait "$P3"; RC3=$?
T1=$(date +%s)
OUT3=$(cat "$OUT3_FILE")
ELAPSED3=$((T1 - T0))
if [ "$OUT3" = "workers idle" ] && [ "$RC3" = 0 ] && [ "$ELAPSED3" -le 20 ]; then
    pass "test3 working-then-idle-edge: reason='$OUT3' ${ELAPSED3}s after the edge"
else
    fail "test3 working-then-idle-edge: rc=$RC3 reason='$OUT3' elapsed=${ELAPSED3}s (expected 'workers idle', <=20s after edge)"
fi
rm -f "$OUT3_FILE"
destroy_worker w1 "$PROJ3" "$SID3"

# --- Test 3b (New Case 5, was Test 3 "concurrent-wait", adapted): two concurrent `wait`
# processes both armed during a genuine working phase (chatty) -> both must exit "workers
# idle" together on the same edge. ---
PROJ3B="/tmp/${TEST_TAG}-3b"
SID3B="${TEST_TAG}-sess-3b"
create_worker w1 "$PROJ3B" "$SID3B" working 0 1 >/dev/null
OUT3BA_FILE="/tmp/${TEST_TAG}-3ba.out"
OUT3BB_FILE="/tmp/${TEST_TAG}-3bb.out"
bash "$BIN" wait "$PROJ3B" --timeout 40 > "$OUT3BA_FILE" 2>&1 &
P3BA=$!
bash "$BIN" wait "$PROJ3B" --timeout 40 > "$OUT3BB_FILE" 2>&1 &
P3BB=$!
sleep 8
go_quiet "$PROJ3B"
set_hook_status "$SID3B" idle "$PROJ3B"
wait "$P3BA"; RC3BA=$?
wait "$P3BB"; RC3BB=$?
OUT3BA=$(cat "$OUT3BA_FILE"); OUT3BB=$(cat "$OUT3BB_FILE")
if [ "$RC3BA" = 0 ] && [ "$RC3BB" = 0 ] && [ "$OUT3BA" = "workers idle" ] && [ "$OUT3BB" = "workers idle" ]; then
    pass "test3b concurrent-wait-during-working: both exited 0 with 'workers idle'"
else
    fail "test3b concurrent-wait-during-working: rc=($RC3BA,$RC3BB) out=('$OUT3BA','$OUT3BB')"
fi
rm -f "$OUT3BA_FILE" "$OUT3BB_FILE"
destroy_worker w1 "$PROJ3B" "$SID3B"

# --- Test 4 (unchanged — verified compatible with the transition gate): probe target
# vanishes mid-wait (hard failure). The vanished-SESSION path routes entirely through the
# empty-NAMES branch, which has no exit condition of its own regardless of SAW_WORKING ->
# always ends in "timeout", same as before this change. ---
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

# --- Test 5 (adapted for the transition gate; preserves the original idle+bg hold intent):
# worker observed "working" once first (brief — the pre-flip window here is short enough that
# window_activity stays fresh without chatty), THEN flips to idle WITH a genuinely open
# *.output write handle -> holds until the handle closes, exits "workers idle" only once BOTH
# the working phase and the bg-task have completed. Also covers the /tmp vs /private/tmp
# resolution gotcha unchanged: the handle is opened via the UNRESOLVED raw_tasks_dir path
# while the hook internally resolves to /private/tmp/... ---
PROJ5="/tmp/${TEST_TAG}-5"
SID5="${TEST_TAG}-sess-5"
create_worker w1 "$PROJ5" "$SID5" working 0 >/dev/null
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
sleep 2
set_hook_status "$SID5" idle "$PROJ5"
sleep 10
if kill -0 "$P5" 2>/dev/null; then
    pass "test5b open-handle: still waiting while .output handle open (opened via unresolved /tmp path, must be detected via the resolved /private/tmp path)"
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

# --- Test 6 (unchanged — verified compatible with the transition gate): lsof unresolvable
# mid-check (PATH stripped of /usr/sbin) -> bg-check probe error -> the idle worker's ALL_
# NONBLOCKING never reaches 1 regardless of SAW_WORKING (the probe error itself keeps it
# classified busy every poll), so this always ends in "timeout", same as before this change.
# Isolates the bg-check's OWN error path (distinct from Test 4's status-check target-vanishes
# case). ---
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

# --- Test 7 (2026-08-19 incident regression, RE-PURPOSED for the working/idle/dead
# vocabulary, 2026-09-02 — verified by an actual run, not assumed): session ALIVE, no
# hooks.json entry ever populated. Under the OLD vocabulary this got stuck on a distinct
# "unknown" placeholder forever — the original incident. Under the NEW vocabulary there is
# no such stuck state: a freshly created pane with no hook data legitimately reads as
# "working" for its first ~10s (we cannot prove otherwise for a just-created pane — a
# correct default, not a misclassification), then self-heals to "idle" once quiet > 10s,
# with no orchestrator/hook data ever needed. This IS the fix for the original incident
# (self-healing beats a stuck-forever placeholder): `wait` correctly arms the gate on the
# real initial working reading and exits "workers idle" once the worker settles — it never
# needs a special terminal carve-out, and it never grinds to the timeout ceiling either.
# (The "never observed working, gate holds" proof lives in Tests 1/2/11a instead, which use
# an explicit idle hook status or no worker at all — neither goes through this shared
# fresh-pane window.) ---
PROJ7="/tmp/${TEST_TAG}-7"
SID7="${TEST_TAG}-sess-7"
create_worker_no_hook w1 "$PROJ7" "$SID7" >/dev/null
TRACE_SIZE_BEFORE7=$([ -f "$TRACE_FILE" ] && wc -c < "$TRACE_FILE" || echo 0)
T0=$(date +%s)
OUT7=$(bash "$BIN" wait "$PROJ7" --timeout 40)
T1=$(date +%s)
ELAPSED7=$((T1 - T0))
if [ "$OUT7" = "workers idle" ] && [ "$ELAPSED7" -ge 9 ] && [ "$ELAPSED7" -le 30 ]; then
    pass "test7a no-hook-entry-self-heals: reason='$OUT7' elapsed=${ELAPSED7}s"
else
    fail "test7a no-hook-entry-self-heals: reason='$OUT7' elapsed=${ELAPSED7}s (expected 'workers idle', ~9-30s)"
fi
if [ -f "$TRACE_FILE" ]; then
    TRACE_NEW7=$(tail -c "+$((TRACE_SIZE_BEFORE7 + 1))" "$TRACE_FILE" | grep "project=$(basename "$PROJ7")")
    if [[ "$TRACE_NEW7" == *"status=working"* ]] && [[ "$TRACE_NEW7" == *"status=idle"* ]] \
        && [[ "$TRACE_NEW7" == *"event=exit reason=workers_idle"* ]]; then
        pass "test7b trace-self-heal: shows working polls settling to idle polls, exit reason=workers_idle"
    else
        fail "test7b trace-self-heal: got: $TRACE_NEW7"
    fi
else
    fail "test7b trace-self-heal: $TRACE_FILE does not exist after a wait run"
fi
destroy_worker w1 "$PROJ7" "$SID7"

# --- Test 8 (adapted for the transition gate): session ALIVE, status stuck "dead"
# (#{pane_dead}=1) from the start (never observed working) -> gate holds, runs to timeout.
# The genuine "working -> killed -> dead" proof is Test 8b below. ---
PROJ8="/tmp/${TEST_TAG}-8"
create_worker_dead w1 "$PROJ8" >/dev/null
T0=$(date +%s)
OUT8=$(bash "$BIN" wait "$PROJ8" --timeout 25)
T1=$(date +%s)
ELAPSED8=$((T1 - T0))
if [ "$OUT8" = "timeout" ] && [ "$ELAPSED8" -ge 25 ] && [ "$ELAPSED8" -le 32 ]; then
    pass "test8 stuck-dead-from-start: reason='$OUT8' elapsed=${ELAPSED8}s"
else
    fail "test8 stuck-dead-from-start: reason='$OUT8' elapsed=${ELAPSED8}s (expected 'timeout', ~25-32s)"
fi
destroy_worker w1 "$PROJ8" "${TEST_TAG}-sess-8"

# --- Test 8b: worker genuinely "working" (chatty), then the claude child is killed while
# the tmux SESSION stays alive (remain-on-exit marks the pane dead once the wrapper's own
# `wait $CLAUDE_PID` returns) -> _worker_detect_status reports "dead" thereafter -> `wait`
# exits "worker dead" once stable, because a real working poll preceded the edge. Distinct
# from Test 4's session-GONE case (empty-NAMES path, never exits early, unchanged above). ---
PROJ8B="/tmp/${TEST_TAG}-8b"
SID8B="${TEST_TAG}-sess-8b"
create_worker w1 "$PROJ8B" "$SID8B" working 0 1 >/dev/null
OUT8B_FILE="/tmp/${TEST_TAG}-8b.out"
bash "$BIN" wait "$PROJ8B" --timeout 40 > "$OUT8B_FILE" 2>&1 &
P8B=$!
sleep 8
T0=$(date +%s)
kill_claude_child "$PROJ8B"
wait "$P8B"; RC8B=$?
T1=$(date +%s)
OUT8B=$(cat "$OUT8B_FILE")
ELAPSED8B=$((T1 - T0))
if [ "$OUT8B" = "worker dead" ] && [ "$RC8B" = 0 ] && [ "$ELAPSED8B" -le 25 ]; then
    pass "test8b working-then-child-killed: reason='$OUT8B' ${ELAPSED8B}s after the edge"
else
    fail "test8b working-then-child-killed: rc=$RC8B reason='$OUT8B' elapsed=${ELAPSED8B}s (expected 'worker dead', <=25s after edge)"
fi
rm -f "$OUT8B_FILE"
destroy_worker w1 "$PROJ8B" "$SID8B"

# --- Test 9 (unchanged — verified compatible with the transition gate and the
# working/idle/dead vocabulary): mixed project — one worker dead (#{pane_dead}=1) from the
# start, one worker genuinely "working" (fresh window_activity at creation covers this
# test's short 5s pre-flip window without chatty) -> `wait` must NOT exit early (dead folds
# into "non-blocking" but a real busy worker still blocks; SAW_WORKING is set from wB's very
# first poll). Once the working worker finishes (flipped to idle), `wait` exits "worker
# dead" (not "workers idle") because the dead worker is still there — validates fold-in +
# exit-line precedence together, now with the gate already satisfied from wB's early
# working poll. ---
PROJ9="/tmp/${TEST_TAG}-9"
SID9B="${TEST_TAG}-sess-9b"
create_worker_dead wA "$PROJ9" >/dev/null
create_worker wB "$PROJ9" "$SID9B" working 0 >/dev/null
OUT9_FILE="/tmp/${TEST_TAG}-9.out"
bash "$BIN" wait "$PROJ9" --timeout 40 > "$OUT9_FILE" 2>&1 &
P9=$!
sleep 5
if kill -0 "$P9" 2>/dev/null; then
    pass "test9a mixed-still-blocks: wait process still alive after 5s (dead worker did not short-circuit the still-busy worker)"
else
    fail "test9a mixed-still-blocks: wait process already exited early — $(cat "$OUT9_FILE")"
fi
set_hook_status "$SID9B" idle "$PROJ9"
T0=$(date +%s)
wait "$P9"; RC9=$?
T1=$(date +%s)
OUT9=$(cat "$OUT9_FILE")
ELAPSED9=$((T1 - T0))
if [ "$OUT9" = "worker dead" ] && [ "$RC9" = 0 ] && [ "$ELAPSED9" -le 25 ]; then
    pass "test9b mixed-exit-precedence: exited 'worker dead' ${ELAPSED9}s after the busy worker went idle (not 'workers idle')"
else
    fail "test9b mixed-exit-precedence: rc=$RC9 reason='$OUT9' elapsed=${ELAPSED9}s (expected 'worker dead')"
fi
rm -f "$OUT9_FILE"
destroy_worker wA "$PROJ9" "${TEST_TAG}-sess-9a"
destroy_worker wB "$PROJ9" "$SID9B"

# --- Test 10 (adapted for the transition gate AND the working/idle/dead vocabulary;
# preserves the original bg-skipped-for-dead intent): worker observed "working" once
# first, THEN the claude child is killed (pane goes dead via remain-on-exit — the SAME real
# dead signal Test 8b uses) AND the hooks.json entry is separately deleted (session/process
# alike show no live hook data — a realistic dead-and-orphaned shape) WHILE a genuinely open
# *.output write handle stays open throughout -> still exits "worker dead" promptly once
# stable, NOT held open until the handle closes — regression-guards the deliberate design
# decision to skip the bg-task probe for dead statuses (unlike Test 5's idle+bg case, which
# DOES hold). NOTE: a deleted hook entry ALONE is no longer a dead signal under the new
# vocabulary (see delete_hook_entry's doc comment) — kill_claude_child is what actually
# produces "dead" here. ---
PROJ10="/tmp/${TEST_TAG}-10"
SID10="${TEST_TAG}-sess-10"
create_worker w1 "$PROJ10" "$SID10" working 0 >/dev/null
TDIR_RAW10=$(raw_tasks_dir "$PROJ10" "$SID10")
TASK_ID10="${TEST_TAG}task10"
start_fake_bg_task "$TDIR_RAW10" "$TASK_ID10"
sleep 0.5
OUT10_FILE="/tmp/${TEST_TAG}-10.out"
bash "$BIN" wait "$PROJ10" --timeout 40 > "$OUT10_FILE" 2>&1 &
P10=$!
sleep 2
delete_hook_entry "$SID10"
kill_claude_child "$PROJ10"
T0=$(date +%s)
wait "$P10"; RC10=$?
T1=$(date +%s)
OUT10=$(cat "$OUT10_FILE")
ELAPSED10=$((T1 - T0))
if [ "$OUT10" = "worker dead" ] && [ "$RC10" = 0 ] && [ "$ELAPSED10" -le 25 ]; then
    pass "test10 working-then-dead-bg-open: reason='$OUT10' ${ELAPSED10}s after the edge (open handle correctly ignored for a dead worker)"
else
    fail "test10 working-then-dead-bg-open: rc=$RC10 reason='$OUT10' elapsed=${ELAPSED10}s (expected 'worker dead', <=25s after edge)"
fi
kill_fake_bg_task "$TASK_ID10"
rm -f "$OUT10_FILE"
destroy_worker w1 "$PROJ10" "$SID10"

# --- Test 11 (New Case 6): `wait` armed while the worker is already idle (no prior working)
# -> keeps running through the idle-from-arm phase (proven via a mid-run liveness check well
# past the old 15s early-exit threshold), THEN the worker becomes genuinely "working" (chatty,
# so window_activity stays fresh despite the flip happening long after creation), THEN idle
# again -> exits "workers idle" only after that SECOND transition, never on the first idle
# phase. ---
PROJ11="/tmp/${TEST_TAG}-11"
SID11="${TEST_TAG}-sess-11"
create_worker w1 "$PROJ11" "$SID11" idle 0 1 >/dev/null
OUT11_FILE="/tmp/${TEST_TAG}-11.out"
bash "$BIN" wait "$PROJ11" --timeout 60 > "$OUT11_FILE" 2>&1 &
P11=$!
sleep 18
if kill -0 "$P11" 2>/dev/null; then
    pass "test11a armed-while-idle: still waiting after 18s of idle-from-arm (no prior working, gate correctly holds)"
else
    fail "test11a armed-while-idle: exited early during the idle-from-arm phase — $(cat "$OUT11_FILE")"
fi
set_hook_status "$SID11" working "$PROJ11"
sleep 7
set_hook_status "$SID11" idle "$PROJ11"
go_quiet "$PROJ11"
T0=$(date +%s)
wait "$P11"; RC11=$?
T1=$(date +%s)
OUT11=$(cat "$OUT11_FILE")
ELAPSED11=$((T1 - T0))
if [ "$OUT11" = "workers idle" ] && [ "$RC11" = 0 ] && [ "$ELAPSED11" -le 25 ]; then
    pass "test11b second-transition-exits: reason='$OUT11' ${ELAPSED11}s after the working->idle edge (not the first idle phase)"
else
    fail "test11b second-transition-exits: rc=$RC11 reason='$OUT11' elapsed=${ELAPSED11}s (expected 'workers idle', <=25s after the SECOND edge)"
fi
rm -f "$OUT11_FILE"
destroy_worker w1 "$PROJ11" "$SID11"

echo "=== $([ $RESULT -eq 0 ] && echo ALL PASSED || echo SOME FAILED) ==="
exit $RESULT
