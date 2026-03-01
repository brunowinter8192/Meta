#!/bin/bash
# Sync local plugin repo to Claude Code plugin cache.
# Bypasses /plugin install — direct, reliable, no version-check issues.
#
# Usage: plugin-sync.sh <plugin-name> <local-repo-path>
# Example: plugin-sync.sh rag ~/Documents/ai/Meta/ClaudeCode/MCP/RAG

set -euo pipefail

MARKETPLACE="brunowinter-plugins"
CACHE_BASE="$HOME/.claude/plugins/cache/$MARKETPLACE"
INSTALLED_JSON="$HOME/.claude/plugins/installed_plugins.json"

# --- Validate args ---

if [ $# -ne 2 ]; then
    echo "Usage: plugin-sync.sh <plugin-name> <local-repo-path>"
    echo "Example: plugin-sync.sh rag ~/Documents/ai/Meta/ClaudeCode/MCP/RAG"
    exit 1
fi

PLUGIN_NAME="$1"
REPO_PATH="$(cd "$2" && pwd)"

if [ ! -d "$REPO_PATH" ]; then
    echo "ERROR: Repo path does not exist: $2"
    exit 1
fi

PLUGIN_JSON="$REPO_PATH/.claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
    echo "ERROR: No .claude-plugin/plugin.json found in $REPO_PATH"
    exit 1
fi

# --- Read version from plugin.json ---

VERSION=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])")
CACHE_DIR="$CACHE_BASE/$PLUGIN_NAME/$VERSION"

if [ ! -d "$CACHE_DIR" ]; then
    echo "ERROR: Cache directory does not exist: $CACHE_DIR"
    echo "Plugin '$PLUGIN_NAME' v$VERSION not installed. Run /plugin install first."
    exit 1
fi

# --- Sync files ---

echo "Syncing $PLUGIN_NAME v$VERSION..."
echo "  From: $REPO_PATH"
echo "  To:   $CACHE_DIR"

# Protect runtime artifacts in cache (venv, data, models) from deletion.
# Only sync git-tracked source files + plugin config.
rsync -av \
    --exclude='.git' \
    --exclude='venv/' --exclude='.venv/' \
    --exclude='__pycache__/' --exclude='*.pyc' \
    --exclude='.env' --exclude='.env.local' \
    --exclude='.beads/' --exclude='.claude/' \
    --exclude='.DS_Store' \
    --exclude='data/' --exclude='debug/' \
    --exclude='logs/' --exclude='*.log' \
    --exclude='models/' --exclude='node_modules/' \
    --delete \
    "$REPO_PATH/" "$CACHE_DIR/"

# --- Update installed_plugins.json ---

SHA=$(cd "$REPO_PATH" && git rev-parse HEAD)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

python3 -c "
import json

with open('$INSTALLED_JSON') as f:
    data = json.load(f)

key = '${PLUGIN_NAME}@${MARKETPLACE}'
if key not in data.get('plugins', {}):
    print(f'WARNING: {key} not found in installed_plugins.json')
else:
    for entry in data['plugins'][key]:
        entry['gitCommitSha'] = '$SHA'
        entry['lastUpdated'] = '$TIMESTAMP'

    with open('$INSTALLED_JSON', 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')

    print(f'Updated metadata: SHA={\"$SHA\"[:8]}, timestamp=$TIMESTAMP')
"

echo ""
echo "Done. Start a new Claude Code session to pick up changes."
