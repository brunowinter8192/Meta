# dev/git_automation/

## Role

Regression probes for `src/git/` (`gcommit`, `git-check`) staging correctness. All commands assume CWD = project root (iterative-dev/).

## Modules

### probe_umlaut_staging.py

**Purpose:** Growing assertion suite proving `python3 -m src.git.commit` and `python3 -m src.git.check --auto-stage` stage/commit paths correctly, including non-ASCII and otherwise "unusual" paths that `git status --porcelain` (without `-z`) C-quotes. Builds throwaway git repos per case, drives the real module entry points against them, asserts via `git show --name-only -z` / `git diff --cached --name-only -z` on the repo itself (never trusts gcommit's own report). New fix-specific cases fold into this file rather than spawning a new one per fix.
**Usage:**
```bash
python3 dev/git_automation/probe_umlaut_staging.py
```
**Output:** `dev/git_automation/md/probe_umlaut_staging_<timestamp>.md` — pass/fail table + per-case detail (rc, committed files, raw output). Exit code non-zero if any case fails.
**Cases covered:** umlaut file in an existing tracked folder (the reported bug); brand-new umlaut folder (single directory status entry — exercises `verify_staged`'s prefix match, not an exact-path match); path with a space; staged rename via `git mv`; plain ASCII modification (regression); unreadable file forcing `git add` to fail (loud-failure path, asserts non-zero exit + no commit); `git-check --auto-stage` against the same kind of fixture.
