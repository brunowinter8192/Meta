---
name: iterative-dev-duallog
description: 
---

# Dual-Log Reading — Skill

**The dual_log is the byte-level record of every CC session — read it ONLY through the CLI.**
Invocation: `duallog <command>` (in PATH; runs the monitor-cc main checkout).

## Commands

| Command | Args | Does |
|---|---|---|
| sessions | [context] [--since YYYY-MM-DD] [--until YYYY-MM-DD] | List sessions (start, context, stem), newest first; `context` is a case-insensitive substring filter (`websearch`, `worker/`, `opus/`); day flags inclusive, on session start; all filters AND |
| timeline | session [--turn N] [--full] | Deduplicated turn timeline of one session; `--turn` restricts to one turn, `--full` prints that turn's complete block contents |
| search | session term [--case-sensitive] | Find a term in one session's deduplicated timeline — searches full block content including tool_use JSON inputs; one hit per (turn, block) with `×N` occurrence count; case-insensitive by default |

## Search Strategy

1. Scope with `sessions` — narrow by project term and day: "everything websearch from 2026-08-28" → `sessions websearch --since 2026-08-28 --until 2026-08-28`. One project term catches main AND worker sessions.
2. `search <session> <term>` across the few candidates to locate content, then `timeline <session> --turn N --full` to read a hit's complete turn. `<session>` is the full stem or any unambiguous substring; an ambiguous one errors with the candidate list.
