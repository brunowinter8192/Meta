---
name: iterative-dev-refactor
description:
---

# Refactor Scan

**Opus checks, workers only fix.**
Opus runs every scan and classification itself — AST walk, grep, or `wc`, whichever fits — and decides what changes. The worker NEVER checks or scans; it receives ONE concrete refactor and implements it.

**One Step at a time.**
Per Step: run its scan → dispatch the fix through workers (one worker per coherent unit, never bundle unrelated refactors) → evaluate the worker's plan against your own model → Go → review the diff → recap → merge. Step N's fix is merged before Step N+1 starts. Never scan ahead.

**Run autonomously — report once.**
No user stop between Steps; drive the run end-to-end and give ONE consolidated prose summary at the very end (per Step: what was found, what was refactored + merged). Every report is written in German; all artifacts (code, DOCS.md) stay English.

**Thresholds are fixed.**
The numbers below are exact — never soften one to fit a project; only the way you write the scan adapts. Cosmetic LOC shrinking (trimming blanks, merging comments) is never a split.

## Scope

ASK the user which directory to refactor (the source root — `src/` or a chosen subtree).

## Phase 1 — Architectural Form

### Step 1 — Placement

Is every top-level module in the right place? A `src/*.py` at the root (skip `__init__`) is justified only if ≥2 subdirectories import it OR an external entry-point loads it (`python -m x`, a uvicorn `x:app` path, `mitmproxy -s`). Imported by a single subdir with no entry-point → move it into that subdir.

### Step 2 — Cohesion & Concern-Splitting

Does one place carry too much and want to split?

- **File size.**
  >400 LOC = hard (split); 300–400 = watch. Largest first.
- **Function size.**
  ≥50 LOC = extract a helper; ≥100 = hard target. Longest first, with file:line.
- **Class state.**
  ≥10 distinct `self.<attr>` (plain + annotated) → split by concern.
- **Constant clustering.**
  Per module, group top-level UPPER_CASE constants by leading `PREFIX_` token; a prefix with ≥3 constants is a cluster; ≥2 clusters in one file → split, each cluster its own module.

**Consequence — any split relocates symbols, so the worker re-points every reference before recap.**
A split moves functions / constants / attributes to new modules. Post-implementation, before recap, the worker greps EVERY reference to each moved symbol and confirms it resolves to the new access path. Whitelist names deliberately left in place.

### Step 3 — Control-Flow Integrity

Fallback vs tripwire is DEFINED in the global testing rules (`shared-rules/global/testing.md` § Fallback and Tripwire) — that rule is the single source of the classifying question and the one-way-redesign pillars; this Step only carries the scan procedure. Classify every hit with the rule's question: does it produce derived output a second way (fallback → eliminate), or refuse and surface (tripwire → keep)?

Three passes:

- **Pass 1 — Textual:**
  grep comments and names for `fallback`, `legacy path`, `old path`, `best-effort`, `backward-compat`, and function names containing `fallback` / `legacy` / `dedup` / `gated`.
- **Pass 2 — Structural (AST):**
  `except` handlers that return a non-`None` value without re-raising — an `except` that produces output instead of surfacing failure.
- **Pass 3 — Cross-module (manual — the AST pass misses this):**
  one conceptual value or effect derived/read in ≥2 places that can diverge. Patterns: two periodic loops doing the same op; one value read from two sources (idle from two mtimes; "is X running" from state-file vs port-scan vs process-scan); the same op in two places with divergent behavior; a hardcoded default consulted when the canonical source is absent; a sentinel `if <key> in x: <new> else: <old>`.

**Verify at the source before classifying:**
read BOTH paths and confirm they derive the same value; for external/library behavior read the vendored source for the categorical answer (never infer from training knowledge); where cheap, confirm with a live probe (lsof, curl, one-shot call).

**Consequence — a genuine fallback is NEVER auto-fixed; it goes through a One-Way Redesign, worked through WITH the user.**
The redesign makes a SINGLE deterministic route produce the output, per the pillars in the testing rule (completeness as a code property, safety check in a test over a real corpus, production runs one way). The procedure:

1. **Record once at the source.**
   Capture the data at the point of truth with enough information (position, identity, order) that a single deterministic path produces the output later — no re-derivation downstream.
2. **Replace the runtime fallback with a test-time invariant.**
   `source + recorded operations == produced output`, asserted over a real corpus and kept as a CI regression. A failure there = a code site that forgot to record → fix the site.
3. **Validate in `dev/` before touching `src/`.**
   Build the redesign as a `dev/` probe, prove exact equivalence on real data across ALL cases, THEN port to `src/` and delete the fallback chain.

## Phase 2 — Module Standards Conformance

The worker coding standard (`shared-rules/worker/code-standards`) defines how a single module is written. Opus does NOT get it in context — READ it each run, extract the concrete standards, and check every module against them. A module that deviates from a standard → dispatch a worker to bring it into conformance.

**Docstrings and comments — the code is self-documenting; prose does not live in it.**
Every module, class, and function docstring is removed. Every comment that documents code — what a function does, why a value was chosen, what was tried, which paper grounds it — is removed. The only comment lines that survive are section markers (`# INFRASTRUCTURE`, `# ORCHESTRATOR`, `# FUNCTIONS`) and cross-module import annotations on `import` lines. A one-line function header is a documenting comment and goes too; the function's name carries that.

Scan (Opus runs it, per file, AST + line walk):

- `ast.get_docstring` on the module node and on every `FunctionDef` / `AsyncFunctionDef` / `ClassDef` → every hit is a violation; report file, node name, docstring line count.
- Every line whose stripped form starts with `#`, excluding the shebang, the three section markers, and inline annotations on `import` lines → violation; report file:line and the comment's first 80 chars.
- Sort files by total violation lines, largest first; that is the dispatch order.

Triage every hit's CONTENT before deleting — nothing of substance is lost, it is relocated:

- Substance recorded nowhere else (derivation, measurement, trade-off, source citation, the reason a constant has its value) → write it into a NEW dated `process-docs/<area>/` entry of the area the value belongs to. One entry per module cleaned, titled as a comment-migration entry, so the reader knows where the prose went.
- A guard on a calibrated value ("do not change without evidence") → one line in the module's `DOCS.md` Gotchas.
- A module's purpose, reads, writes, callers, and grounding entry → the module's `DOCS.md` entry, which is the ONLY place that description lives.
- Content already covered by process-docs or `DOCS.md` → delete outright.

The worker receives the scan's hit list for ONE module plus the triage of every hit (which target, or delete), written by Opus. The worker relocates and deletes; it does not decide. Re-scan after merge: zero hits, or the Step is not closed.

## Phase 3 — Doc-Drift Check

Refactor workers update the touched DOCS.md alongside their code change as they go. At the very END — after every Step's fix is merged — run `docs-drift-check` (cwd) ONCE. Clean → done. Residual drift → fix it (worker), then done.
