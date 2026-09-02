"""
Stage all (tracked mods + untracked, minus skip-list) and commit in one call.
Usage: python3 -m src.git.commit "<message>" [repo_path]
"""

# INFRASTRUCTURE

import argparse
import logging
import os
import subprocess
import sys

# From check.py: skip-list, status parsing, classification, staging
from src.git.check import parse_status, classify_files, stage_all

logger = logging.getLogger(__name__)


# ORCHESTRATOR

def commit_workflow(repo_path: str, message: str) -> None:
    logger.info("commit_workflow repo=%s", repo_path)
    status_lines = parse_status(repo_path)
    staged, unstaged, untracked, skipped = classify_files(status_lines)
    auto_staged, stage_errors = stage_all(repo_path, unstaged, untracked)
    if stage_errors:
        print_commit_report(auto_staged, skipped, "")
        print_stage_errors(stage_errors)
        sys.exit(1)
    returncode, output = do_commit(repo_path, message)
    print_commit_report(auto_staged, skipped, output)
    if returncode != 0:
        sys.exit(returncode)


# FUNCTIONS

# Run git commit, returning (returncode, combined stdout+stderr)
def do_commit(repo_path: str, message: str) -> tuple[int, str]:
    result = subprocess.run(
        ["git", "commit", "-m", message],
        capture_output=True, text=True, cwd=repo_path,
    )
    output = (result.stdout + result.stderr).strip()
    return result.returncode, output


# Print concise staged-files + commit result summary
def print_commit_report(staged: list[str], skipped: list, commit_output: str) -> None:
    if staged:
        print(f"staged: {', '.join(staged)}")
    else:
        print("staged: (nothing new)")
    if skipped:
        print(f"skipped: {', '.join(p for _, p in skipped)}")
    print(commit_output)


# Print staging failures and the abort message (no commit is attempted after this)
def print_stage_errors(stage_errors: list[str]) -> None:
    print("stage errors:")
    for e in stage_errors:
        print(f"  {e}")
    print("aborting: staging failed, no commit made")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Stage all + commit in one call")
    parser.add_argument("message", help="Commit message")
    parser.add_argument("repo_path", nargs="?", default=os.getcwd(), help="Path to git repository (default: cwd)")
    args = parser.parse_args()
    commit_workflow(os.path.abspath(args.repo_path), args.message)
