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
| sessions | — | List all sessions with start, context, stem, requests, messages, size — newest first |
| timeline | session [--turn N] [--full] | Deduplicated turn timeline of one session; `--turn` restricts to one turn, `--full` prints that turn's complete block contents |
| search | session term [--case-sensitive] | Find a term in one session's deduplicated timeline — searches full block content including tool_use JSON inputs; one hit per (turn, block) with `×N` occurrence count; case-insensitive by default |

## Search Strategy

1. `sessions` for the inventory — every session newest-first with start time, context (`opus/<project>` or `worker/<name>`), stem, request count, message count, size. Pick the target here.
2. `timeline <session>` for the shape — turns, request markers, block sizes, previews. `<session>` is the full stem or any unambiguous substring (`gh_cli_1787995963` works); an ambiguous one errors with the candidate list.
3. `search <session> <term>` to locate content, then `timeline <session> --turn N --full` to read a hit's complete turn.
