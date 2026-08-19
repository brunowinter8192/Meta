# dev/worker_janitor/

## Role

Smoke test for `worker-cli janitor` (`bin/worker-cli`, `janitor` case) — the stale-worker
tmux/worktree/branch/registry cleanup sweep.

## Modules

### test_janitor.sh

**Purpose:** Exercise the real `worker-cli janitor` binary against real tmux sessions in a
throwaway git repo, with `WORKER_REGISTRY_DIR`/`WORKER_LOGGER_DIR` overrides. Covers:
`--max-age-hours 0 --dry-run` listing a stale synthetic session as a candidate without
killing it; a real run (`--max-age-hours 0`) killing it end-to-end (tmux session + worktree
+ branch + registry, via the reused `kill` path) with a `janitor.log` line; a fresh synthetic
session spared by the default 12h age gate; an orphan registry entry (registry file with no
live tmux session, past the spawn-race grace window) cleaned via the same kill path.

**Tmux isolation:** `janitor` sweeps ALL `worker-*` sessions on the tmux server — unlike
`worker-cli wait`/`list` (project-scoped), there is no natural scope to keep a real-kill test
away from live sessions. The script PATH-shadows a `tmux` wrapper (`exec real-tmux -L
janitor_smoke_test_$$ "$@"`) for its own subprocess tree only: `tmux -L` spins up a fully
separate server, invisible to the default one (verified empirically — `TMUX_TMPDIR` alone
does NOT isolate when already inside a tmux session, since `$TMUX` wins). `bin/worker-cli`'s
bare `tmux` calls resolve through PATH to this wrapper transparently — zero source changes,
and the real-kill pass can never reach live state (`keep-filters`, `menubar-remote`, etc.)
even at `--max-age-hours 0` matching everything.

**Dot-in-basename gotcha:** project dirs use a dot-free subdir name (`mktemp -d`'s default
macOS `tmp.XXXXXXXX` prefix contains a `.`) — tmux silently rewrites `.`/`:` (reserved
target-spec separators) to `_` in session names, desyncing the actual live session name from
what `_worker_session_name` (`src/spawn/tmux_spawn.sh`) computes from the path's basename.
Latent in the wider spawn system too (not janitor-specific) — sidestepped here, not fixed.

**Usage:** `bash dev/worker_janitor/test_janitor.sh` (~10s; creates/kills real tmux sessions
on an isolated `-L` server + a throwaway git repo, all torn down via `trap ... EXIT`).
