---
name: iterative-dev-duallog
description: 
---

# Dual-Log Reading — Skill

**The dual_log is the byte-level record of every CC session — read it ONLY through the CLI.**
Invocation: `duallog <command>` (in PATH; runs the monitor-cc main checkout).

**The timeline is the deduplicated conversation, not the raw log.**
It is reconstructed from the LAST conversation request of the session, with request boundaries interleaved as `── REQ N ──` markers. Each turn shows role, block types (`text` / `tool_use[Tool]` / `tool_result` / `thinking`), char sizes, and a 100-char preview per block. A `WARNING` header line means a `/clear` restart happened inside the log id — request markers before it do not align with the final message list.

**`search` finds a term ONCE, not once per request.**
`search <session> <term>` searches the deduplicated timeline (case-insensitive by default, `--case-sensitive` to override). One hit line per (turn, block), a block holding the term N times shows `×N`. Searched text is each block's FULL content, including tool_use JSON inputs — `search <s> "worker-cli merge"` finds the command inside a Bash call. Raw-file greps overcount by ~100×; the header's occurrence count is the true number.

**Drill into one turn with `--turn N --full`.**
The compact timeline previews only. For the complete content of one turn: `timeline <session> --turn N --full`. Piping through `head` is safe — the CLI exits silently on a closed pipe.

**Live sessions move under you.**
The proxy appends to open sessions while you read; every invocation re-reads the current end of the log. Identical counts across two invocations are not guaranteed for a running session.

## Commands

| Command | Args | Does |
|---|---|---|
| sessions | — | List all sessions with start, context, stem, requests, messages, size — newest first |
| timeline | session [--turn N] [--full] | Deduplicated turn timeline of one session; `--turn` restricts to one turn, `--full` prints that turn's complete block contents |
| search | session term [--case-sensitive] | Find a term in one session's deduplicated timeline — one hit per (turn, block) with `×N` occurrence count |

## Search Strategy

1. `sessions` for the inventory — every session newest-first with start time, context (`opus/<project>` or `worker/<name>`), stem, request count, message count, size. Pick the target here.
2. `timeline <session>` for the shape — turns, request markers, block sizes, previews. `<session>` is the full stem or any unambiguous substring (`gh_cli_1787995963` works); an ambiguous one errors with the candidate list.
3. `search <session> <term>` to locate content, then `timeline <session> --turn N --full` to read a hit's complete turn.
