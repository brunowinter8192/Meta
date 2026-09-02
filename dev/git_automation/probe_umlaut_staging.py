"""
Probe: gcommit / git-check staging correctness for non-ASCII and "unusual" paths.
Usage: python3 dev/git_automation/probe_umlaut_staging.py

Builds throwaway git repos under a temp dir, drives `python3 -m src.git.commit` and
`python3 -m src.git.check --auto-stage` against them exactly like a real caller would,
and asserts against the repo's own git state (git log / git status), never against
gcommit's own report. Report: dev/git_automation/md/probe_umlaut_staging_<ts>.md
"""

# INFRASTRUCTURE

import datetime
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
REPORT_DIR = Path(__file__).resolve().parent / "md"


# ORCHESTRATOR

def run_probe() -> None:
    cases = [
        case_umlaut_file_in_existing_folder,
        case_space_in_path,
        case_new_umlaut_folder,
        case_staged_rename,
        case_ascii_modification,
        case_loud_failure_permission_denied,
        case_git_check_auto_stage,
    ]
    results = []
    for case in cases:
        ok, name, detail = case()
        results.append((ok, name, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}")
        print(f"    {detail}")

    write_report(results)
    if any(not ok for ok, _, _ in results):
        print("\nprobe FAILED — see report for details")
        sys.exit(1)
    print("\nprobe PASSED — all cases green")


# FUNCTIONS

# Run a subprocess command, returning (returncode, stdout, stderr)
def sh(cmd: list, cwd=None, check: bool = False):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"setup command failed: {cmd} -> {result.stderr}")
    return result.returncode, result.stdout, result.stderr


# Build a throwaway git repo with one committed placeholder file
def make_repo() -> Path:
    repo = Path(tempfile.mkdtemp(prefix="gcommit_probe_"))
    sh(["git", "init", "-q"], cwd=repo, check=True)
    # matches the global commit-msg identity guard (~/.githooks/commit-msg) so throwaway
    # commits aren't rejected by it
    sh(["git", "config", "user.email", "brunowinter8192@github.com"], cwd=repo, check=True)
    sh(["git", "config", "user.name", "Bruno Winter"], cwd=repo, check=True)
    (repo / "README.md").write_text("probe repo\n")
    sh(["git", "add", "README.md"], cwd=repo, check=True)
    sh(["git", "commit", "-q", "-m", "initial"], cwd=repo, check=True)
    return repo


# Invoke gcommit (src.git.commit) against a repo, from the project root (module entry point)
def run_gcommit(repo: Path, message: str):
    return sh(["python3", "-m", "src.git.commit", message, str(repo)], cwd=PROJECT_ROOT)


# Invoke git-check (src.git.check) with --auto-stage against a repo
def run_git_check(repo: Path):
    return sh(["python3", "-m", "src.git.check", str(repo), "--auto-stage"], cwd=PROJECT_ROOT)


# List files touched by the repo's last commit, NUL-split/unquoted — avoids the same
# C-quoting pitfall gcommit itself is being tested for
def last_commit_files(repo: Path) -> list[str]:
    _, out, _ = sh(["git", "show", "--format=", "--name-only", "-z", "HEAD"], cwd=repo)
    return [p for p in out.split("\0") if p]


def last_commit_hash(repo: Path) -> str:
    _, out, _ = sh(["git", "rev-parse", "HEAD"], cwd=repo)
    return out.strip()


# Undo any chmod-000 lockouts (loud-failure case) so tempdir removal doesn't fail, then remove
def _force_writable(func, path, exc_info):
    os.chmod(path, 0o755)
    func(path)


def cleanup(repo: Path):
    shutil.rmtree(repo, onerror=_force_writable)


# Reported case: an existing tracked folder named with an umlaut gains a new untracked file
def case_umlaut_file_in_existing_folder():
    name = "umlaut file inside an existing tracked anhaenge/ folder"
    repo = make_repo()
    try:
        folder = repo / "dokumente" / "wollpflege" / "anhänge"
        folder.mkdir(parents=True)
        (folder / ".gitkeep").write_text("")
        sh(["git", "add", "."], cwd=repo, check=True)
        sh(["git", "commit", "-q", "-m", "add anhaenge folder"], cwd=repo, check=True)

        (folder / "2026-08-28_troyer-zustandsfotos.pdf").write_bytes(b"%PDF-1.4 fake\n")

        rc, out, err = run_gcommit(repo, "add troyer photos")
        files = last_commit_files(repo)
        expected = "dokumente/wollpflege/anhänge/2026-08-28_troyer-zustandsfotos.pdf"
        ok = rc == 0 and expected in files
        return ok, name, f"rc={rc} files={files} stdout={out.strip()!r}"
    finally:
        cleanup(repo)


def case_space_in_path():
    name = "path with a space"
    repo = make_repo()
    try:
        (repo / "meeting notes.md").write_text("agenda\n")
        rc, out, err = run_gcommit(repo, "add meeting notes")
        files = last_commit_files(repo)
        ok = rc == 0 and "meeting notes.md" in files
        return ok, name, f"rc={rc} files={files}"
    finally:
        cleanup(repo)


# Brand-new (entirely untracked) umlaut folder — status collapses it to ONE directory entry
# ("?? anhaenge_neu/"), which is the verify_staged prefix-match case
def case_new_umlaut_folder():
    name = "brand-new umlaut folder (directory status entry, not a file entry)"
    repo = make_repo()
    try:
        folder = repo / "anhänge_neu"
        folder.mkdir()
        (folder / "foto.pdf").write_bytes(b"binary\n")
        rc, out, err = run_gcommit(repo, "add new attachments folder")
        files = last_commit_files(repo)
        ok = rc == 0 and "anhänge_neu/foto.pdf" in files
        return ok, name, f"rc={rc} files={files}"
    finally:
        cleanup(repo)


# Staged rename (git mv) must still stage/commit the NEW path; an unrelated sidecar file
# in the same status batch catches any rename-token miscount corrupting the next entry
def case_staged_rename():
    name = "staged rename (git mv) commits the new path"
    repo = make_repo()
    try:
        (repo / "old_name.txt").write_text("content\n" * 5)
        sh(["git", "add", "old_name.txt"], cwd=repo, check=True)
        sh(["git", "commit", "-q", "-m", "add old_name.txt"], cwd=repo, check=True)

        sh(["git", "mv", "old_name.txt", "new_name.txt"], cwd=repo, check=True)
        (repo / "sidecar.txt").write_text("sidecar\n")

        rc, out, err = run_gcommit(repo, "rename old_name to new_name")
        files = last_commit_files(repo)
        ok = rc == 0 and "new_name.txt" in files and "sidecar.txt" in files
        return ok, name, f"rc={rc} files={files}"
    finally:
        cleanup(repo)


def case_ascii_modification():
    name = "plain ASCII modification (regression)"
    repo = make_repo()
    try:
        (repo / "README.md").write_text("probe repo\nupdated\n")
        rc, out, err = run_gcommit(repo, "update readme")
        files = last_commit_files(repo)
        ok = rc == 0 and "README.md" in files
        return ok, name, f"rc={rc} files={files}"
    finally:
        cleanup(repo)


# git add cannot succeed (unreadable file) -> gcommit must fail loudly, no commit made
def case_loud_failure_permission_denied():
    name = "loud failure: unreadable file blocks git add, no commit made"
    repo = make_repo()
    try:
        before = last_commit_hash(repo)
        target = repo / "secret.bin"
        target.write_bytes(b"top secret\n")
        os.chmod(target, 0o000)

        rc, out, err = run_gcommit(repo, "should never land")
        after = last_commit_hash(repo)
        combined = out + err
        ok = rc != 0 and after == before and "aborting" in combined.lower()
        return ok, name, f"rc={rc} before={before} after={after} output={combined.strip()!r}"
    finally:
        cleanup(repo)


# git-check --auto-stage shares stage_all/parse_status with gcommit and must inherit the fix
def case_git_check_auto_stage():
    name = "git-check --auto-stage inherits the fix"
    repo = make_repo()
    try:
        folder = repo / "anhänge"
        folder.mkdir()
        (folder / "schäden.pdf").write_bytes(b"binary\n")
        (repo / "spaced file.txt").write_text("x\n")

        rc, out, err = run_git_check(repo)
        _, cached, _ = sh(["git", "diff", "--cached", "--name-only", "-z"], cwd=repo)
        cached_files = [p for p in cached.split("\0") if p]
        ok = (
            rc == 0
            and "anhänge/schäden.pdf" in cached_files
            and "spaced file.txt" in cached_files
            and "STAGE ERRORS" not in out
        )
        return ok, name, f"rc={rc} cached={cached_files}"
    finally:
        cleanup(repo)


# Write the persistent markdown report
def write_report(results: list[tuple[bool, str, str]]):
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    path = REPORT_DIR / f"probe_umlaut_staging_{ts}.md"
    lines = [
        "# gcommit / git-check non-ASCII staging probe",
        "",
        f"Run: {ts}",
        "",
        "| Result | Case |",
        "|---|---|",
    ]
    for ok, case_name, _ in results:
        lines.append(f"| {'PASS' if ok else 'FAIL'} | {case_name} |")
    lines.append("")
    lines.append("## Details")
    for ok, case_name, detail in results:
        lines.append(f"\n### {case_name} — {'PASS' if ok else 'FAIL'}\n\n{detail}")
    path.write_text("\n".join(lines) + "\n")
    print(f"\nreport written: {path}")


if __name__ == "__main__":
    run_probe()
