# Git Automation — Three-Phase Workflow Snapshot

*Snapshot as of 2026-03 — historical process record; the live current state is the source code (`src/git/`), not this file.*

## Architecture as of 2026-03

Three-phase git workflow used by the `git-committer` agent:

**Phase 1 — check.py (pre-commit + auto-stage):**
- Parses `git status --porcelain` into staged/unstaged/untracked/skipped
- SKIP_PATTERNS: `.beads/`, `.DS_Store`, `.env`, `credentials`, `.claude/worktrees/`
- Detects new imports in unstaged files (potential missing-module warnings)
- Checks the pre-commit hook for known broken patterns (e.g., `bd sync` → should be `bd export`)
- Outputs a structured report with sections: STAGED, UNSTAGED, UNTRACKED, SKIP, IMPORT WARNINGS, DIFF SUMMARY, HOOK STATUS
- `--auto-stage`: stages all UNSTAGED + UNTRACKED (minus SKIP), outputs AUTO-STAGED + DIFF SUMMARY for the commit message

**Phase 2 — staged.py (staging verification) — retained as fallback:**
- Confirms all relevant files are staged (same SKIP_PATTERNS)
- Reports COMPLETE/INCOMPLETE status
- Provides a `git diff --cached --stat` summary for commit-message generation
- Not called in the normal flow (replaced by `check.py --auto-stage`)

**Phase 3 — post.py (post-commit):**
- Confirms the working tree is clean after commit
- Shows the last commit hash + message
- Reports CLEAN/DIRTY with remaining uncommitted changes (excluding SKIP_PATTERNS)

**Usage:** `python3 -m src.git.<module> <repo-path> [--auto-stage]`

**Files:** `src/git/check.py`, `src/git/staged.py`, `src/git/post.py`

## Decision at snapshot time

Auto-stage consolidation: `check.py --auto-stage` replaces manual `git add` + `staged.py` in the normal git-committer flow. Reduced agent tool calls from 6+N to 5-6 per repo. staged.py retained as fallback.

SKIP_PATTERNS + `run()` helper remained duplicated across 3 files — accepted at the time (extraction adds complexity without functional benefit).
