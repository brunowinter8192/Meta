---
name: iterative-dev-doccheck
description:
---

# Doc & Structure Check

**Subject.**
A project's documentation surface: `process-docs/**`, every `DOCS.md`, `dev/` reports, `skills/*/SKILL.md`. The skill systematically verifies this surface complies with the rules defined in § Documentation Hierarchy.

**Reference.**
§ Documentation Hierarchy is THE standard — the sole source of what correct docs + structure look like, and it wins over the project's current state. NEVER accept an existing structure as a "project convention" that excuses a deviation — "it's consistent everywhere" is not a defense; a consistent deviation is still a deviation. Diverges from a rule → flag it, bring it into line; a deviation stays only on an explicit user decision made LIVE in the current session — activating this skill IS that instruction to enforce the standard, so a past artifact (a historical note, a code comment, an old doc that records a prior choice) NEVER counts as a deviation-preserving decision. The sole sanctioned carve-out is the Step 0 contact-layer exclusion — never your own "it already works". "A deviation stays only on an explicit user decision" governs KEEPING a deviation, not fixing one — fixing is the default and needs no confirmation.

**Work Step by Step.**
The Workflow below adds no rules of its own; its Steps and Stages only fix the ORDER of what to check, mirroring the split of § Documentation Hierarchy. Read/grep across all a Step's Stages, then fix at the end of the Step — one fix pass per Step, not per Stage.

**Run the whole audit through without pausing.**
Apply the fixes and move on, NEVER stop to ask per finding — the size of a fix, or that it is not purely mechanical, is no reason to pause; a fix that follows from the rules gets applied in full, however substantial the reshaping. A fix that triggers a second violation is not a dilemma to report — resolve that one too in the same pass, the rules compose to a fully compliant surface. Report ONCE, at the very end (Step 6 — Hand off). Exception: Step 4 (skills) is flag-only — collect the findings there, never fix.

**Volume is never a scope argument — assume an infinite token budget.**
NEVER sample, shortcut, or do only "part"; every rule-driven fix is carried through in full, however many files it takes. A context limit is not a stop and not grounds to declare partial work "done": commit incrementally (after each Step/area) so nothing is lost, and the run resumes from the last commit — where a worker hit its limit, the orchestrator spawns a successor that picks up from there. Binds worker and orchestrator alike: a worker NEVER trims a task for size, commits per area, and works until done or until its limit.

**Report language: German.**
Every report is written in German. This governs the chat surface only; all ARTIFACTS (process-docs, DOCS.md, code) stay English per § Documentation Hierarchy, regardless of the German chat.

**Step blinders — the Steps are separate layers, never cross-fed.**
Each Step's scope is deliberately narrow: look ONLY at that Step's surface (Step 1 process-docs; Step 2 dev; Step 3 DOCS.md; Step 4 skills; Step 5 issues). The aperture widens Step by Step — knowledge gathered earlier may inform a later Step, but only within the frame the CURRENT Step defines; never reach back to re-open a closed Step. The surfaces do not source each other: process-docs is write-once history, DOCS.md is current state maintained from the CODE. The question "does layer A carry content layer B needs?" must NOT arise — it is a category error; a fix in one layer NEVER ports content into another. "In process-docs but not in DOCS.md" is not a portable gap; a reframed process-docs entry has zero bearing on DOCS.md completeness, which is judged only against the code.

## Workflow

### Step 0 — Contact-layer check (orchestrator only, once, before the audit)

If you are Opus (orchestrator), ask the user ONE upfront question before Step 1: "Besides this chat, does the project have a user-facing contact layer — a directory of files authored FOR or delivered TO the user, not the internal doc surface?" (Standard project: the chat is the only contact layer → no. Non-standard: e.g. an exported-concepts / deliverables directory where the user is the recipient → yes, plus its path.)

- **No**
  every directory is in scope; the standard applies to all of it.
- **Yes**
  the named directory is a user-owned surface: EXCLUDE it entirely from every Step — never relocate, rename, translate, reframe, or reformat anything inside it; leave it exactly as-is.

A WORKER never asks this. The orchestrator passes any excluded contact-layer path in the worker's prompt (as with handoff); the worker excludes exactly what the prompt names, nothing more.

### Step 1 — process-docs

Touch ONLY process-docs in this Step — NEVER migrate its content into a `DOCS.md` or any other surface. process-docs are write-once, potentially-stale snapshots; `DOCS.md` is maintained from the CODE, not copied from process-docs prose. "In process-docs but not in DOCS.md" is NOT a portable gap. A present-tense "current state" entry (§ process docs violation) is fixed within process-docs and needs no code — it is binary: reframe it as a dated snapshot in its thematic area folder, or delete it if it holds no historical value. process-docs MAY be historical, so its currency is irrelevant here.

#### Stage 1 — structure

Check § process docs (Root-anchored, one fixed name).

#### Stage 2 — area assignment

Check every `process-docs/<area>/` folder against § process docs (Area = work strand with its own driving question, New area vs existing area). NOT a glance-over: produce an explicit per-folder verdict — no folder is skipped, no verdict is implicit.

Per folder, in order:

1. **State its driving question in one sentence.** Cannot state one → the folder is not an area → dissolve, route entries to their true areas.
2. **Single-settled-question test.** The folder's content is one question that one entry (or one session) settled → not an area → fold the entry into the area whose strand it belongs to.
3. **Entry-membership test.** Per entry: does THIS entry answer THIS folder's driving question? An entry answering a DIFFERENT area's question moves there — a folder can be a valid area and still hold misfiled entries.
4. **Overlap test.** Two folders whose driving questions are one question → merge.

Fold, split, or dissolve accordingly; a rename propagates to `dev/<area>/`. Open items from a dissolved maintained-list folder are issue material — flag them in the report. The Step-6 report lists every folder with its verdict (`valid: <driving question>` / `folded into X` / `split into X+Y` / `dissolved`) and every entry that moved.

#### Stage 3 — invariants

Check § No Issue References and § process docs (no present-tense current/production claims, dense/dated/thematic, no cross-references to another process-docs entry, evidence inline).

#### Stage 4 — language

Check § Language across every `process-docs/` entry.

#### Stage 5 — RAG manifest

Check `.rag-docs.json` at project root:

- `include` MUST cover the full docs surface: every `DOCS.md` AND `process-docs/**/*.md`. A manifest missing the `process-docs` layer → add the pattern.
- Every `include` pattern matches ≥1 file on disk → a dead pattern (matches nothing) is removed.
- `collection` follows `<Project>-docs` naming.
- No manifest present → flag in the report; do not create one.
- Do NOT run `rag-cli update_docs` here — index sync is a session-recap action.

### Step 2 — dev

Check § dev reports. Beyond the rule, apply on invocation:

- A maintenance/utility script (reclean, one-shot fixer) goes in its thematic `dev/<area>/` — no exempt catch-all folder. A loose `.md` in `dev/` that **no script produces** (a hand-written run summary / analysis) is NOT a dev report → it belongs in `process-docs/` if still relevant, or is deleted if stale.
- Assign each dev folder to its area (determine the fit from its `DOCS.md` / module docstring / contents). Belongs to ONE area → rename the folder to that area name. Contents spanning MULTIPLE areas is the real fix and the hard one → split the folder, routing each part into its own `dev/<area>/`.
- **Report vs DATA**
  distinguish by content: a report is a readable analysis (a JSON *analysis* output counts → `md/`); data is the run's raw payload (scraped corpora, raw dumps, cached job data).
- **Cumulative logs stay.**
  An append-only log tracked + compared across runs (institutional history, not a single-run analysis) is NOT a report → leave in place.
- **Sub-suite own `md/`.**
  A self-contained sub-eval folder (`garbage_eval/`, `browser_eval/`) gets its OWN `md/`, not the parent area's.

### Step 3 — DOCS

Use heredoc / `/tmp` scripts — do not read every `DOCS.md` by hand.

#### Stage 1 — placement

Check § docs (Placement). Beyond the rule: **Root files** — `README.md` → flag for removal; a root `DOCS.md` that is a project overview → flag for removal; a root `CLAUDE.md` documenting project-only interactive working areas → allowed, do not flag.

#### Stage 2 — format

Check § docs (DOCS.md Format). Beyond the rule: **References resolve** — every file a `DOCS.md` names exists on disk; a reference to a nonexistent file → delete it from the `DOCS.md`.

#### Stage 3 — language

Check § Language across every `DOCS.md`.

### Step 4 — skills (flag-only)

Check § Artifact Density against each `skills/*/SKILL.md`. Beyond the rule:

`skills/*/SKILL.md` = procedure, not essay: WHAT (capability + output) and HOW (steps, commands, thresholds, formats, rules incl. "do NOT X"), never WHY.

**Frontmatter.**
`description:` is present but empty — flag any non-empty `description` and blank it.

Removability test per clause: reader still executes exactly the same without it? Yes → WHY → cut. A concrete example stays only when it shows HOW to decide.

Flag WHY-content by signature:

| Signature | Example | Action |
|---|---|---|
| Justification clause | "raw and maximal — content not captured is gone for good" | cut clause, keep instruction |
| Cause / mechanism | "the plugin cache has NO venv, so a plugin-relative path fails" | cut |
| Rationale section | a "Why X matters" section | delete section |
| Historical / evidence note | "(verified on 278 files)", "previous runs failed here" | cut |
| Illustrative "what happens otherwise" | "the same anchor just returns the same top sources" | cut |
| `because` / `so that` / `in order to` / `which means` | any clause led by these | cut clause |

Keep — never flag: commands, paths, thresholds, output formats, parameter tables, ordering rules, prohibitions, behavior facts the procedure depends on, decision-examples.

### Step 5 — issues (orchestrator only)

Runs LAST — after Steps 1-4 the area structure is final. A WORKER skips this Step entirely (no gh-cli).

Check every OPEN issue of the project (`gh-cli list_issues`, owner/repo from `git remote get-url origin`) against § GitHub Issues (Issue Format). Bring every body into that format via `update_issue --body` (full-replace):

- Rewrite `What it is:` to 2-3 sentences if it carries iteration history or decision rationale.
- Replace any Source-Inventory / file-path list with the `Area:` line — the area per the POST-audit folder structure (Steps 1-2 may have renamed/merged the folder the issue pointed to).
- Set the `Resume:` line to the area-scoped RAG search.

### Step 6 — Hand off

Report your findings (Step 4 flags + Step 5 issue rewrites included). Then, if you are Opus: commit your doc fixes and spawn a worker to activate this skill (`iterative-dev-doccheck`) — it re-runs the audit on the committed state and applies the flagged source fixes (source edits are worker-only). Hand the worker, in its prompt, every source fix you already established — concrete file, location, and change. Review + merge each worker's branch; where a worker hits its context limit mid-work, spawn a successor from the last commit and continue until the chain reports done. Do NOT sync RAG here — the RAG sync is a session-recap action on the final merged state, not the skill's concern. If you are a worker, you're done — no spawn.
