#!/usr/bin/env bash
# tmux_spawn.sh — Spawn Claude Code sessions in tmux with Ghostty viewer.
#
# Architecture: One tmux session per worker (session name = "worker-<project>-<name>").
# Project-scoped: workers from different projects never collide.
# Each Ghostty window attaches to its own session — no sync, no zombies.
# Direct command arg to tmux new-session (no shell-ready polling).
# remain-on-exit on for status detection via #{pane_dead}.
#
# Usage: source this file, then call spawn_claude_worker.
#
# Orchestration: worker_list, worker_status, worker_capture, worker_send allow
# the main agent to monitor and interact with running workers.

set -euo pipefail

# --- Constants ---
_ORCHESTRATOR_SIGNALS_FILE="$HOME/Library/Application Support/com.brunowinter.monitor-cc-menubar/orchestrator_signals.json"

# --- Helpers ---

# _orchestrator_signal_update SESSION_NAME
#   Update the orchestrator-signal file: set signals[SESSION_NAME] = now, prune entries > 1h.
#   Atomic write via tmp + os.replace. Failures are non-fatal — signal is a hint to the menubar,
#   not a correctness requirement for worker delivery. Menubar treats workers without signals
#   normally (falls through to hook-state for status).
_orchestrator_signal_update() {
    local session_name="$1"
    python3 - "$_ORCHESTRATOR_SIGNALS_FILE" "$session_name" <<'PYEOF' 2>/dev/null || true
import json, os, sys, time
path, key = sys.argv[1], sys.argv[2]
now = time.time()
try:
    data = json.loads(open(path).read())
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, json.JSONDecodeError, OSError):
    data = {}
# prune entries > 1h old (excluding the one we're about to set)
data = {k: float(v) for k, v in data.items()
        if isinstance(v, (int, float)) and (now - float(v)) < 3600 and k != key}
data[key] = now
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f)
os.replace(tmp, path)
PYEOF
}

# _orchestrator_signal_delete SESSION_NAME
#   Remove the signal entry for SESSION_NAME (used on worker kill).
_orchestrator_signal_delete() {
    local session_name="$1"
    python3 - "$_ORCHESTRATOR_SIGNALS_FILE" "$session_name" <<'PYEOF' 2>/dev/null || true
import json, os, sys, time
path, key = sys.argv[1], sys.argv[2]
try:
    raw = open(path).read()
    data = json.loads(raw)
    if not isinstance(data, dict):
        sys.exit(0)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    sys.exit(0)
data.pop(key, None)
# prune > 1h old entries while we are touching the file
now = time.time()
data = {k: float(v) for k, v in data.items()
        if isinstance(v, (int, float)) and (now - float(v)) < 3600}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f)
os.replace(tmp, path)
PYEOF
}

# _worker_project_name PROJECT_PATH
#   Derives project name from project path.
#   Strips .claude/worktrees/<name> suffix if path is a worktree.
#   Example: /path/to/RAG/.claude/worktrees/foo → RAG
#   Example: /path/to/RAG → RAG
_worker_project_name() {
    local project_path="$1"
    if [[ "$project_path" == */.claude/worktrees/* ]]; then
        basename "$(echo "$project_path" | sed 's|/.claude/worktrees/.*||')"
    else
        basename "$project_path"
    fi
}

# _worker_session_name PROJECT_PATH NAME
#   Returns the full tmux session name: "worker-<project>-<name>"
_worker_session_name() {
    local project_path="$1"
    local name="$2"
    local project
    project=$(_worker_project_name "$project_path")
    echo "worker-${project}-${name}"
}

# --- Orchestration ---

# _worker_detect_status SESSION
#   Returns status: working, idle, or dead — a closed three-value vocabulary (2026-09-02).
#   Shared logic used by worker_list and worker_status.
#   'dead': cannot accept a message anymore — tmux session gone (caller-side, see
#   worker_status), #{pane_dead}=1, no claude descendant under the pane pid, or the
#   session JSONL's last assistant message is Claude Code's client-side context-limit
#   marker (anthropics/claude-code #90113, #23377: message.model=="<synthetic>" + text
#   "Prompt is too long" + isApiErrorMessage=true + error="invalid_request" — every later
#   input fails the same way until /compact or /clear).
#   'idle': hooks.json status idle (Stop hook fired), OR status working but
#   #{window_activity} stale > 10s — the ESC-interrupt case: process alive, Stop hook
#   never fired, pane quiet. Same 10s rule applies when there is no hook data at all
#   (fresh spawn pre-JSONL, no hook entry, unreadable hooks file) — a quiet pane with no
#   data is still read as idle, not as a distinct placeholder state.
#   'working': the default — hook status working with fresh activity, or no dead signal
#   and no idle signal (including every case that used to report "unknown").
_worker_detect_status() {
    local session="$1"

    local dead
    dead=$(tmux display-message -t "${session}:^" -p "#{pane_dead}" 2>/dev/null || echo "?")
    if [ "$dead" = "1" ]; then
        echo "dead"
        return 0
    fi
    # dead != "0" means the pane query itself failed (tmux hiccup) — no positive dead
    # signal fired, fall through to the rest of the checks (fail-open toward "working").

    # Process-tree check: pane_dead is 0 in our zsh/bash-wrapped CC setup even
    # after Claude exits (shell keeps the pane alive). The reliable signal is
    # whether a `claude` descendant of the pane PID still exists. If none →
    # CC has exited (context-limit death, crash, manual quit) — "dead".
    local pane_pid
    pane_pid=$(tmux display-message -t "${session}:^" -p "#{pane_pid}" 2>/dev/null || true)
    if [ -n "$pane_pid" ]; then
        local children
        children=$(pgrep -P "$pane_pid" 2>/dev/null || true)
        if [ -z "$children" ]; then
            echo "dead"
            return 0
        fi
        local has_claude=0
        for cpid in $children; do
            if ps -o command= -p "$cpid" 2>/dev/null | grep -q "claude"; then
                has_claude=1
                break
            fi
        done
        if [ "$has_claude" = "0" ]; then
            echo "dead"
            return 0
        fi
    fi

    # Resolve the session JSONL once — reused below for both the context-limit marker
    # check and the hooks.json lookup.
    local worktree encoded jsonl session_id
    worktree=$(tmux display-message -t "${session}:^" -p "#{pane_current_path}" 2>/dev/null || true)
    if [ -n "$worktree" ]; then
        # CC encoding: replace /, _, . with - (matches Monitor_CC/src/session_finder.py:encode_project_path).
        encoded=$(echo "$worktree" | tr '/_.' '-')
        jsonl=$(ls -t "$HOME/.claude/projects/${encoded}"/*.jsonl 2>/dev/null | head -1 || true)
    fi

    # Context-limit marker check: the LAST assistant-type entry in the JSONL (not
    # necessarily the last line of the file) is the synthetic rejection Claude Code
    # writes when it blocks a turn for prompt length — the worker cannot take another
    # message until the user runs /compact or /clear, so this counts as "dead".
    if [ -n "${jsonl:-}" ] && [ -f "$jsonl" ]; then
        local last_assistant
        last_assistant=$(jq -c -s '[.[] | select(.type=="assistant")] | last // empty' "$jsonl" 2>/dev/null || true)
        if [ -n "$last_assistant" ] && [ "$last_assistant" != "null" ]; then
            local marker_model marker_is_err marker_err marker_text
            marker_model=$(echo "$last_assistant" | jq -r '.message.model // empty' 2>/dev/null || true)
            marker_is_err=$(echo "$last_assistant" | jq -r '.isApiErrorMessage // false' 2>/dev/null || true)
            marker_err=$(echo "$last_assistant" | jq -r '.error // empty' 2>/dev/null || true)
            marker_text=$(echo "$last_assistant" | jq -r '[.message.content[]? | select(.type=="text") | .text] | join(" ")' 2>/dev/null || true)
            if [ "$marker_model" = "<synthetic>" ] && [ "$marker_is_err" = "true" ] \
                && [ "$marker_err" = "invalid_request" ] && [[ "$marker_text" == *"Prompt is too long"* ]]; then
                echo "dead"
                return 0
            fi
        fi
    fi

    # hooks.json status — idle is always idle; working (or no data at all: fresh spawn,
    # no hook entry, unreadable hooks file) shares the same window_activity check below.
    local hook_status=""
    if [ -n "${jsonl:-}" ]; then
        session_id=$(basename "$jsonl" .jsonl)
        local hook_file="$HOME/Library/Application Support/com.brunowinter.monitor-cc-menubar/hooks.json"
        hook_status=$(jq -r --arg sid "$session_id" '.[$sid].status // ""' "$hook_file" 2>/dev/null || true)
        [ "$hook_status" = "null" ] && hook_status=""
    fi
    if [ "$hook_status" = "idle" ]; then
        echo "idle"
        return 0
    fi

    # Demote to 'idle' when the pane has been inactive > 10s — applies whether hook
    # status is "working" or entirely absent (ESC-interrupt / crash / no-data-yet all
    # read the same way: process alive, pane quiet). Mirrors menubar discover.py:178-181
    # (WORKING_THRESHOLD_SECS=10, #{window_activity}). Fail-open: activity unreadable or
    # non-positive → default "working".
    local wa now_ts
    wa=$(tmux display-message -t "${session}:^" -p "#{window_activity}" 2>/dev/null || true)
    if [[ "$wa" =~ ^[0-9]+$ ]] && [ "$wa" -gt 0 ]; then
        now_ts=$(date +%s)
        if [ $((now_ts - wa)) -gt 10 ]; then
            echo "idle"
            return 0
        fi
    fi
    echo "working"
}

# worker_list [PROJECT_PATH]
#   Lists active worker sessions for the given project (default: pwd).
#   Output: NAME  STATUS  SPAWNED  PURPOSE per line (STATUS: working/idle/dead).
worker_list() {
    local project_path="${1:-$(pwd)}"
    local project
    project=$(_worker_project_name "$project_path")
    local prefix="worker-${project}-"
    local sessions
    sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null \
        | grep "^${prefix}" || true)

    if [ -z "$sessions" ]; then
        return 0
    fi

    while IFS= read -r session_name; do
        local name="${session_name#$prefix}"
        local status
        status=$(_worker_detect_status "$session_name" 2>/dev/null || echo "working")
        local spawned
        spawned=$(tmux show-environment -t "$session_name" WORKER_SPAWNED 2>/dev/null | cut -d= -f2)
        [ -z "$spawned" ] && spawned="(?)"
        local purpose
        purpose=$(tmux show-environment -t "$session_name" WORKER_PURPOSE 2>/dev/null | cut -d= -f2)
        [ -z "$purpose" ] && purpose="(?)"
        echo "$name  $status  $spawned  $purpose"
    done <<< "$sessions"
}

# worker_status NAME [PROJECT_PATH]
#   Returns status: working, idle, or dead.
#   working = Claude Code is actively processing (the default; also every no-data case)
#   idle = waiting for input — Stop hook fired, or process alive with a quiet pane (ESC)
#   dead = cannot accept a message anymore — no session, pane dead, no claude child, or
#   the JSONL's last assistant message is the context-limit marker
worker_status() {
    local name="$1"
    local project_path="${2:-$(pwd)}"
    local session
    session=$(_worker_session_name "$project_path" "$name")

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "dead"
        return 0
    fi

    local raw
    raw=$(_worker_detect_status "$session")
    echo "$raw"
}

# worker_capture NAME [LINES] [PROJECT_PATH]
#   Captures worker pane content to /tmp/worker-<name>-pane.txt.
#   LINES: number of scrollback lines to capture (default: all).
#   PROJECT_PATH: project the worker belongs to (default: pwd).
#   Returns: path to the capture file.
worker_capture() {
    local name="$1"
    local lines="${2:-}"
    local project_path="${3:-$(pwd)}"
    local session
    session=$(_worker_session_name "$project_path" "$name")
    local outfile="/tmp/worker-${name}-pane.txt"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "ERROR: No session '$session'" >&2
        return 1
    fi

    local pane_id
    pane_id=$(tmux list-panes -t "$session" -F "#{pane_id}" | head -1)

    if [ -n "$lines" ]; then
        tmux capture-pane -p -t "$pane_id" -S "-${lines}" > "$outfile"
    else
        tmux capture-pane -p -t "$pane_id" -S - > "$outfile"
    fi

    echo "$outfile"
}

# worker_capture_clean NAME [PROJECT_PATH]
#   Captures worker pane, scopes to output since last real orchestrator prompt (❯ with content),
#   applies clean filter (boot box, spinners, diff hunks, widget chrome), prints to stdout.
#   Output shape: "=== capture from <name> (since last prompt, N chars) ===" + cleaned body.
#   Fallback: if no ❯ prompt marker in scrollback → prints full cleaned buffer + warning.
#   Uses _capture_clean.py (same dir as this script) for the scope + filter logic.
worker_capture_clean() {
    local name="$1"
    local project_path="${2:-$(pwd)}"
    local session
    session=$(_worker_session_name "$project_path" "$name")

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "ERROR: No session '$session'" >&2
        return 1
    fi

    local clean_script
    clean_script="$(dirname "${BASH_SOURCE[0]}")/_capture_clean.py"
    if [ ! -f "$clean_script" ]; then
        echo "ERROR: _capture_clean.py not found at $clean_script" >&2
        return 1
    fi

    local pane_id pane_file
    pane_id=$(tmux list-panes -t "$session" -F "#{pane_id}" | head -1)
    pane_file=$(mktemp "/tmp/.cap_pane_${name}_XXXXXX.txt")

    tmux capture-pane -p -t "$pane_id" -S - > "$pane_file"
    python3 "$clean_script" "$pane_file" "$name"
    local exit_code=$?
    rm -f "$pane_file"
    return $exit_code
}

# worker_send NAME MESSAGE [PROJECT_PATH]
#   Sends text input to a running worker's tmux pane (followed by Enter).
#   PROJECT_PATH: project the worker belongs to (default: pwd).
worker_send() {
    local name="$1"
    local message="$2"
    local project_path="${3:-$(pwd)}"
    local session
    session=$(_worker_session_name "$project_path" "$name")

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "ERROR: No session '$session'" >&2
        return 1
    fi

    local pane_id
    pane_id=$(tmux list-panes -t "$session" -F "#{pane_id}" | head -1)

    # Signal the orchestrator-send event BEFORE delivering the keys. The Monitor_CC menubar
    # treats workers with a recent signal as 'working' for auto-abort, bridging the latency
    # window between this tmux send-keys and CC's UserPromptSubmit hook firing — see
    # Monitor_CC process-docs (menubar signal grace).
    _orchestrator_signal_update "$session"

    # Paste message, then send Enter as key event.
    # Claude Code TUI ignores pasted newlines as submit — needs real key event.
    # Sleep prevents race condition where Enter arrives before paste completes.
    printf '%s' "$message" | tmux load-buffer -
    tmux paste-buffer -d -t "$pane_id"
    sleep 0.2
    tmux send-keys -t "$pane_id" Enter
}

# --- Functions ---

# open_tmux_viewer SESSION
#   Opens a new Ghostty window and attaches to the tmux session.
#   Ghostty 1.3+: Uses native AppleScript API (PR #11208).
#   Ghostty 1.2.x: Falls back to open -na with isolation flags.
open_tmux_viewer() {
    local session="$1"

    local ghostty_version
    ghostty_version=$(ghostty +version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' || echo "0.0")
    local major minor
    major=$(echo "$ghostty_version" | cut -d. -f1)
    minor=$(echo "$ghostty_version" | cut -d. -f2)

    if [ "$major" -ge 2 ] || { [ "$major" -ge 1 ] && [ "$minor" -ge 3 ]; }; then
        # Ghostty 1.3+: native AppleScript
        osascript -e "
tell application \"Ghostty\"
    activate
    set win to new window
    set t to terminal 1 of selected tab of win
    input text \"tmux attach -t $session; exit\" to t
    send key \"enter\" to t
end tell
"
    else
        # Ghostty 1.2.x: -e expects separate args, not a quoted string
        open -na Ghostty.app --args \
            --quit-after-last-window-closed=true \
            --window-save-state=never \
            -e tmux attach -t "$session"
    fi

}

# _start_worker_logger NAME SESSION EVENT
#   Spawn the diagnostic logger sidecar in background. Samples every 10s; on detected
#   pane_dead writes a forensic snapshot. Writes its own PID to /tmp/worker-logger-<name>.pid
#   so _stop_worker_logger can clean it up.
#
#   EVENT is "spawn" or "revive" — only affects the log filename suffix.
#
#   Log dir defaults to ~/Documents/ai/Meta/blank/src/logs (user's plugin source); override
#   via WORKER_LOGGER_DIR env var. Plugin runs from cache but logs go to source-repo dir so
#   they survive plugin-publish overwrites.
_start_worker_logger() {
    local name="$1"
    local session="$2"
    local event="${3:-spawn}"
    local logger_script
    logger_script="$(dirname "${BASH_SOURCE[0]}")/worker_logger.sh"
    if [ ! -x "$logger_script" ]; then
        # Logger missing — non-fatal, just skip
        return 0
    fi
    local log_dir="${WORKER_LOGGER_DIR:-$HOME/Documents/ai/Meta/blank/src/logs}"
    mkdir -p "$log_dir"
    # Start in background, fully detached so the logger survives worker_spawn returning
    nohup "$logger_script" "$name" "$session" "$log_dir" "$event" \
        >/dev/null 2>&1 &
    disown
}

# _stop_worker_logger NAME
#   Stop the diagnostic logger sidecar via PID file (best-effort).
_stop_worker_logger() {
    local name="$1"
    local pid_file="/tmp/worker-logger-${name}.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || echo "")
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi
}


# _worker_proxy_setup NAME PROJECT_PATH
#   Sets up a worker-specific mitmproxy if the Monitor_CC proxy marker is present.
#   The proxy is needed so the worker's claude --resume hits the same per-project
#   marker prefix as the main session — without it the prompt-cache prefix changes
#   and Anthropic sees a full cache miss, forcing a complete re-upload of context.
#
#   Reads /tmp/.monitor_cc_proxy_<session_id> (line 1 = main_port, line 3 = MONITOR_CC_ROOT).
#   Starts mitmdump in background on (main_port + N) with a per-worker live-copy of
#   the addon (live-copy prevents hot-reload bashing the main proxy).
#
#   Writes results to global vars (consumed by both spawn and revive):
#     WORKER_PROXY_PID            — pid of mitmdump or empty if no proxy
#     WORKER_PROXY_ENV_PREFIX     — env-var string to prefix the claude command, or empty
#     WORKER_PROXY_LIVE_ADDON     — path to live-copy addon file (for cleanup) or empty
#     WORKER_PROXY_LIVE_DIR       — path to live-copy proxy dir (for cleanup) or empty
#
#   Returns 0 always (including no-proxy-active case); 1 only on dedup error (live addon
#   already in use by another mitmdump — caller should refuse to spawn).
_worker_proxy_setup() {
    local name="$1"
    local project_path="$2"

    # Reset globals
    WORKER_PROXY_PID=""
    WORKER_PROXY_ENV_PREFIX=""
    WORKER_PROXY_LIVE_ADDON=""
    WORKER_PROXY_LIVE_DIR=""

    # Detect mitmproxy: strip worktree suffix to get original project path for hash
    local proxy_project_path="$project_path"
    if [[ "$project_path" == */.claude/worktrees/* ]]; then
        proxy_project_path="${project_path%%/.claude/worktrees/*}"
    fi
    local proxy_session_id
    if command -v md5 >/dev/null 2>&1; then
        proxy_session_id=$(echo -n "$proxy_project_path" | md5 | head -c 8)
    else
        proxy_session_id=$(echo -n "$proxy_project_path" | md5sum | head -c 8)
    fi
    local proxy_marker="/tmp/.monitor_cc_proxy_${proxy_session_id}"
    [ ! -f "$proxy_marker" ] && return 0

    local main_port monitor_cc_root
    main_port=$(sed -n '1p' "$proxy_marker")
    monitor_cc_root=$(sed -n '3p' "$proxy_marker")
    if [ -z "$monitor_cc_root" ] || [ ! -d "$monitor_cc_root" ]; then
        # Marker exists but no MONITOR_CC_ROOT (old format) — skip proxy setup
        return 0
    fi

    # Find a free port starting at main_port + 1
    local worker_port=$((main_port + 1))
    while lsof -iTCP:${worker_port} -sTCP:LISTEN >/dev/null 2>&1; do
        worker_port=$((worker_port + 1))
    done
    # Generate human-readable log id: worker_{project_session_id}_{name}_{timestamp}
    # project_session_id scopes this log to the active project (mirrors _proxy_session_id_for_project in parser.py)
    local worker_log_id="worker_${proxy_session_id}_${name}_$(date +%s)"
    # Start worker-specific mitmproxy in background (live-copy to prevent hot-reload)
    local log_dir="${monitor_cc_root}/src/logs"
    mkdir -p "$log_dir"
    local worker_live_id="worker_${name}"
    local worker_live_addon_path="${log_dir}/.proxy_addon_live_${worker_live_id}.py"
    local worker_live_dir_path="${log_dir}/.proxy_live_${worker_live_id}"
    # Dedup guard: if this worker's live-copy already exists AND a mitmdump process is
    # still using it, abort rather than overwriting (which would hot-reload the running proxy).
    if [ -f "$worker_live_addon_path" ] && lsof "$worker_live_addon_path" >/dev/null 2>&1; then
        echo "ERROR: Worker proxy for '$name' is already running (live addon in use)." >&2
        echo "  Kill the existing '$name' worker or choose a different name." >&2
        return 1
    fi
    cp "${monitor_cc_root}/src/proxy_addon.py" "$worker_live_addon_path"
    mkdir -p "$worker_live_dir_path"
    cp -r "${monitor_cc_root}/src/proxy" "$worker_live_dir_path/"
    MONITOR_CC_ROOT="$monitor_cc_root" PROXY_LOG_ID="$worker_log_id" \
        PROXY_PROJECT_PATH="$proxy_project_path" \
        mitmdump -p "$worker_port" -s "$worker_live_addon_path" \
        --set flow_detail=0 -q \
        >/dev/null 2>"${log_dir}/proxy_errors_${worker_log_id}.log" &
    WORKER_PROXY_PID=$!
    WORKER_PROXY_LIVE_ADDON="$worker_live_addon_path"
    WORKER_PROXY_LIVE_DIR="$worker_live_dir_path"
    WORKER_PROXY_ENV_PREFIX="HTTPS_PROXY=http://localhost:${worker_port} NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem SSL_CERT_FILE=~/.mitmproxy/combined-ca.pem REQUESTS_CA_BUNDLE=~/.mitmproxy/combined-ca.pem "
    return 0
}


# _resolve_worker_model
#   Returns the worker model to use when no explicit model argument was given: the "worker"
#   key from ~/.claude/shared-rules/model_selection.json (menubar Models tab, 2026-08 model-
#   selector milestone 3) if present and non-empty, else the hardcoded fallback "claude-sonnet-5".
#   Never fails under set -e — jq's own failure is caught with the same `|| true` idiom already
#   used for the hooks.json read above; a missing/unreadable/malformed file, missing jq, or a
#   missing/empty "worker" key all degrade silently to the hardcoded fallback.
#   NOTE: for `worker-cli spawn`, spawn.py resolves the model in Python BEFORE ever calling into
#   this file, so this function is not exercised on that path — it's load-bearing for (a) a
#   direct caller of spawn_claude_worker/spawn_claude_worker_from_file that omits the model
#   argument, and (b) worker_revive's own fallback when WORKER_MODEL is absent from the tmux
#   environment (see worker_revive below — the stored WORKER_MODEL always wins over this).
_resolve_worker_model() {
    local file="${MODEL_SELECTION_FILE:-$HOME/.claude/shared-rules/model_selection.json}"
    local worker=""
    if command -v jq >/dev/null 2>&1 && [ -f "$file" ]; then
        worker=$(jq -r '.worker // empty' "$file" 2>/dev/null || true)
    fi
    if [ -n "$worker" ]; then
        echo "$worker"
    else
        echo "claude-sonnet-5"
    fi
}


# spawn_claude_worker SESSION_IGNORED NAME PROJECT_PATH MODEL TASK_PROMPT [EXTRA_FLAGS]
#   Spawns Claude Code in its own tmux session ("worker-<project>-<name>").
#   Opens a Ghostty window to view the session.
#
#   Note: SESSION parameter is kept for API compatibility but ignored.
#   Each worker gets its own session named "worker-<project>-<name>".
#   Project prefix is derived from basename of PROJECT_PATH (worktree-aware).
#
#   Uses direct command arg to tmux new-session (no shell-ready polling).
#   Sets remain-on-exit on for status detection via #{pane_dead}.
spawn_claude_worker() {
    local _session_ignored="${1:-}"
    local name="$2"
    local project_path="$3"
    local model="${4:-$(_resolve_worker_model)}"
    local task_prompt="$5"
    local extra_flags="${6:---dangerously-skip-permissions}"

    local session
    session=$(_worker_session_name "$project_path" "$name")

    # Kill existing session with same name (clean restart for THIS project + worker name)
    tmux kill-session -t "$session" 2>/dev/null || true

    # Write prompt to temp file to avoid shell escaping issues
    local prompt_file="/tmp/spawn-prompt-${name}-$$.txt"
    echo "$task_prompt" > "$prompt_file"

    # Set up worker-specific mitmproxy via shared helper (populates WORKER_PROXY_* globals)
    _worker_proxy_setup "$name" "$project_path" || return 1
    local proxy_env_prefix="$WORKER_PROXY_ENV_PREFIX"
    local worker_proxy_pid="$WORKER_PROXY_PID"
    local worker_live_addon="$WORKER_PROXY_LIVE_ADDON"
    local worker_live_dir="$WORKER_PROXY_LIVE_DIR"

    # Build a runner script so trap fires reliably on EXIT/INT/TERM/HUP regardless
    # of how the tmux pane shell is killed (tmux kill-session sends SIGHUP, which
    # cuts the ; chain before cleanup commands can run).
    local worker_claude_bin="${CLAUDE_BIN:-$HOME/.local/bin/claude-223}"
    local runner
    runner=$(mktemp "/tmp/.worker_${name}.XXXXXX")
    cat > "$runner" <<RUNSCRIPT
#!/usr/bin/env bash
_cleanup() {
    [ -n '${worker_proxy_pid}' ] && kill '${worker_proxy_pid}' 2>/dev/null || true
    [ -n '${worker_live_addon}' ] && rm -f '${worker_live_addon}' || true
    [ -n '${worker_live_dir}' ]   && rm -rf '${worker_live_dir}' || true
    touch '/tmp/worker-${name}.done'
    rm -f '${runner}'
}
trap _cleanup EXIT INT TERM HUP
cd '${project_path}'
${proxy_env_prefix}${worker_claude_bin} --model '${model}' ${extra_flags}
RUNSCRIPT
    local claude_cmd="bash '${runner}'"

    # Create session with command as direct arg (no polling needed).
    # Atomic remain-on-exit via ; chain — set before process can exit.
    # 50000-line history so a long worker turn never scrolls off the top of the scrollback
    # before worker_capture_clean can find the ❯ prompt anchor.
    tmux new-session -d -s "$session" "$claude_cmd" \; \
        set-option -p -t "$session" remain-on-exit on \; \
        set-option -t "$session" history-limit 50000

    # Write orchestrator signal for menubar grace (Fix A: spawn-case protection).
    # Same mechanism as worker_send — covers initial thinking phase before first JSONL
    # write. Without this, menubar's stale-JSONL demote kills Opus bg timers during
    # the fresh-worker thinking window. See Monitor_CC process-docs (menubar signal grace).
    _orchestrator_signal_update "$session"

    # Store spawn metadata for worker_list display
    tmux set-environment -t "$session" WORKER_SPAWNED "$(date +%H:%M)"
    local purpose
    purpose=$(echo "$task_prompt" | grep -m1 "^# " | sed 's/^# //' || echo "")
    [ -z "$purpose" ] && purpose="(?)"
    tmux set-environment -t "$session" WORKER_PURPOSE "$purpose"
    tmux set-environment -t "$session" WORKER_PARENT "${CLAUDE_SESSION_ID:-unknown}"
    tmux set-environment -t "$session" WORKER_MODEL "$model"

    # Start diagnostic logger sidecar (samples + death-snapshot)
    _start_worker_logger "$name" "$session" "spawn"

    # Open Ghostty window attached to this worker's session
    open_tmux_viewer "$session" &

    # Readiness gate: poll until CC shows its input prompt (❯ at col 0).
    # CC writes no JSONL before the first prompt — the pane content is the only
    # pre-input signal. ❯ (U+276F) at line start = input box ready; the trust-dir
    # dialog uses " ❯ 1." (leading space) and does NOT match ^❯, so a trust dialog
    # in an untrusted dir causes gate timeout → explicit failure rather than silent
    # injection into a dialog. FRAGILITY: if CC changes this glyph, gate times out
    # and spawn fails explicitly — update the grep pattern to match.
    local _pane_id _deadline
    _pane_id=$(tmux list-panes -t "$session" -F "#{pane_id}" | head -1)
    _deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$_deadline" ]; do
        tmux capture-pane -p -t "$_pane_id" 2>/dev/null | grep -q '^❯' && break
        sleep 0.3
    done
    if ! tmux capture-pane -p -t "$_pane_id" 2>/dev/null | grep -q '^❯'; then
        echo "spawn_claude_worker: CC did not reach input-ready state within 30s (session=$session)" >&2
        rm -f "$prompt_file"
        return 1
    fi

    # Inject prompt via paste — same mechanism as worker_send.
    # Prompt text never touches the claude cmdline; pane content only.
    printf '%s' "$task_prompt" | tmux load-buffer -
    tmux paste-buffer -d -t "$_pane_id"
    sleep 0.2
    tmux send-keys -t "$_pane_id" Enter
    rm -f "$prompt_file"

    # Return session name (pane_id no longer needed — use session:^ for queries)
    echo "$session"
}

# spawn_claude_worker_from_file SESSION NAME PROJECT_PATH MODEL PROMPT_FILE [EXTRA_FLAGS]
#   Like spawn_claude_worker, but reads the task prompt from a file instead of
#   an argument. Avoids shell escaping issues with complex multi-line prompts.
spawn_claude_worker_from_file() {
    local session="${1:-}"
    local name="$2"
    local project_path="$3"
    local model="${4:-$(_resolve_worker_model)}"
    local prompt_file="$5"
    local extra_flags="${6:---dangerously-skip-permissions}"

    if [ ! -f "$prompt_file" ]; then
        echo "ERROR: Prompt file not found: $prompt_file" >&2
        return 1
    fi

    local task_prompt
    task_prompt=$(cat "$prompt_file")

    spawn_claude_worker "$session" "$name" "$project_path" "$model" "$task_prompt" "$extra_flags"
}


# worker_revive NAME PROJECT_PATH
#   Reanimate a worker whose pane died (tmux session still exists, pane_dead=1).
#   Uses claude --resume with the session's stored JSONL to restore full conversation
#   context. CRITICAL: sets up the same mitmproxy as spawn (via _worker_proxy_setup),
#   so the prompt-cache prefix matches what Anthropic saw before the death — without
#   this the cache invalidates and the entire conversation context gets re-uploaded.
#
#   Gates (return 2 + message on failure):
#     1. tmux session must exist (else: worker was killed, use spawn)
#     2. pane must be dead (else: worker alive, use send)
#     3. worktree dir must exist
#     4. session JSONL must exist
#
#   Restores stored env vars: WORKER_MODEL, WORKER_PURPOSE, WORKER_PARENT.
#   Re-installs pane-died hook for death-log writing.
#   Opens viewer window.
worker_revive() {
    local name="$1"
    local project_path="$2"
    local session
    session=$(_worker_session_name "$project_path" "$name")

    # Gate 1: tmux session must exist
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "worker_revive: session '$session' not found — worker was fully killed; use 'spawn'" >&2
        return 2
    fi

    # Gate 2: pane must be dead
    local pane_dead
    pane_dead=$(tmux display-message -t "${session}:^" -p "#{pane_dead}" 2>/dev/null || echo "?")
    if [ "$pane_dead" = "0" ]; then
        echo "worker_revive: worker '$name' is still running — use 'send'" >&2
        return 2
    elif [ "$pane_dead" != "1" ]; then
        echo "worker_revive: cannot determine pane state for '$session' (got: $pane_dead)" >&2
        return 2
    fi

    # Gate 3: worktree must exist
    local worktree
    if [[ "$project_path" == */.claude/worktrees/* ]]; then
        # Caller passed a worktree path directly; respect it
        worktree="$project_path"
    else
        worktree="$project_path/.claude/worktrees/$name"
    fi
    if [ ! -d "$worktree" ]; then
        echo "worker_revive: worktree not found at $worktree — revive not possible" >&2
        return 2
    fi

    # Gate 4: session JSONL must exist
    # Claude Code encoding of paths: '/' -> '-', '.' -> '-', '_' -> '-'
    local encoded jsonl encoded_dir
    encoded="$worktree"
    encoded="${encoded//\//-}"
    encoded="${encoded//\./-}"
    encoded="${encoded//_/-}"
    encoded_dir="$HOME/.claude/projects/$encoded"
    jsonl=$(ls -t "$encoded_dir"/*.jsonl 2>/dev/null | head -1)
    if [ -z "$jsonl" ]; then
        echo "worker_revive: no session JSONL found at $encoded_dir — context lost; use 'spawn'" >&2
        return 2
    fi
    local session_id
    session_id=$(basename "$jsonl" .jsonl)

    # Restore stored env vars from the dead session BEFORE killing it.
    # The stored WORKER_MODEL always wins when present — revive's job is to restore the model
    # the worker was ORIGINALLY spawned with, not to re-apply a possibly-since-changed config.
    # The config (then the hardcoded fallback) only applies when WORKER_MODEL itself is absent.
    local model purpose parent
    model=$(tmux show-environment -t "$session" WORKER_MODEL 2>/dev/null | cut -d= -f2-)
    [ -z "$model" ] && model="$(_resolve_worker_model)"
    purpose=$(tmux show-environment -t "$session" WORKER_PURPOSE 2>/dev/null | cut -d= -f2-)
    [ -z "$purpose" ] && purpose="(?)"
    parent=$(tmux show-environment -t "$session" WORKER_PARENT 2>/dev/null | cut -d= -f2-)
    [ -z "$parent" ] && parent="unknown"

    echo "Reviving $name (session-id $session_id, model $model)"

    # Kill the dead session before recreating
    tmux kill-session -t "$session" 2>/dev/null || true

    # Set up worker-specific mitmproxy — SAME helper as spawn, ensures cache prefix matches
    _worker_proxy_setup "$name" "$project_path" || return 1
    local proxy_env_prefix="$WORKER_PROXY_ENV_PREFIX"
    local worker_proxy_pid="$WORKER_PROXY_PID"
    local worker_live_addon="$WORKER_PROXY_LIVE_ADDON"
    local worker_live_dir="$WORKER_PROXY_LIVE_DIR"

    # Build a runner script — same trap pattern as spawn so the proxy is cleaned up on EXIT/INT/TERM/HUP
    local worker_claude_bin="${CLAUDE_BIN:-$HOME/.local/bin/claude-223}"
    local death_log="$HOME/.claude/worker-deaths.log"
    local runner
    runner=$(mktemp "/tmp/.worker_${name}_revive.XXXXXX")
    cat > "$runner" <<RUNSCRIPT
#!/usr/bin/env bash
_cleanup() {
    local _s=\$?
    echo "\$(date -Iseconds) worker=${name} session=${session} status=\$_s signal=EXIT" >> '${death_log}'
    [ -n '${worker_proxy_pid}' ] && kill '${worker_proxy_pid}' 2>/dev/null || true
    [ -n '${worker_live_addon}' ] && rm -f '${worker_live_addon}' || true
    [ -n '${worker_live_dir}' ]   && rm -rf '${worker_live_dir}' || true
    touch '/tmp/worker-${name}.done'
    rm -f '${runner}'
}
trap _cleanup EXIT INT TERM HUP
cd '${worktree}'
${proxy_env_prefix}${worker_claude_bin} --model '${model}' --dangerously-skip-permissions --resume '${session_id}'
RUNSCRIPT
    chmod +x "$runner"

    # Create new tmux session with the runner; remain-on-exit on for next death detection.
    # 50000-line history mirrors spawn_claude_worker so capture_clean works after revive too.
    tmux new-session -d -s "$session" "bash '$runner'" \; \
        set-option -p -t "$session" remain-on-exit on \; \
        set-option -t "$session" history-limit 50000

    # Restore env vars + revive marker
    tmux set-environment -t "$session" WORKER_SPAWNED "$(date +%H:%M)"
    tmux set-environment -t "$session" WORKER_REVIVED "$(date +%H:%M)"
    tmux set-environment -t "$session" WORKER_PURPOSE "$purpose"
    tmux set-environment -t "$session" WORKER_PARENT "$parent"
    tmux set-environment -t "$session" WORKER_MODEL "$model"

    # Pane-died hook for death-log writing (single-quoted to defer #{} expansion to tmux)
    tmux set-hook -t "$session" pane-died \
        "run-shell 'echo \"\$(date -Iseconds) worker=${name} session=#{session_name} status=#{pane_dead_status} signal=#{pane_dead_signal}\" >> ${death_log}'" 2>/dev/null || true

    # Orchestrator signal for menubar grace (mirrors spawn-case behaviour)
    _orchestrator_signal_update "$session"

    # Start diagnostic logger sidecar (samples + death-snapshot) — CRITICAL for revive
    # path so we can catch any post-revive death with full forensics
    _start_worker_logger "$name" "$session" "revive"

    # Open viewer window
    open_tmux_viewer "$session" &

    echo "  session: $session"
    echo "  jsonl:   $jsonl"
    echo "$session"
}
