# Rule Observation 2026-06-04 — Check Context BEFORE the Reuse-vs-Fresh Decision

Orchestration-behaviour observation from a real session, recorded 2026-06-04 as a CANDIDATE
refinement to the worker rules (`~/.claude/shared-rules/opus/workers-*.md`) — status at recording
time: "seen once, observing", not a hardened rule.

**Waste definition (user):** waste = a worker already holds full usable context for a topic and a
BUILDING-ON task is delegated to a NEWLY spawned worker. NOT waste = fresh spawn for a completely
independent/orthogonal topic (no context to reuse), or fresh spawn because the context-rich worker
is at context-floor (near-exhausted, knowledge already persisted to disk).

**Instance (monitor-cc, inline-span work):**
- `span-probe` had just validated the inline-span data model (read `diff_engine`/`logging`/`parser`,
  wrote OldThemes 09).
- The src/ PORT (building-on) was handed to a FRESH worker (`inline-render`) while `span-probe` was
  alive → the waste pattern.
- Not caught proactively — the user challenged the spawn decision. The "correction" then THRASHED:
  kill `inline-render` → redirect to `span-probe` WITHOUT checking its context → `span-probe` was
  context-dead ("Prompt is too long") → re-spawn `inline-render`. Three moves where one would have
  sufficed.

**Candidate rule:** before spawning a worker for a building-on task —
1. `worker-cli list` → is there an alive worker with context overlap?
2. Check ITS context % (`Sonnet | X%` from capture).
3. Healthy → reuse. Near-floor → spawn fresh reading the persisted docs (OldThemes / merged code).
The waste was skipping (1)+(2): spawned fresh blindly, then thrashed the correction by also skipping
(2) on `span-probe`.

**Counter-examples same session (NOT waste):** `header-mods`/`span-probe`/`janitor`/`attribution`
(independent topics, no reuse candidate); `inline-render-2`/`attribution2` (forced fresh after prior
worker context-death); `display-tweaks` (reuse candidate `inline-render` was alive but at 24% —
context checked first, judged near-floor, spawned fresh reading OldThemes 10 — lesson applied).

**Status:** OBSERVATION. Watching for recurrence before hardening into `workers-3.md` AGGRESSIVE
REUSE.
