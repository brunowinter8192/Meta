# dev/worker_merge/

## Role

Test for `worker-cli merge` (`bin/worker-cli`, `merge` case) — the merge command's
built-in outcome verification, which replaced the orchestrator's by-hand post-merge check.

## Modules

### test_merge_verify.sh

**Purpose:** Exercise the real `worker-cli merge` binary against a throwaway git repo
(explicit `project_path` argument, no registry entry, no tmux). Covers a real merge
(branch with a commit) printing `=== Files merged ===` with the correct file list and
landing the merge commit, and a repeat merge on the same fully-merged branch hitting the
"Already up to date" no-op path — asserts the stderr line names the no-op and both known
causes (missing `project_path` on a cross-project worker; a worker that never committed),
plus the non-zero exit code.
**Usage:** `bash dev/worker_merge/test_merge_verify.sh`
