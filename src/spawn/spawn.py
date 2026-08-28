"""
Spawn a Claude Code worker in a git worktree via tmux + Ghostty.
Usage: python3 -m src.spawn.spawn <name> <prompt_file> <project_path> [model] [--no-worktree]
"""

# INFRASTRUCTURE

import argparse
import json
import os
import shutil
import subprocess
import sys

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TMUX_SPAWN_SH = os.path.join(PLUGIN_DIR, "src", "spawn", "tmux_spawn.sh")
_DEFAULT_WORKER_MODEL = "claude-sonnet-5"
_MODEL_SELECTION_FILE = os.environ.get(
    "MODEL_SELECTION_FILE", os.path.expanduser("~/.claude/shared-rules/model_selection.json"))


# ORCHESTRATOR

def spawn_workflow(name: str, prompt_file: str, project_path: str, model: str, worktree: bool) -> None:
    if not os.path.isfile(prompt_file):
        print(f"ERROR: Prompt file not found: {prompt_file}", file=sys.stderr)
        sys.exit(1)

    actual_path = project_path

    if worktree:
        actual_path = setup_worktree(name, project_path)
        if actual_path is None:
            sys.exit(1)

    session = tmux_spawn(name, actual_path, model, prompt_file)
    if session.startswith("ERROR"):
        print(session, file=sys.stderr)
        sys.exit(1)

    print(f"Session: {session}")
    print(f"Attach: tmux attach -t {session}")


# FUNCTIONS

# Create worktree, copy settings, symlink venv — returns worktree path or None on error
def setup_worktree(name: str, project_path: str) -> str | None:
    wt_path = os.path.join(project_path, ".claude", "worktrees", name)

    branch_check = _run_git(["branch", "--list", name], cwd=project_path)
    if branch_check.strip():
        print(f"ERROR: Branch '{name}' already exists. Clean up first.", file=sys.stderr)
        return None

    result = _run_git(["worktree", "add", "-b", name, wt_path], cwd=project_path)
    if result.startswith("ERROR"):
        print(result, file=sys.stderr)
        return None
    print(f"Worktree: {wt_path}")

    if not os.path.isdir(wt_path):
        print(f"ERROR: Worktree not created at {wt_path}", file=sys.stderr)
        return None

    settings_src = os.path.join(project_path, ".claude", "settings.local.json")
    if os.path.isfile(settings_src):
        dst_dir = os.path.join(wt_path, ".claude")
        os.makedirs(dst_dir, exist_ok=True)
        shutil.copy2(settings_src, os.path.join(dst_dir, "settings.local.json"))
        print("Settings copied.")

    venv_src = os.path.join(project_path, "venv")
    if os.path.isdir(venv_src):
        venv_dst = os.path.join(wt_path, "venv")
        if not os.path.exists(venv_dst):
            os.symlink(venv_src, venv_dst)
            print("Venv symlinked.")

    return wt_path


# Source tmux_spawn.sh and call spawn_claude_worker_from_file
def tmux_spawn(name: str, actual_path: str, model: str, prompt_file: str) -> str:
    func_call = f'spawn_claude_worker_from_file "workers" "{name}" "{actual_path}" "{model}" "{prompt_file}"'
    cmd = f'source "{TMUX_SPAWN_SH}" && {func_call}'
    try:
        result = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True, text=True, timeout=60,
            cwd=os.getcwd()
        )
    except subprocess.TimeoutExpired:
        return "ERROR: tmux spawn timed out after 60s"
    except OSError as e:
        return f"ERROR: {e.strerror}"
    if result.returncode != 0:
        return f"ERROR: {result.stderr.strip()}"
    return result.stdout.strip()


# Run git command and return stdout or ERROR: prefix on failure
def _run_git(args: list, cwd: str) -> str:
    result = subprocess.run(
        ["git"] + args,
        capture_output=True, text=True, timeout=30, cwd=cwd
    )
    if result.returncode != 0:
        return f"ERROR: {result.stderr.strip()}"
    return result.stdout.strip()


# Resolve the worker model when no explicit CLI argument was given: "worker" key from
# ~/.claude/shared-rules/model_selection.json (menubar Models tab), else the hardcoded
# fallback. Never raises — a missing/unreadable/malformed file or a missing/empty key all
# degrade silently to the fallback; a spawn must never fail because of this file.
def _resolve_worker_model() -> str:
    worker = ""
    try:
        with open(_MODEL_SELECTION_FILE, encoding="utf-8") as f:
            data = json.load(f)
        worker = data.get("worker") or ""
    except Exception:
        worker = ""
    return worker or _DEFAULT_WORKER_MODEL


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Spawn a Claude Code worker in a git worktree")
    parser.add_argument("name", help="Worker name (branch + tmux session suffix)")
    parser.add_argument("prompt_file", help="Absolute path to prompt file")
    parser.add_argument("project_path", help="Absolute path to project directory")
    parser.add_argument("model", nargs="?", default=None,
                         help="Model ID; explicit argument wins over the config file")
    parser.add_argument("--no-worktree", action="store_true", help="Skip worktree creation, spawn in project dir directly")
    args = parser.parse_args()
    resolved_model = args.model or _resolve_worker_model()
    spawn_workflow(args.name, args.prompt_file, args.project_path, resolved_model, not args.no_worktree)
