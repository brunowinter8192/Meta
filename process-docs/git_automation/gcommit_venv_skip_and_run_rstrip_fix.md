# gcommit — venv Symlink Skip + run() Leading-Whitespace Fix

**Date**: 2026-07-13
**Branch**: gcommit-build
**Commits**: 5f7034b, d53a30f
**Files changed**: `src/git/check.py` (only)

---

## Problem 1 — venv symlinks committed

Worktrees hold `venv` as a SYMLINK to the main repo's real venv. `git status` reports untracked symlinks without a trailing slash (`?? venv`), but the repo's `.gitignore` has `venv/` (trailing slash — directory-only match). Result: `gcommit` staged and committed the symlink.

**Fix:** added `"venv"`, `".venv"`, `"node_modules"` to `SKIP_PATTERNS` (`src/git/check.py`). Verified no tracked repo path contains `venv` as a substring (`git ls-files | grep -i venv` → none), so the bare substring pattern carries no false-positive risk here — consistent with the existing loose-substring convention (`.env` already matches `.env.example`, `credentials` matches any filename containing that word).

## Problem 2 — `run()`'s whole-blob `.strip()` silently drops the first unstaged file

Discovered while verifying Problem 1: a real unstaged modification to `check.py` sat alongside the untracked `venv` symlink, and `gcommit` reported `staged: (nothing new)` — the modification was silently NOT staged.

**Root cause:** `run()` did `result.stdout.strip()` on the FULL multi-line `git status --porcelain` output. When the lexicographically-first status line is an unstaged tracked modification (porcelain code `" M"`, leading space), that leading space is the first character of the captured string — `.strip()` removes it. `parse_status`'s `xy = line[:2]; path = line[3:]` then split the corrupted line wrong (`"M src/git/check.py"` → `xy="M "`, `path="rc/git/check.py"`, dropping the `s`). `classify_files` read `x='M'` (not space) and misfiled the entry into the already-staged bucket, so `stage_all` never ran `git add` on it.

**Fix:** `run()` changed to `result.stdout.rstrip()` (trailing-only). Checked every `check.py` caller of `run()`: `git diff --stat`/`git diff` outputs are display/line-content-scanned only, `git add` return value is unused — none depend on leading-whitespace removal. `parse_status` was the only caller for which leading whitespace is semantically load-bearing.

## Verification

- **venv skip:** untracked `venv` symlink alone → `skipped: venv`, commit fails fast (exit 1, "nothing added to commit"), `git log -1 --name-only` on unchanged HEAD confirms no `venv` entry.
- **run() fix, exact failing scenario:** clean tree, ONE unstaged tracked modification (`check.py` itself) as the only change → `gcommit` reported `staged: src/git/check.py` (previously `staged: (nothing new)`), commit succeeded (exit 0), `git log -1 --name-only` confirms the file IS in the commit. This run doubled as the fix's own commit (d53a30f) — dogfooded successfully.
- Re-ran the venv-skip scenario after the `run()` fix to confirm no regression — same skip/fail-fast behavior held.
