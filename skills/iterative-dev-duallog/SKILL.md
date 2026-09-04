---
name: iterative-dev-duallog
description: 
---

# Dual-Log Reading — Skill

## Commands

| Command | Args | Does |
|---|---|---|
| sessions | [context] [--since YYYY-MM-DD] [--until YYYY-MM-DD] | List sessions, newest first; context filters by project/worker substring |
| msgs | session [from] [to] \| --req F [T] | One classifier line per msg, grouped by request |
| expand | session msg [--before N] [--after N] [--only classifier] | Full content of one msg and the window around it |
| search | term [scope] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--only classifier] [--case-sensitive] | Find a term across sessions, each hit once; scope matches context or session name |
| reqs | [scope] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--main \| --worker] [--gap MINUTES] [--merged] [--rebuild] [--drop] | One REQ number + time per line, per session; scope matches context or session name; --main/--worker keep only opus/ or worker/ sessions; --gap shows only the REQs bracketing a consecutive gap of at least MINUTES (after-REQ carries `+Nm`; no qualifying gap prints only the session line); --merged combines every session in scope into one chronological REQ chain (each line tagged by worker/project) instead of one listing per session — the prompt cache is shared across a project's workers, so --gap on a merged chain evaluates the gap that actually matters for cache health; --rebuild keeps only REQs where CC > CR, --drop keeps only REQs whose predecessor's cached prefix was not fully read back (CR(n) < CR(n-1)+CC(n-1), REQ 1 of a chain never qualifies) — both carry a `CR c  CC c` tail (--drop also a `−N` shortfall), combine with each other (AND), with --gap (filtering the lines --gap would print), and with --merged (predecessor is then the merged chain's, across sessions) |

`--only` (expand, search) takes a role (`user`), a block type (`tool_result`), or a role/type pair (`user/text`); a msg is selected when its role matches and ANY block matches the type, and it always shows ALL its blocks.

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
