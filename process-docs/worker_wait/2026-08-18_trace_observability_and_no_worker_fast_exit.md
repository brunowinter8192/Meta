# `worker-cli wait` — Poll Trace (C1) + No-Worker Fast Exit (C3)

Follow-up milestone to the 2026-08-17 handle-based bg-task rewrite (this same area). Origin: a
cross-repo audit of the whole orchestrator wake-up chain (monitor-cc's `timer-loop` area) reported
`wait` broken in live use, with "always runs into its timeout ceiling" as one open candidate. That
audit's own process-docs entry (monitor-cc `timer-loop` area, not duplicated here) narrowed the
live-observed timeouts down to three named root-cause candidates — C1 (no observability, so a
timeout was indistinguishable from a legitimately long-running worker), C2 (lsof/PATH probe
hardening — explicitly NOT done here, unconfirmed as the actual cause), and C3 (empty-`NAMES`
looping to the full ceiling with no fast path, already a documented/tested behavior in this area's
own suite). This entry covers C1 and C3, implemented together.

## C1 — durable per-poll trace

**Format decision — one shared, growing file, not one per invocation.** `worker_logger.sh` (this
same package) is the only prior "durable trace" convention here: per-worker timestamped files,
never pruned. Deliberately NOT copied verbatim: a shared file (`wait_trace.log`, same
`WORKER_LOGGER_DIR` override + default `worker_logger.sh` already uses) means concurrent `wait`
calls for the same project — the exact shape Test 3 already exercises — interleave chronologically
in one place, tagged by `pid=$$`. That's a deliberate secondary benefit: the trace itself can now
surface stacked/duplicate `wait` arms as a visible pattern, which is an open question in the
sibling monitor-cc audit that this repo can't answer on its own but can now leave evidence for.

**Granularity — one line per worker per poll, not one aggregate line.** Logs in the same order the
existing loop already checks workers, stopping at the first non-idle blocker exactly where the
loop's own short-circuit already stops — no new subprocess calls added, no behavior change to the
polling cost. `status` values with embedded spaces (`"limit reached"`) are normalized to
`limit_reached` in the trace so every field stays single-token (grep/awk-friendly), separate from
the plain-text `worker_status` output.

**Bounded, no unbounded growth — the gap this repo hadn't closed anywhere else.**
`worker_logger.sh`'s own per-worker files are never pruned; nothing in this repo bounds file COUNT
over time. `_wait_trace_init` checks the shared file's line count once per `wait` INVOCATION (not
per poll — a single invocation is already self-bounded, a few thousand lines worst case) and trims
to the most recent 10000 lines if it exceeds 20000. Verified by hand (not part of the committed
suite — a one-off check): force-grew the real trace file to 25000 lines, ran one `wait` call,
confirmed it trimmed to 10000 + that invocation's own 3 new lines, then restored the original file.

**`set -e` discipline.** `bin/worker-cli` runs under `set -e` (line 5) — the exact failure class
already live-caught once in this area (`_wait_has_live_bg_task`'s lsof-exit-code/`set -e`
incident, prior entry). Every trace write and the trim step is `|| true`-guarded and
existence-checked before use; a disk-full or permission hiccup on the trace file must never abort
the wait loop itself.

## C3 — no-worker fast exit

**Chosen semantics: grace window, not immediate exit — reusing the existing stability-window
constants, not a new threshold.** The prevailing design invariant for `wait` (this area's own
2026-08-17 entry, and the monitor-cc `timer-loop` area's architecture-decision entry) is that
every failure mode should collapse into waking LATE, never early or wrong. An immediate exit on
the first empty-`NAMES` sample would risk exactly a wrong-direction early wake if `spawn`'s
`tmux new-session` return doesn't guarantee instantaneous visibility to a SEPARATE `tmux
list-sessions` call — the "spawn racing the wait arm" case. Requiring 3 consecutive empty polls
(same 5s-poll/10-15s span already trusted for the idle-transition case) absorbs that race with the
same mechanism, not a new invented number: a worker appearing mid-window resets the empty counter
to 0 and falls through to normal idle-tracking, no special-casing needed.

**Trade-off made explicitly, not hidden:** this conflates "genuinely zero workers ever" with
"`worker_list` failing to report existing workers" (`wait`'s existing "best-effort listing"
comment already treats both as empty `NAMES`). A `worker_list` outage lasting the full grace
window while a real worker exists would now exit early with a `"no workers"` label that's
technically wrong, vs. the pre-fix behavior of grinding to the 3300s ceiling regardless. Judged
acceptable: a single bad poll self-heals (doesn't reset to "confirmed no workers"), and the case
being fixed (genuinely zero workers, already documented as a designed-in timeout in this area's
own test suite before this milestone) is far more common in live use than a multi-poll tmux
outage.

**New, distinct exit string** — `"no workers"`, not a reuse of `"workers idle"`. Grepped this repo
for any consumer parsing `wait`'s exact output strings before adding a third one: none found
outside the test suite itself.

## Verification

Full real run of `dev/worker_wait/test_worker_wait.sh` (real `worker-cli` binary, real tmux
sessions, real `hooks.json`, exit 0, all 12 checks PASS) — 3 new/changed cases specifically:

- **Test 1c** (new): a before/after byte-offset diff on the real, live, shared `wait_trace.log`
  (not a test-isolated copy) confirms a normal idle-worker run writes both `event=start` and
  `event=exit reason=workers_idle`.
- **Test 2** (contract changed): `--timeout 20` against a project with no worker ever registered
  now exits `"no workers"` at 9-20s (measured: 10s) — was `"timeout"` at 6-15s before this
  milestone.
- **Test 2b** (new): `--timeout 3` — shorter than the ~10-15s grace window — still exits
  `"timeout"` cleanly (measured: 5s, capped by 5s poll granularity), proving the two exit paths
  compose without interference.

**Test 4 needed hand-verification of a timing margin, not just running it.** Test 4 kills a
worker's tmux session mid-wait with `--timeout 12`; after the kill, `worker_list` returns empty
`NAMES` (the session no longer matches the tmux prefix scan) — the exact new empty-`NAMES` path
this milestone added. Traced the iteration timing by hand before running: the empty-grace-window
needs 3 full polls (~15s worst case from when the session vanishes) to fire `"no workers"`, while
the `--timeout 12` ceiling check runs at the TOP of the same loop iteration and wins first at
elapsed=15 — a real one-iteration structural margin (`_WAIT_STABLE_SAMPLES` polls always land one
iteration after the ceiling here), not a coincidence of the specific numbers chosen. Confirmed
empirically afterward — Test 4 passed unchanged.

Two standalone smoke tests run before touching the suite (`--timeout 20` on a nonexistent project
→ `"no workers"` at 10s with a correctly populated trace; `--timeout 3` → `"timeout"` at 5s) —
same results as the later formal Test 2/2b, cross-confirming before the suite edit.

## Explicitly not done

C2 (lsof/PATH hardening on `_wait_has_live_bg_task`) — the live-observed timeouts this milestone
traces back to never confirmed a probe-error as the cause; C1's trace exists specifically so a
future recurrence is diagnosable from the trace instead of requiring another forensic
reconstruction, rather than hardening a mechanism whose failure was never actually confirmed live.
No other `worker-cli` subcommand touched.
