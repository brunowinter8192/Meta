#!/bin/bash
# Test H1: Direct command arg to tmux new-session
# Verifies env var inheritance and immediate command execution without polling.
set -euo pipefail

SESSION="test-spawn-h1"
RESULT=0

# Cleanup from previous run
tmux kill-session -t "$SESSION" 2>/dev/null || true

echo "=== H1: Direct Command Arg ==="

# Create session with direct command — env vars should be inherited
tmux new-session -d -s "$SESSION" -c /tmp \
    "echo GH_TOKEN=\$GH_TOKEN && echo PATH=\$PATH && sleep 10" \; \
    set-option -p -t "$SESSION" remain-on-exit on

# Wait for command to execute
sleep 1

# Capture pane content
OUTPUT=$(tmux capture-pane -p -t "$SESSION")

echo "--- Captured output ---"
echo "$OUTPUT"
echo "--- End ---"

# Check GH_TOKEN
if echo "$OUTPUT" | grep -q "GH_TOKEN=ghp_"; then
    echo "PASS: GH_TOKEN inherited"
else
    echo "FAIL: GH_TOKEN not found or empty"
    RESULT=1
fi

# Check PATH
if echo "$OUTPUT" | grep -q "PATH=/"; then
    echo "PASS: PATH inherited"
else
    echo "FAIL: PATH not found"
    RESULT=1
fi

# Cleanup
tmux kill-session -t "$SESSION" 2>/dev/null || true

if [ $RESULT -eq 0 ]; then
    echo "=== H1 CONFIRMED ==="
else
    echo "=== H1 FAILED ==="
fi

exit $RESULT
