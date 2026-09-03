# worker-cli merge: built-in outcome verification

2026, iterative-dev.

## Context

`worker-cli merge <name> [project_path]` ran `git merge <name> --no-ff` and passed the
output through verbatim. The orchestrator used to verify the merge outcome by hand after
every call (checking whether the branch actually carried commits, and whether the merge
brought in the expected files). That manual step was retired; the check needed to move
into the command itself so it runs deterministically on every invocation instead of
depending on the orchestrator remembering to look.

Two failure shapes needed to become loud:
1. `git merge` reporting "Already up to date." — the branch carried no commits into the
   current branch. Two known causes: a cross-project worker merged without passing its
   `project_path` (the branch actually lives in the other repo, so the merge target never
   saw it), or a worker that never committed.
2. A real merge landing but bringing in zero files — a signal something is off even
   though git itself reported success.

## Decision: diff against ORIG_HEAD, not HEAD~1

`git diff HEAD~1 --name-only` only shows the immediately-preceding commit. `ORIG_HEAD` is
git's own record of the pre-merge tip of the current branch, set by `git merge` itself —
diffing against it covers every commit the merge brought in, including a multi-commit
worker branch. Verified with a real throwaway repo: `ORIG_HEAD` diff is empty exactly when
the merge was a genuine no-op (git's "Already up to date." case), which lets the two checks
compose cleanly (the "Already up to date" string match short-circuits before the
`ORIG_HEAD` diff is even taken).

## Dead end: `set -e` swallowed conflict output

First implementation captured the merge command directly into a variable:
`MERGE_OUT=$(git -C "$PROJECT" merge ...)`. `bin/worker-cli` runs under `set -e` (line 5).
A command-substitution assignment (`VAR=$(cmd)`) propagates `cmd`'s exit status to the
assignment statement — verified live: a real conflict (`git merge` exit 1) aborted the
script immediately, before the `echo "$MERGE_OUT"` line ever ran. Before this change, the
bare `git merge ...` call had streamed its output directly to the terminal as it ran, so a
conflict's `CONFLICT (content): ...` text was always visible; the naive capture-then-echo
rewrite silently regressed that — the conflict happened, but its explanation vanished.

Fix: wrap the merge call in `set +e` / capture `$?` explicitly / `set -e` again, echo the
captured output unconditionally (success or failure), then `exit "$MERGE_RC"` if non-zero
before running the "Already up to date" / `ORIG_HEAD` checks. Verified with a real
throwaway-repo conflict (same file edited differently on both branches): stdout still
carries git's own `Auto-merging`/`CONFLICT (content):`/`Automatic merge failed` lines, exit
code is git's own non-zero code, and neither the "Already up to date" message nor
`=== Files merged ===` fires on that path.

Where merge's stdout/stderr split matters: verified directly with real git repos (not
assumed) that `git merge` writes "Already up to date.", a successful merge summary, AND
conflict text all to **stdout**, never stderr. Capturing only stdout (not `2>&1`) was
therefore sufficient for both the outcome-string check and the pass-through requirement.

## What changed

`bin/worker-cli`, `merge)` case only — no other subcommand touched, no new flags. Output
shape: existing "Commits on branch … not in …" listing and merge output unchanged; a
successful real merge now additionally prints `=== Files merged ===` followed by
`git diff ORIG_HEAD --name-only`; a no-op or empty-diff merge exits non-zero with a stderr
line; a conflict exits with git's own non-zero code and its own conflict text on stdout, as
before.

## Test

`dev/worker_merge/test_merge_verify.sh` — throwaway git repo, explicit `project_path`
argument (no registry, no tmux). Three cases: a real merge (asserts `=== Files merged ===`
+ correct file list + landed commit), a repeat merge on the same branch (asserts the
"Already up to date" stderr line names both known causes + non-zero exit), and a genuine
conflict (asserts git's `CONFLICT` text reaches stdout + non-zero exit + no false
`=== Files merged ===`). All ten assertions pass as of this entry.
