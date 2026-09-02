# gcommit — Non-ASCII Path Silent Staging Loss Fix

**Date**: 2026-09-02
**Files changed**: `src/git/check.py`, `src/git/commit.py`

---

## Problem

`gcommit` silently dropped files whose path contained non-ASCII characters (e.g. an `anhänge/` folder). It printed them in its `staged:` line every run, but they never landed in the commit and `git status` kept showing them untracked afterward. A manual `git add` on the real path staged them fine — the files, the working tree, and git itself were all fine; the tool was lying about its own result.

## Root Cause

Two compounding bugs in `check.py`'s shared primitives:

1. `parse_status` read `git status --porcelain` (no `-z`). Git's default text format C-quotes any path with non-ASCII, backslash, quote, or control characters into an escaped literal string (`"anh\303\244nge/x.pdf"`) — quotes and octal escapes included as literal text, not decoded. `parse_status` took that string verbatim as the path.
2. `stage_all` then ran `git add <that garbled string>`, which matched no real file — `git add` no-ops. `run()`, which every git call in the module went through, only ever returned `stdout.rstrip()`, discarding the subprocess returncode and stderr entirely. `stage_all` unconditionally reported every attempted path as staged regardless of whether `git add` actually did anything. Nothing between `git add` and `git commit` ever checked that staging had worked.

Renames were collateral: the non-`-z` porcelain format embeds `"old -> new"` as one text field, and this had to keep working unchanged.

## Fix

**Parsing — switch to `git status --porcelain -z`.** `-z` prints paths verbatim (real bytes, no quoting) and NUL-terminates entries instead of using `\n`, and — per `git-status(1)` — reverses the rename field order to `to` first, then `from`, each NUL-terminated, dropping the ` -> ` text separator. `parse_status` now splits on `"\0"`, and for `R`/`C` status entries consumes the extra token, reconstructing the exact same `"from -> to"` string the rest of the module (`_extract_stage_path`, the report printers) already expected — so nothing downstream had to change, and rename staging behavior is bit-for-bit identical to before. `run()`'s existing `.rstrip()` is safe against this format: NUL is not whitespace, so it never eats the trailing terminator the way a prior fix's leading-space gotcha did for the old format (documented in `process-docs/git_automation/` — a whole-blob `.strip()` on the old non-`-z` text output could eat a leading status-column space and shift the parse; that gotcha doesn't apply to `-z` parsing, a different one does, see below).

**Loud failure — `stage_all` now verifies, not just attempts.** Every `git add` call runs via `subprocess.run` directly (not `run()`, which would still discard the returncode), and a nonzero returncode is captured into an `errors` list with git's own stderr. Paths that report success are then cross-checked against `git diff --cached --name-only -z` (`verify_staged`) — belt-and-braces against any other silent-no-op path, not just the specific quoting bug. `stage_all`'s return type changed from `list[str]` to `(staged, errors)`; only paths that pass both checks land in `staged`. `commit.py`'s `commit_workflow` treats a non-empty `errors` as fatal: it prints the errors plus an abort message and exits non-zero *before* calling `do_commit` — no commit is attempted, let alone a partial one.

**Directory-entry verification.** A brand-new (entirely untracked) folder collapses to a single `git status` line with a trailing slash (e.g. `?? anhänge_neu/`) rather than one line per file inside it. `git diff --cached --name-only` never lists that directory path — only the individual files under it. An exact-match `verify_staged` would therefore treat every newly-added folder as a staging failure and false-abort `gcommit`. `verify_staged` special-cases paths ending in `/`: verified by prefix match against the staged file list instead of exact match. Considered switching `parse_status` to `-uall` (which expands new directories into individual file entries at the source, sidestepping the trailing-slash case entirely) — rejected because it would also change `check.py`'s STAGED/UNSTAGED/UNTRACKED report output for every new-folder case (one line per file instead of one line for the folder), a behavior change outside this fix's scope for a tool whose contract is "keep behaving as before for the cases it handles today."

**`check.py` (`git-check`) inherits the same fix for free** — both `parse_status` and `stage_all` are shared primitives; `check.py`'s own `check_workflow` just gained an optional "STAGE ERRORS" report section (empty list = no new output, so the report is unchanged for every case it already handled correctly).

## Verification

`dev/git_automation/probe_umlaut_staging.py` — 7 cases against throwaway git repos, asserted via `git show --name-only -z` / `git diff --cached --name-only -z` on the repo itself (not gcommit's own report): umlaut file in an existing tracked folder (the reported case) — PASS, file present in commit; brand-new umlaut folder (directory status entry, the prefix-match case) — PASS; path with a space — PASS (regression, was already fine); staged rename via `git mv` alongside an unrelated sidecar file (catches any rename-token-count corruption of the next parsed entry) — PASS, both files in commit; plain ASCII modification — PASS (regression); unreadable file (`chmod 000`) forcing `git add` to fail — PASS, non-zero exit, commit hash unchanged, `stage errors:` / `aborting: staging failed, no commit made` in output; `git-check --auto-stage` against an umlaut-folder + spaced-file fixture — PASS, both files reached the index, no STAGE ERRORS section.

All 7 cases green in one run; the probe's own exit code is non-zero if any case regresses.
