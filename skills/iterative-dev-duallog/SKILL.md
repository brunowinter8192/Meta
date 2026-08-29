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
| search | term [scope] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--case-sensitive] | Find a term across the deduplicated timelines — `scope` matches context OR stem (project, worker, or single session); every filter optional and AND-combined; searches full block content including tool_use JSON inputs; one hit per (turn, block) with `×N` count; case-insensitive by default |

## Search Strategy

1. Scope and search in ONE command — project, day, and session are independent optional axes: "where was the Reißleine story, websearch, yesterday" → `search "Reißleine" websearch --since 2026-08-28 --until 2026-08-28`. Day-only, project-only, single-session, or fully unscoped all work.
2. `sessions [context] [--since] [--until]` when you first need the inventory itself rather than content.
3. Read a hit completely with `timeline <session> --turn N --full`.
