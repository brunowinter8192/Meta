---
name: iterative-dev-duallog
description: 
---

# Dual-Log Reading — Skill

**The dual_log is the byte-level record of every CC session — read it ONLY through the CLI.**
Invocation: `cd /Users/brunowinter2000/Documents/ai/monitor-cc && ./venv/bin/python -m src.dual_log_cli <command>`. Never grep, cat, or Read the JSONL files directly: one `_original` line is a COMPLETE API request (up to 15 MB) that re-embeds the entire conversation history — a grep hit appears once per subsequent request, and a Read blows the context window.

**`sessions` first, then `timeline`.**
`sessions` lists every session newest-first: start time, context (`opus/<project>` or `worker/<name>`), stem, request count, message count, size on disk. `timeline <session>` takes the full stem or any unambiguous substring (`gh_cli_1787995963` works); an ambiguous substring errors with the candidate list.

**The timeline is the deduplicated conversation, not the raw log.**
It is reconstructed from the LAST conversation request of the session, with request boundaries interleaved as `── REQ N ──` markers. Each turn shows role, block types (`text` / `tool_use[Tool]` / `tool_result` / `thinking`), char sizes, and a 100-char preview per block. A `WARNING` header line means a `/clear` restart happened inside the log id — request markers before it do not align with the final message list.

**Drill into one turn with `--turn N --full`.**
The compact timeline previews only. For the complete content of one turn: `timeline <session> --turn N --full`. Piping through `head` is safe — the CLI exits silently on a closed pipe.

**Live sessions move under you.**
The proxy appends to open sessions while you read; every invocation re-reads the current end of the log. Identical counts across two invocations are not guaranteed for a running session.

## Commands

| Command | Args | Does |
|---|---|---|
| sessions | — | List all sessions with start, context, stem, requests, messages, size — newest first |
| timeline | session [--turn N] [--full] | Deduplicated turn timeline of one session; `--turn` restricts to one turn, `--full` prints that turn's complete block contents |
