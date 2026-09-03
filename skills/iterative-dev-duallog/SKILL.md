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
| sessions | [context] [--since YYYY-MM-DD] [--until YYYY-MM-DD] | List sessions (start, context, stem), newest first; `context` is a case-insensitive substring filter (`websearch`, `worker/`, `opus/`); day flags inclusive, on session start; all filters AND — this and nothing else |
| msgs | session [from] [to] | Request-grouped msg listing: one `── REQ n  HH:MM:SS  CR c  CC c ──` separator per request (CR = `cache_read_input_tokens`, CC = `cache_creation_input_tokens` of that request's response, joined from CC's transcript; a separator without CR/CC means the join did not resolve — errored request, live-session lag, or no transcript record), below it one `[N] role type chars` line per msg that request added (a multi-block msg shows `N blocks`, followed by one indented sub-line per block with its own type/tool-name and chars); optional inclusive index range keeps a partial group's separator; REQ numbers match the proxy pane's `#N`; nothing else |
| expand | session msg [--before N] [--after N] [--only classifier] | Full content of the window around an anchor msg; before/after default 0, so a bare call prints exactly the anchor msg; `--only` narrows what is printed, never the examined window. A block the proxy transformed is followed by `── stripped by REQ n ──` / `── injected by REQ n ──` sections (REQ n = the request that PERFORMED the strip, matching `msgs`' numbering); an untouched block shows content only |
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

1. Scope and search in ONE command — project, day, and session are independent optional axes: "where was `<topic>` discussed, in `<project>`, on `<day>`" → `search "<term>" <project> --since <day> --until <day>`. Day-only, project-only, single-session, or fully unscoped all work.
2. `sessions [context] [--since] [--until]` when you first need the inventory itself rather than content.
3. Around a hit, `expand <session> <msg>` reads exactly that msg in full; widen with `--before N --after N [--only user/text]` to read the chain.

## Cache Reading

Compare CR of REQ n+1 against CR + CC of REQ n on the `msgs` separators. Equal or larger is incremental caching; smaller is a prefix break — then the `_forwarded` deltas of that request name the changed block. A CR that drops sharply while CC jumps (e.g. `CR 69,599  CC 414` → `CR 9,564  CC 63,159`) is a rebuild from the system/tools prefix onward.
