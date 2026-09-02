# src/git/

## Role

Three-phase git workflow utilities for pre-commit checks, staging, and post-commit verification. Touch this package when modifying how files are classified before staging, how hook health is detected, or how the working tree is verified after a commit. Do NOT touch for project-specific commit conventions — those live in the `tool-use` skill (`#### Git CLI` subsection).

## Public Interface

`__init__.py` is empty. Modules are invoked as `python3 -m src.git.<module>` entry points. Active entry paths: `~/.local/bin/git-check` → `python3 -m src.git.check`; `~/.local/bin/gcommit` → `python3 -m src.git.commit`.

## Modules

### check.py (246 LOC)

**Purpose:** Pre-commit analysis + optional auto-staging. Classifies files into staged/unstaged/untracked/skipped, detects new imports in unstaged .py files, checks hook health. `parse_status` reads `git status --porcelain -z` (NUL-delimited, unquoted paths) rather than the default text format, which C-quotes any non-ASCII/backslash/quote/control-char path into an escaped literal (`"anh\303\244nge/x.pdf"`) that no longer matches a real file — `-z` sidesteps that entirely; rename entries are reassembled into the same `"from -> to"` display string the rest of the module already expects. `stage_all` runs `git add --` per path via `subprocess.run` directly (not through `run()`, which discards returncode/stderr), and cross-checks successes against `git diff --cached --name-only -z` (`verify_staged`) before calling a path staged — a path reported as staged is always actually in the index.
**Reads:** Repository files, git status/diff output, `.git/hooks/pre-commit` content.
**Writes:** stdout (structured report: STAGED, UNSTAGED, UNTRACKED, SKIP, IMPORT WARNINGS, DIFF SUMMARY, HOOK STATUS, and STAGE ERRORS when `--auto-stage` hits a staging failure). With `--auto-stage`: git index via `git add`.
**Called by:** `~/.local/bin/git-check`.
**Calls out:** subprocess (git commands).

---

### commit.py (73 LOC)

**Purpose:** One-call stage-all + commit, worktree-correct (no path resolution/stripping — `repo_path` used as-is, `git` itself resolves the right worktree branch). Reuses `parse_status`/`classify_files`/`stage_all` from `check.py` — single source of truth for `SKIP_PATTERNS` and for the `-z`-based staging fix. `stage_all` now returns `(staged, errors)`; a non-empty `errors` list (e.g. an unreadable file that makes `git add` fail) aborts before `do_commit` runs — non-zero exit, no commit made, never a silent partial commit.
**Reads:** git status output (via `check.py` primitives).
**Writes:** git index via `stage_all`, git commit via `do_commit`. stdout (staged/skipped summary + git commit output, or stage-errors + abort message on staging failure).
**Called by:** `~/.local/bin/gcommit`.
**Calls out:** subprocess (git commands); `src/git/check.py` (`parse_status`, `classify_files`, `stage_all`).

---

### staged.py (108 LOC)

**Purpose:** Staging verification — confirms all relevant files are staged, provides diff summary for commit message.
**Reads:** git status --porcelain, git diff --cached output.
**Writes:** stdout (COMPLETE/INCOMPLETE status + staged file list + diff summary).
**Called by:** Retained as fallback; no active caller after migration to `check.py --auto-stage`.
**Calls out:** subprocess (git commands).

---

### post.py (71 LOC)

**Purpose:** Post-commit verification — confirms working tree is clean after commit.
**Reads:** git log, git status output.
**Writes:** stdout (last commit hash + CLEAN/DIRTY status with remaining changes).
**Called by:** No active caller (git-committer.md agent removed).
**Calls out:** subprocess (git commands).

---

## Usage

```bash
python3 -m src.git.check <repo-path>                # analysis only
python3 -m src.git.check <repo-path> --auto-stage   # analysis + stage all (normal flow)
python3 -m src.git.staged <repo-path>               # manual staging verification (fallback)
python3 -m src.git.post <repo-path>
python3 -m src.git.commit "<message>" [repo-path]   # stage-all + commit, one call
```

## Gotchas

`check.py`'s `resolve_project_path` (in the `bin/git-check` wrapper, not this module) strips `.claude/worktrees/…` back to the parent repo — worktree-hostile. `commit.py`'s wrapper (`bin/gcommit`) deliberately does NOT do this: `repo_path` defaults to the caller's `pwd` (captured before the wrapper `cd`s into the plugin root) and is passed through unresolved — `git` itself finds the correct worktree branch from `cwd`.

`run()` must `rstrip()`, NOT `strip()`. `git status --porcelain`'s first line carries a leading status-column space (e.g. `" M file.py"` = unstaged modification); a whole-blob `.strip()` eats that space when it's the first char of the captured stdout, shifting `parse_status`'s `line[:2]`/`line[3:]` split and silently dropping the file from staging. Any future `run()`-consuming parser that reads leading characters needs this same care.

`SKIP_PATTERNS` includes bare `"venv"`/`".venv"`/`"node_modules"` — catches worktree dependency symlinks (e.g. `venv -> ../real/venv`), which `git status` reports without a trailing slash (unlike real directories), so the repo's `.gitignore` `venv/` entry doesn't match them.

`parse_status` must use `git status --porcelain -z`, never the default text format — the default C-quotes any non-ASCII/backslash/quote/control-char path (`core.quotePath=true`), and the quoted-escaped string is not a valid filesystem path, so a later `git add` on it silently no-ops instead of staging the real file. `-z` also reverses the rename field order (new path first, then old path, each NUL-terminated) — `parse_status` consumes the extra token when `R`/`C` appears in either status column, and re-glues it into the same `"from -> to"` string the rest of the module (`_extract_stage_path`, report printers) already assumed, so nothing downstream needed to change.

`verify_staged` matches directory-entry paths (trailing `/`, from a brand-new untracked folder that `git status` collapses to one line) by prefix, not exact match — `git diff --cached --name-only` only ever lists individual files, never the directory itself, so an exact match would false-positive every new folder as a staging failure.
