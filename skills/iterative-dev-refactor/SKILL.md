---
name: iterative-dev-refactor
description:
---

# Refactor Scan

## Core Rules

**Opus scans, workers fix.**
- Opus runs every scan and every classification itself, by AST walk, grep, or `wc`.
- The worker never scans and never classifies.
- The worker receives one concrete refactor and implements it.

**One Step at a time.**
- Per Step: scan, dispatch, evaluate the worker's plan, Go, review the diff, recap, merge.
- One worker per coherent unit, never a bundle of unrelated refactors.
- Step N is merged before Step N+1 is scanned.

**The run is autonomous and reports once.**
- No user stop between Steps.
- One consolidated summary at the end, per Step: what was found, what was refactored and merged.
- The summary is German, every artifact stays English.

**Thresholds are fixed.**
- No number below is softened to fit a project.
- Cosmetic LOC shrinking is never a split.

## Scope

**The user names the directory.**
- Ask for the source root or a chosen subtree before the first scan.

## Phase 1 — Architectural Form

### Step 1 — Placement

**A root-level module stays at the root only with a justification.**
- Justification is import by two or more subdirectories, or load by an external entry point.
- A module imported by a single subdirectory without an entry point moves into that subdirectory.
- `__init__.py` is skipped.

### Step 2 — Cohesion and Concern-Splitting

**File size.**
- Over 400 LOC is a split.
- 300 to 400 LOC is a watch.
- Largest first.

**Function size.**
- 50 LOC or more extracts a helper.
- 100 LOC or more is a hard target.
- Longest first, reported with file and line.

**Class state.**
- Ten or more distinct `self.<attr>` splits the class by concern.

**Constant clustering.**
- Top-level UPPER_CASE constants are grouped by leading `PREFIX_` token.
- A prefix with three or more constants is a cluster.
- Two or more clusters in one file split, one module per cluster.

**A split re-points every reference before recap.**
- The worker greps every reference to each moved symbol and confirms the new access path.
- Names deliberately left in place are whitelisted in the recap.

### Step 3 — Control-Flow Integrity

**The classifying question comes from the global testing rule.**
- A branch that produces derived output a second way is a fallback and is eliminated.
- A branch that refuses and surfaces the failure is a tripwire and stays.

**Three passes.**
- Textual: grep comments and names for `fallback`, `legacy path`, `old path`, `best-effort`, `backward-compat`, and function names containing `fallback`, `legacy`, `dedup`, `gated`.
- Structural: AST for `except` handlers that return a non-`None` value without re-raising.
- Cross-module, manual: one value or effect derived or read in two or more places that can diverge.

**Verification precedes classification.**
- Both paths are read and confirmed to derive the same value.
- Library behavior is read in the vendored source, never inferred.
- Where cheap, a live probe confirms it.

**A genuine fallback is never auto-fixed.**
- It goes through a one-way redesign with the user.
- The redesign makes one deterministic route produce the output.

**One-way redesign procedure.**
- Record once at the source, with position, identity, and order.
- Replace the runtime fallback with a test-time invariant over a real corpus, kept as a regression.
- Validate in `dev/` on real data across all cases, then port and delete the fallback chain.

## Phase 2 — Module Standards Conformance

**The worker code standard is read each run.**
- Opus reads `shared-rules/worker/code-standards`, extracts the concrete standards, and checks every module.
- A deviating module gets a worker.

**Docstrings and comments are violations.**
- Every module, class, and function docstring.
- Every comment line except the shebang and the three section markers.

**Opus scans per file.**
- `ast.get_docstring` on the module node and on every `FunctionDef`, `AsyncFunctionDef`, `ClassDef`.
- Line walk for every line whose stripped form starts with `#`, minus the allowed set.
- Files sorted by violation lines, largest first, is the dispatch order.

**Opus triages every hit before dispatch.**
- Substance recorded nowhere else goes into a new dated `process-docs/<area>/` entry, one entry per module.
- A guard on a calibrated value goes into the module's `DOCS.md` Gotchas.
- A module's purpose, reads, writes, callers, and grounding entry go into the module's `DOCS.md` entry.
- Content already covered by process-docs or `DOCS.md` is deleted.

**The worker relocates and deletes, and decides nothing.**
- The worker receives one module's hit list with the triage target per hit.
- After merge, Opus re-scans the module. Zero hits closes the Step.

## Phase 3 — Doc-Drift Check

**Workers update the touched DOCS.md with their change.**

**One drift check closes the run.**
- After the last merge, `docs-drift-check` runs once in the cwd.
- Residual drift goes to a worker, then the run is done.
