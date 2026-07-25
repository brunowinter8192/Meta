#!/bin/bash
# log_permission_request.sh — Logs PermissionRequest hook input to file for inspection
# Install: Add to ~/.claude/settings.json under hooks.PermissionRequest
# Output: /tmp/permission_request_log.jsonl (one JSON object per line)

INPUT=$(cat)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_FILE="/tmp/permission_request_log.jsonl"

# Append timestamped input to log
echo "{\"timestamp\":\"$TIMESTAMP\",\"input\":$INPUT}" >> "$LOG_FILE"

# Pass through — don't interfere with normal permission flow
exit 0
