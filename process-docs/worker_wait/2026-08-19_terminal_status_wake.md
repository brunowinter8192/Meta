# `worker-cli wait` — Terminal Status Wakes Instead of Blocking

Live incident: a worker's `claude` process died silently mid-session; `worker_status`
returned verbatim `unknown` on every poll forever. `wait` treated anything != `idle` as
not-idle (fail-toward-waiting), so it held until a manual kill — would have burned the full
3300s timeout ceiling on a worker that was never coming back. Decision: a STABLY terminal
status is effectively idle toward the all-idle decision — a dead worker needs orchestrator
intervention, not more sleeping.

## Vocabulary verified, not assumed

`_worker_detect_status`/`worker_status` (`src/spawn/tmux_spawn.sh`) return exactly 4 literal
strings: `working`, `idle`, `limit reached`, `unknown`. Closed set, confirmed by reading the
function body line by line (`tmux_spawn.sh:103-239`), not inferred from the usage comment.

## `unknown` is transient-by-design — the tension, resolved by cost asymmetry

`process-docs/worker_status/worker_status_three_state.md` explicitly documents `unknown` as
"the honest no-data-yet fallback during spawn-init... NOT one of the three decision states"
— i.e. designed to be transient (fresh spawn before its JSONL/hook entry exists), not a
peer of `limit reached` (which IS one of the three real decision states, "anything
forcefully/abnormally stopped... collapses into `limit reached`").

This directly conflicts with folding bare `unknown` into terminal-ok on the SAME 15s
(3-sample x 5s) stability window already used for the idle transition: a worker merely slow
to boot, or hitting a momentary probe blip, could misclassify as terminal before it ever
gets a chance to report real status. Resolved not by excluding `unknown` (that would leave
the reported incident — literally `unknown` forever — unfixed) but by accepting the
trade-off explicitly: a false-positive terminal wake costs one spurious orchestrator check
(cheap, self-correcting — the orchestrator re-`wait`s once it sees the worker is actually
fine); the old failure mode was a silent, unrecoverable 55min hang. Implemented exactly as
proposed: whitelist `idle` + `{"limit reached", "unknown"}` as non-blocking, same
`_WAIT_STABLE_SAMPLES` window, no new threshold invented.

**This trade-off materialized live in this milestone's own verification** (see below) — not
just a theoretical risk.

## Bg-task probe deliberately skipped for terminal statuses

The existing `_wait_has_live_bg_task` probe (idle-only) does its own tmux/JSONL lookups.
Applying it to a terminal (`unknown`/`limit reached`) worker would very plausibly fail for
the same reason the worker is terminal in the first place (`-> "error" -> busy` under the
probe's own fail-toward-waiting contract) — silently re-trapping `wait` in the exact
"blocks forever on an unresolvable probe" failure this whole change fixes. Semantically:
even a genuinely still-running orphaned bg process (double-forked, survives its dead
coordinator) doesn't change that the orchestrator must intervene on a terminal worker
either way — nobody is left to consume that bg task's result. Test 10 regression-guards
this: a terminal worker with a real open `*.output` handle still exits `"worker terminal"`
promptly, unlike Test 5's `idle`+bg case, which holds.

## Test 4 (`probe-vanishes`, session killed mid-wait) needed NO contract change

Confirmed via `worker_list` (`tmux_spawn.sh:193-218`): it enumerates via `tmux list-sessions
| grep <prefix>` — a killed session simply stops appearing in `NAMES`, never reaches
`worker_status()`'s per-worker branch at all. That scenario was already fully owned by the
pre-existing empty-`NAMES`/`EMPTY_COUNT` -> `"no workers"`/timeout path (2026-08-18 C3
milestone, same area). The new terminal path only ever fires for a worker STILL enumerated
by `worker_list` (session/pane alive) whose `worker_status()` call returns
`unknown`/`limit reached` — a structurally different, new fixture shape
(`create_worker_no_hook`: claude-dummy child alive + JSONL present, but no `hooks.json`
entry ever set, so the "no hook entry" branch returns `unknown` forever) from Test 4's
session-GONE fixture.

## Exit vocabulary

New exit line `"worker terminal"` — distinct from `"workers idle"`. Grepped this repo for
consumers parsing `wait`'s exact output strings before adding a fourth one (after `"workers
idle"`, `"no workers"`, `"timeout"`): none found outside the test suite itself, same check
the 2026-08-18 C3 milestone already did for `"no workers"`.

## Trace

Every `event=poll` line now carries `class=busy|idle|terminal`; `event=decision` carries
`all_nonblocking=`/`any_terminal=` (renamed from `all_idle=`, nothing external parses this
field — grepped, only this suite's own tests and the DOCS.md prose reference it, both
updated); new `event=exit reason=worker_terminal`.

## Verification

Full run of `dev/worker_wait/test_worker_wait.sh` — real `worker-cli wait` binary, real tmux
sessions, real `hooks.json`, real `wait_trace.log`. 4 new fixture tests added (7-10) on top
of the existing 6:

- **Test 7** — session alive, `hooks.json` entry never set -> stuck `unknown` (the live
  incident's exact shape) -> exits `"worker terminal"` in 11s; trace shows `class=terminal`
  + `event=exit reason=worker_terminal`.
- **Test 8** — wrapper exits immediately (zero children, pane held by `remain-on-exit`) ->
  stuck `limit reached` -> exits `"worker terminal"` in 10s.
- **Test 9** — mixed project: one worker terminal from the start, one genuinely `working`.
  `wait` stays alive past 5s (terminal didn't short-circuit the busy worker); once the busy
  one flips to `idle`, exits `"worker terminal"` (not `"workers idle"`) 11s later — proves
  fold-in + exit-line precedence together.
- **Test 10** — terminal worker (`unknown`) with a genuinely open `*.output` handle -> still
  exits `"worker terminal"` in 11s, not held — proves the bg-check-skip decision.

First full-suite run: 18/19 checks passed, **Test 1b failed** (`reason='worker terminal'`,
expected `'workers idle'`) — an idle worker with a persistent tooling-child grandchild
(unrelated fixture, unchanged from the prior milestone). Trace for that run
(`pid=30163 project=waittest28200-1b`) showed the worker's own `worker_status` flip
`idle` -> `unknown` -> `unknown` for 2 consecutive polls (10s), then stabilize back — a live
capture of exactly the accepted trade-off above, not a bug in the new classification logic:
(a) isolated reproduction of the identical fixture via direct `worker_status` calls stayed
`idle` for a steady 12s with zero flips; (b) the full suite rerun immediately after passed
clean, 19/19, with the same fixture reporting `idle` throughout
(`event=poll worker=w1 status=idle bg=no class=idle` on every one of its 3 polls). Root
cause not chased further into `_worker_detect_status` itself (`tmux_spawn.sh` stays
untouched — established boundary for this whole area) — flagged here as an observed,
accepted cost, not silently hidden.

Verified at the entry-point level: the real `bin/worker-cli wait` subcommand, real argument
parsing, real polling loop, real tmux + real `hooks.json` reads. NOT verified: actual
orchestrator-side wiring reacting to the new `"worker terminal"` string (out of scope here —
orchestrator prompt/rule updates are Opus's surface, not touched).
