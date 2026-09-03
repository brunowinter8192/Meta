# dev/

## Role

Development scripts for testing, debugging, and experimentation related to the iterative-dev plugin. Organized by area, mirroring `process-docs/<area>/` where the two align. Touch when adding probes or smoke tests; do NOT touch for production code (`src/`).

## Areas

- [session_pipeline/DOCS.md](session_pipeline/DOCS.md) — session-pipeline audit scripts (reports in `session_pipeline/md/`)
- [worker_spawn/DOCS.md](worker_spawn/DOCS.md) — spawn-flow smoke tests
- [worker_status/DOCS.md](worker_status/DOCS.md) — status-detection smoke tests
- [worker_wait/DOCS.md](worker_wait/DOCS.md) — `worker-cli wait` integration tests
- [worker_janitor/DOCS.md](worker_janitor/DOCS.md) — `worker-cli janitor` stale-worker cleanup smoke test
- [worker_merge/DOCS.md](worker_merge/DOCS.md) — `worker-cli merge` outcome-verification test
- [desktop_targeting/DOCS.md](desktop_targeting/DOCS.md) — space-move probe + report (`desktop_targeting/md/`)
- [cc_hooks/DOCS.md](cc_hooks/DOCS.md) — CC hook-input inspection helpers
- [git_automation/DOCS.md](git_automation/DOCS.md) — gcommit/git-check staging regression probes
