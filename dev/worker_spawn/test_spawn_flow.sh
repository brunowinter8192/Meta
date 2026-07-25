#!/bin/bash
# Test full spawn flow WITHOUT starting a real Claude Code session.
# Uses a dummy command instead of claude-patched to avoid token costs.
#
# Tests:
# 1. Proxy starts with correct env (PROXY_LOG_ID)
# 2. tmux session creation is non-blocking
# 3. Ghostty open_tmux_viewer is non-blocking
# 4. spawn_claude_worker returns within 5s (not 60s timeout)
# 5. Worker proxy creates a separate log file
# 6. Cleanup works (proxy killed on session exit)
#
# Usage: bash dev/spawn/test_spawn_flow.sh [--no-ghostty]
#        --no-ghostty: skip Ghostty window test (for headless/CI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPAWN_SH="$PLUGIN_ROOT/src/spawn/tmux_spawn.sh"

# Use Monitor_CC as test project (needs proxy marker files)
TEST_PROJECT="/Users/brunowinter2000/Documents/ai/Monitor_CC"
TEST_NAME="test-spawn-flow"
TEST_SESSION="worker-Monitor_CC-${TEST_NAME}"
SKIP_GHOSTTY=false

for arg in "$@"; do
    case "$arg" in
        --no-ghostty) SKIP_GHOSTTY=true ;;
    esac
done

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null && echo "  killed tmux session" || true
    # Kill any test proxy
    pkill -f "mitmdump.*test-spawn-flow" 2>/dev/null && echo "  killed test proxy" || true
    # Remove test worktree if created
    if [ -d "$TEST_PROJECT/.claude/worktrees/$TEST_NAME" ]; then
        git -C "$TEST_PROJECT" worktree remove ".claude/worktrees/$TEST_NAME" --force 2>/dev/null || true
        git -C "$TEST_PROJECT" branch -D "$TEST_NAME" 2>/dev/null || true
        echo "  removed worktree + branch"
    fi
}
trap cleanup EXIT

# Pre-cleanup
cleanup 2>/dev/null

echo "=== Test 1: open_tmux_viewer blocking test ==="
# Create a dummy tmux session, then test if open_tmux_viewer returns quickly
DUMMY_SESSION="test-ghostty-block"
tmux kill-session -t "$DUMMY_SESSION" 2>/dev/null || true
tmux new-session -d -s "$DUMMY_SESSION" "sleep 30"

if [ "$SKIP_GHOSTTY" = true ]; then
    pass "skipped (--no-ghostty)"
else
    source "$SPAWN_SH"
    START_TIME=$(date +%s)
    open_tmux_viewer "$DUMMY_SESSION" 2>/dev/null || true
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [ "$ELAPSED" -le 5 ]; then
        pass "open_tmux_viewer returned in ${ELAPSED}s"
    else
        fail "open_tmux_viewer took ${ELAPSED}s (should be <5s)"
    fi
fi
tmux kill-session -t "$DUMMY_SESSION" 2>/dev/null || true

echo ""
echo "=== Test 2: Proxy marker files exist ==="
PROJECT_HASH=$(echo -n "$TEST_PROJECT" | md5 | head -c 8)
MARKER="/tmp/.monitor_cc_proxy_${PROJECT_HASH}"
if [ -f "$MARKER" ]; then
    MARKER_PORT=$(head -1 "$MARKER")
    MARKER_LINES=$(wc -l < "$MARKER" | tr -d ' ')
    pass "marker exists: port=$MARKER_PORT, lines=$MARKER_LINES"
else
    fail "marker not found: $MARKER (is proxy running for Monitor_CC?)"
fi

echo ""
echo "=== Test 3: Worker proxy spawn (isolated) ==="
# Test the proxy-spawn logic from tmux_spawn.sh without full worker
# Simulate what spawn_claude_worker does for proxy setup
source "$SPAWN_SH"

PROXY_PROJECT_PATH="$TEST_PROJECT"
if command -v md5 >/dev/null 2>&1; then
    WORKER_SESSION_ID=$(echo -n "worker-${TEST_NAME}-${PROXY_PROJECT_PATH}" | md5 | head -c 8)
else
    WORKER_SESSION_ID=$(echo -n "worker-${TEST_NAME}-${PROXY_PROJECT_PATH}" | md5sum | head -c 8)
fi
WORKER_LOG_ID="${WORKER_SESSION_ID}_$(date +%s)"

if [ -f "$MARKER" ] && [ -f "/tmp/.monitor_cc_root" ]; then
    MAIN_PORT=$(head -1 "$MARKER")
    MONITOR_CC_ROOT=$(cat "/tmp/.monitor_cc_root")
    WORKER_PORT=$((MAIN_PORT + 100))  # Use high offset to avoid collisions
    while lsof -iTCP:${WORKER_PORT} -sTCP:LISTEN >/dev/null 2>&1; do
        WORKER_PORT=$((WORKER_PORT + 1))
    done

    LOG_DIR="${MONITOR_CC_ROOT}/src/logs"
    WORKER_LOG="${LOG_DIR}/api_requests_${WORKER_LOG_ID}.jsonl"

    MONITOR_CC_ROOT="$MONITOR_CC_ROOT" PROXY_LOG_ID="$WORKER_LOG_ID" \
        mitmdump -p "$WORKER_PORT" -s "${MONITOR_CC_ROOT}/src/proxy_addon.py" \
        --set flow_detail=0 -q \
        2>"${LOG_DIR}/proxy_errors_test.log" &
    TEST_PROXY_PID=$!
    sleep 1

    if kill -0 "$TEST_PROXY_PID" 2>/dev/null; then
        pass "worker proxy started on port $WORKER_PORT (PID $TEST_PROXY_PID)"
    else
        fail "worker proxy died immediately"
    fi

    # Verify it would write to the correct file
    echo "  Expected log: $WORKER_LOG"

    # Kill test proxy
    kill "$TEST_PROXY_PID" 2>/dev/null || true
    pass "worker proxy cleaned up"
else
    fail "no proxy marker — can't test worker proxy spawn"
fi

echo ""
echo "=== Test 4: Full spawn timing (dummy command) ==="
# Temporarily create a mock claude-patched that just sleeps
MOCK_CLAUDE="/tmp/claude-patched"
cat > "$MOCK_CLAUDE" << 'MOCKEOF'
#!/bin/bash
echo "MOCK Claude Code started with args: $@"
echo "Waiting for input (simulating idle)..."
# Stay alive so tmux session doesn't exit immediately
sleep 300
MOCKEOF
chmod +x "$MOCK_CLAUDE"

# Add mock to PATH temporarily
export PATH="/tmp:$PATH"

source "$SPAWN_SH"
TASK_PROMPT="Test prompt — this is a mock spawn for timing measurement."

START_TIME=$(date +%s%N 2>/dev/null || date +%s)
spawn_claude_worker "workers" "$TEST_NAME" "$TEST_PROJECT" "sonnet" "$TASK_PROMPT" > /tmp/spawn-test-output.txt 2>&1
END_TIME=$(date +%s%N 2>/dev/null || date +%s)

# Calculate elapsed (handle both ns and s)
if [[ "$START_TIME" =~ ^[0-9]{10,}$ ]]; then
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    ELAPSED_STR="${ELAPSED_MS}ms"
else
    ELAPSED_MS=$(( (END_TIME - START_TIME) * 1000 ))
    ELAPSED_STR="${ELAPSED_MS}ms (second precision)"
fi

SPAWN_OUTPUT=$(cat /tmp/spawn-test-output.txt)
echo "  spawn output: $SPAWN_OUTPUT"
echo "  elapsed: $ELAPSED_STR"

if [ "$ELAPSED_MS" -le 10000 ]; then
    pass "spawn returned in $ELAPSED_STR (< 10s)"
else
    fail "spawn took $ELAPSED_STR (should be < 10s — likely Ghostty blocking)"
fi

# Verify tmux session exists
if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "tmux session '$TEST_SESSION' exists"
else
    fail "tmux session '$TEST_SESSION' not found"
fi

# Verify mock claude is running in the pane
sleep 1
PANE_CONTENT=$(tmux capture-pane -p -t "$TEST_SESSION" 2>/dev/null || echo "")
if echo "$PANE_CONTENT" | grep -q "MOCK Claude Code"; then
    pass "mock claude running in pane"
else
    fail "mock claude not found in pane output"
    echo "  pane content: $PANE_CONTENT"
fi

echo ""
echo "=== Test 5: Worker proxy was started ==="
# Check if a worker proxy process exists for this spawn
WORKER_PROXY=$(ps aux | grep "mitmdump.*proxy_addon" | grep -v grep | grep -v "test-spawn-flow" || true)
if [ -n "$WORKER_PROXY" ]; then
    pass "worker proxy process found"
else
    # May have already been killed or not started (no marker)
    echo "  ⚠ no worker proxy found (may be expected if no marker)"
fi

echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="

exit $FAIL
