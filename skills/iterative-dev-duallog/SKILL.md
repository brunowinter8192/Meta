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
| timeline | session | Deduplicated turn timeline of one session |
| expand | session turn [--before N] [--after N] | Classifier lines (index, role, type, chars) around an anchor turn; before/after default 30 with a HARD FLOOR of 30 — only larger allowed, never filtered |
| expand --full | session turn --full --before N --after N [--only classifier] | Full content of the window; both bounds required, no floor (0 works); `--only` filters by role or message type, e.g. tool_result |
| search | term [scope] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--case-sensitive] | Find a term across the deduplicated timelines — `scope` matches context OR stem (project, worker, or single session); every filter optional and AND-combined; searches full block content including tool_use JSON inputs; one hit per (turn, block) with `×N` count; case-insensitive by default |

## Classifiers

What each turn classifier means — the basis for deciding what to expand:

| Classifier | What it is |
|---|---|
| user / text | A genuine human message — the steering signal. Expand these to follow intent, criticism, and decisions |
| assistant / text | The agent's visible reply. A ~9-char one is the literal placeholder `undefined` — the turn's real content was thinking or tool calls |
| assistant / thinking | Internal reasoning. `0 chars` plus signature means the text was withheld; large ones carry the agent's actual deliberation |
| assistant / tool_use | A tool invocation: tool name plus input JSON — the executed command lives here |
| user / tool_result | The tool's output, returned under the user role; `tool_result!err` marks errors |
| system / system | Runtime injections: 49-char ones are `total_tokens` counters (noise), large ones are deferred-tool or agent lists |
| user / system-reminder | CC-injected context wrapped as a user turn (CLAUDE.md contents, env context) |
| user / task-notification | Background-task wake-up (task id, output path, status) — automated, never real user input |

The story of a session lives in user/text, assistant/text and thinking; the mechanics live in tool_use and tool_result; total_tokens system turns are skippable.

## Search Strategy

1. Scope and search in ONE command — project, day, and session are independent optional axes: "where was the Reißleine story, websearch, yesterday" → `search "Reißleine" websearch --since 2026-08-28 --until 2026-08-28`. Day-only, project-only, single-session, or fully unscoped all work.
2. `sessions [context] [--since] [--until]` when you first need the inventory itself rather than content.
3. Around a hit, `expand <session> <turn>` for the classifier overview, then `expand <session> <turn> --full --before N --after N [--only tool_result]` to read the chain; `--full --before 0 --after 0` reads exactly one turn.
