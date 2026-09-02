"""
Pre-commit check: staged/unstaged/untracked files, hook status, import warnings.
Usage: python3 -m src.git.check <repo-path> [--auto-stage]
"""

# INFRASTRUCTURE

import argparse
import logging
import subprocess
import os

logger = logging.getLogger(__name__)

SKIP_PATTERNS = [".beads/", ".DS_Store", ".env", "credentials", ".claude/worktrees/", "venv", ".venv", "node_modules"]

BROKEN_HOOK_PATTERNS = [
    ("bd sync", "BROKEN: uses 'bd sync' — run 'bd export' instead"),
]


# ORCHESTRATOR

def check_workflow(repo_path: str, auto_stage: bool = False) -> None:
    logger.info("check_workflow repo=%s auto_stage=%s", repo_path, auto_stage)
    status_lines = parse_status(repo_path)
    staged, unstaged, untracked, skipped = classify_files(status_lines)
    import_warnings = find_import_warnings(repo_path, unstaged)
    hook_status = check_hook(repo_path)
    diff_staged = run(["git", "diff", "--cached", "--stat"], repo_path)
    diff_unstaged = run(["git", "diff", "--stat"], repo_path)
    print_report(staged, unstaged, untracked, skipped, import_warnings, hook_status, diff_staged, diff_unstaged)

    if auto_stage:
        auto_staged, stage_errors = stage_all(repo_path, unstaged, untracked)
        print_auto_stage_report(auto_staged, stage_errors)
        diff_after = run(["git", "diff", "--cached", "--stat"], repo_path)
        print_diff_summary(diff_after)


# FUNCTIONS

# Run git command and return stdout, trailing whitespace only
def run(cmd: list, cwd: str) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    return result.stdout.rstrip()


# Parse git status --porcelain -z output into raw lines. -z prints paths verbatim (no
# C-quoting of non-ASCII/backslash/quote/control chars) and NUL-terminates entries; rename
# entries emit "to" then "from" (reversed vs. the ' -> ' text format), each NUL-terminated.
def parse_status(repo_path: str) -> list[tuple[str, str]]:
    raw = run(["git", "status", "--porcelain", "-z"], repo_path)
    tokens = raw.split("\0")
    if tokens and tokens[-1] == "":
        tokens.pop()
    lines = []
    i = 0
    while i < len(tokens):
        entry = tokens[i]
        xy = entry[:2]
        to_path = entry[3:]
        if xy[0] in ("R", "C") or xy[1] in ("R", "C"):
            i += 1
            from_path = tokens[i]
            path = f"{from_path} -> {to_path}"
        else:
            path = to_path
        lines.append((xy, path))
        i += 1
    return lines


# Classify files into staged/unstaged/untracked/skipped
def classify_files(lines: list[tuple[str, str]]) -> tuple[list, list, list, list]:
    staged, unstaged, untracked, skipped = [], [], [], []
    for xy, path in lines:
        if any(p in path for p in SKIP_PATTERNS):
            skipped.append((xy, path))
            continue
        x, y = xy[0], xy[1]
        if xy == "??":
            untracked.append(path)
        else:
            if x not in (" ", "?"):
                staged.append((xy, path))
            if y not in (" ", "?"):
                unstaged.append((xy, path))
    return staged, unstaged, untracked, skipped


# Check new imports in unstaged files for untracked module warnings
def find_import_warnings(repo_path: str, unstaged: list) -> list[str]:
    if not unstaged:
        return []
    paths = [p for _, p in unstaged]
    diff = run(["git", "diff"] + paths, repo_path)
    warnings = []
    for line in diff.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            stripped = line[1:].strip()
            if stripped.startswith("import ") or stripped.startswith("from "):
                warnings.append(stripped)
    return warnings


# Check pre-commit hook for broken patterns
def check_hook(repo_path: str) -> str:
    hook_path = os.path.join(repo_path, ".git", "hooks", "pre-commit")
    if not os.path.exists(hook_path):
        return "NONE"
    with open(hook_path) as f:
        content = f.read()
    for pattern, message in BROKEN_HOOK_PATTERNS:
        if pattern in content:
            return f"WARNING: {message}"
    return "OK"


# Print structured report
def print_report(staged, unstaged, untracked, skipped, import_warnings, hook_status, diff_staged, diff_unstaged):
    _section("STAGED")
    if staged:
        for xy, p in staged:
            print(f"  {xy}  {p}")
    else:
        print("  (none)")

    _section("UNSTAGED")
    if unstaged:
        for xy, p in unstaged:
            print(f"  {xy}  {p}")
    else:
        print("  (none)")

    _section("UNTRACKED")
    if untracked:
        for p in untracked:
            print(f"  {p}")
    else:
        print("  (none)")

    _section("SKIP — do not stage")
    if skipped:
        for xy, p in skipped:
            print(f"  {p}")
    else:
        print("  (none)")

    if import_warnings:
        _section("IMPORT WARNINGS — check if imported module is untracked")
        for w in import_warnings:
            print(f"  {w}")

    if diff_unstaged:
        _section("DIFF SUMMARY (unstaged)")
        print(diff_unstaged)

    if diff_staged:
        _section("DIFF SUMMARY (already staged)")
        print(diff_staged)

    _section("HOOK STATUS")
    print(f"  pre-commit: {hook_status}")


def _section(title: str):
    print(f"\n=== {title} ===")


# For RM entries like 'old -> new', return new path only (the one to git add)
def _extract_stage_path(path: str) -> str:
    if " -> " in path:
        return path.split(" -> ", 1)[1]
    return path


# Confirm expected paths actually landed in the index (git add's returncode alone is
# insufficient defense-in-depth). Directory entries (trailing '/', from a brand-new untracked
# folder collapsed to one status line) verify by prefix, since 'git diff --cached --name-only'
# only ever lists individual files, never the directory itself.
def verify_staged(repo_path: str, expected_paths: list[str]) -> list[str]:
    raw = run(["git", "diff", "--cached", "--name-only", "-z"], repo_path)
    staged_now = [p for p in raw.split("\0") if p]
    missing = []
    for path in expected_paths:
        if path.endswith("/"):
            if not any(p.startswith(path) for p in staged_now):
                missing.append(path)
        elif path not in staged_now:
            missing.append(path)
    return missing


# Stage all unstaged and untracked files (minus SKIP). Returns (staged, errors) — a path only
# lands in `staged` once its `git add` returncode AND the post-hoc index check both confirm it;
# any other outcome is reported in `errors` instead of being silently treated as staged.
def stage_all(repo_path: str, unstaged: list, untracked: list) -> tuple[list[str], list[str]]:
    paths_to_stage = [_extract_stage_path(p) for _, p in unstaged] + untracked
    if not paths_to_stage:
        return [], []
    errors = []
    attempted = []
    for path in paths_to_stage:
        result = subprocess.run(["git", "add", "--", path], capture_output=True, text=True, cwd=repo_path)
        if result.returncode != 0:
            errors.append(f"{path}: {(result.stderr or result.stdout).strip()}")
        else:
            attempted.append(path)
    missing = verify_staged(repo_path, attempted)
    for path in missing:
        errors.append(f"{path}: git add reported success but path is missing from the staged index")
    staged = [p for p in attempted if p not in missing]
    return staged, errors


# Print auto-staged files report, plus any staging errors (empty errors = today's output)
def print_auto_stage_report(auto_staged: list[str], stage_errors: list[str] = None):
    _section("AUTO-STAGED")
    if auto_staged:
        for p in auto_staged:
            print(f"  {p}")
    else:
        print("  (nothing to stage)")

    if stage_errors:
        _section("STAGE ERRORS")
        for e in stage_errors:
            print(f"  {e}")


# Print diff summary after staging
def print_diff_summary(diff: str):
    _section("DIFF SUMMARY — use this for commit message")
    if diff:
        print(diff)
    else:
        print("  (nothing staged)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Pre-commit check for git-committer agent")
    parser.add_argument("repo_path", help="Path to git repository")
    parser.add_argument("--auto-stage", action="store_true", help="Stage all unstaged/untracked files (minus SKIP)")
    args = parser.parse_args()
    check_workflow(args.repo_path, auto_stage=args.auto_stage)
