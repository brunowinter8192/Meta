---
name: iterative-dev-duallog
description: 
---

# Dual-Log Reading — Skill

**The dual_log is the byte-level record of every CC session — read it ONLY through the CLI.**
Invocation: `duallog <command>` (in PATH; runs the monitor-cc main checkout).

## Commands

| Command | Args |
|---|---|
| sessions | [context] [--since YYYY-MM-DD] [--until YYYY-MM-DD] |
| msgs | session [from] [to] |
| expand | session msg [--before N] [--after N] [--only classifier] |
| search | term [scope] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--only classifier] [--case-sensitive] |

`--only` takes a role (`user`), a block type (`tool_result`), or a role/type pair (`user/text`) — a msg is selected when its role matches and ANY of its blocks matches the type, and a selected msg always shows ALL its blocks.

## Reading `msgs`

```
── REQ n  HH:MM:SS  CR c  CC c ──
        sys[i] chars  changed|new
        tool[Name] chars  changed|new
[N] role type chars  −S +I → Wc
        block-label chars  −S +I → Wc
```

- The separator carries the request's response usage: CR = `cache_read_input_tokens`, CC = `cache_creation_input_tokens`, joined from CC's transcript. A separator without CR/CC means the join did not resolve (errored request, live-session lag, or no transcript record). REQ numbers match the proxy pane's `#N`.
- Under the separator, the system blocks and tools the request sent on the wire: all of them on the family's first request, afterwards only those whose content `changed` or which are `new` against the previous request. No sys/tool line means the prefix did not change there. `sys[0]` is the per-request billing header and is listed on the first request only.
- Chars are the ORIGINAL payload's. A msg or block the proxy transformed carries a tail `−S +I → Wc`: chars stripped, chars injected, resulting wire size (what actually reached the API). ` by REQ n` is appended only when a later request than the group's own did the transform. An untouched line has no tail.

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
