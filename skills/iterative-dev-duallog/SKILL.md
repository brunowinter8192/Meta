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
| timeline | session | Deduplicated msg timeline of one session |
| expand | session msg [--before N] [--after N] [--only classifier] | Classifier rows (msg index, time, role, type-or-block-count, chars) around an anchor msg; a multi-block msg lists its blocks as indented sub-rows; before/after default 30 with a HARD FLOOR of 30 — only larger allowed; `--only` narrows what is printed, never the examined window |
| expand --full | session msg --full --before N --after N [--only classifier] | Full content of the window; both bounds required, no floor (0 works) |
| search | term [scope] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--only classifier] [--case-sensitive] | Find a term across the deduplicated timelines — `scope` matches context OR stem (project, worker, or single session); every filter optional and AND-combined; searches full block content including tool_use JSON inputs; one hit per (turn, block) with `×N` count; case-insensitive by default |

`--only` takes a role (`user`), a block type (`tool_result`), or a role/type pair (`user/text`) — a msg is selected when its role matches and ANY of its blocks matches the type, and a selected msg always shows ALL its blocks. The pair `user/text` isolates what the human actually typed.

## Classifiers

A msg is one entry of the API messages array: a role plus a list of typed blocks. Block types:

| Block type | What it is |
|---|---|
| text | Visible prose — the human's typed message under role user, the agent's reply under role assistant |
| thinking | The agent's internal reasoning |
| tool_use | A tool invocation: tool name plus input JSON — the executed command lives here |
| tool_result | The tool's output, returned under role user; `tool_result!err` marks errors |
| image | An embedded image |
| system | Runtime-injected block, e.g. token counters or deferred-tool lists |
| system-reminder | CC-injected context wrapped as a user msg (CLAUDE.md contents, env context) |
| task-notification | Background-task wake-up (task id, output path, status) — automated, never real user input |

The story of a session lives in user/text, assistant/text and thinking; the mechanics live in tool_use and tool_result.

## Search Strategy

1. Scope and search in ONE command — project, day, and session are independent optional axes: "where was the Reißleine story, websearch, yesterday" → `search "Reißleine" websearch --since 2026-08-28 --until 2026-08-28`. Day-only, project-only, single-session, or fully unscoped all work.
2. `sessions [context] [--since] [--until]` when you first need the inventory itself rather than content.
3. Around a hit, `expand <session> <msg>` for the classifier overview, then `expand <session> <msg> --full --before N --after N [--only user/text]` to read the chain; `--full --before 0 --after 0` reads exactly one msg.
