# Session Pipeline — JSONL Analysis Snapshot

*Snapshot as of 2026-03 — historical process record; the live current state is the source code (`src/pipeline/`), not this file.*

## Architecture as of 2026-03

Utilities for analyzing Claude Code session JSONL logs. Used by the eval workflow (RAG plugin) and for debugging subagent behavior.

**jsonl_to_md.py (JSONL to Markdown):**
- Loads a JSONL session file, extracts the task prompt (first user message) and final response (last assistant text)
- Extracts all tool_use/tool_result pairs with timestamps
- Strips `<system-reminder>` tags from all content
- Outputs summary markdown: tool call table (one line per call with timestamp, tool name, params, output size or error marker)
- Error detection: `is_tool_error()` checks the `is_error` flag, `<tool_use_error>` tags, and "No such tool available" in tool_result content. Failed calls marked as `[✗ error text]` in the summary. An audit over 40364 tool_results (1442 sessions) confirmed: all hard errors have `is_error=True` — the string patterns are a redundant safety net. Evidence: `dev/session_pipeline/md/error_patterns_20260321_203616.md`
- Suspicious-output detection: MCP tool calls (name starts with `mcp__`) with output < 500 chars marked `[suspicious: N chars]` in the summary. Flags calls that returned "successfully" but with error content (404, "No content extracted", broken HTML). Built-in tools (Bash, Read, Grep) excluded — short output is normal for them. Not an error classification — a signal for the eval reviewer to extract and verify content. Evidence: `dev/session_pipeline/md/error_patterns_20260321_203616.md`
- Input truncation: `format_input_params()` truncates values to 100 chars, replaces newlines with spaces (single-line guarantee). File-content params (`content`, `file_content`, `new_string`, bash heredoc) show `[N chars]` instead of content.
- Optional `--dispatch` flag: traces back to the main session, extracts dispatch context (pre-dispatch messages, Agent tool_use prompt, post-dispatch response)
- Dispatch-context derivation: finds the `progress` message with matching agentId, walks backwards to find the Agent tool_use block

**list_agents.py (subagent listing):**
- Scans `~/.claude/projects/<escaped-path>/*/subagents/agent-*.jsonl`
- For each subagent: extracts agent_type from the main session (sync via progress anchor, async via tool_result text matching)
- Graceful per-agent error handling: agents with parse errors (RuntimeError, FileNotFoundError) are included as `UNKNOWN (parse error)` instead of crashing the entire listing
- Outputs an aligned table: agent_id, agent_type, timestamp, size
- `--session latest` filter for the most recent session only
- Imports from jsonl_to_md: `load_jsonl`, `derive_main_session`, `find_task_anchor`

**extract_calls.py (tool call extraction):**
- Extracts specific tool calls by number from a session JSONL
- `--list` mode: prints a summary table of all calls
- `--calls 1,3,7` mode: extracts full input/output for the selected calls
- Imports from jsonl_to_md: `load_jsonl`, `extract_tool_calls`, `format_tool_call`, `write_output`, `format_summary_table`

**Usage:**
- `python3 -m src.pipeline.jsonl_to_md --input <path> --output <path> [--dispatch]`
- `python3 -m src.pipeline.list_agents --project <path> [--session latest]`
- `python3 -m src.pipeline.extract_calls --input <path> --calls 1,3 [--output <path>]`

**MCP wrappers (server.py):**
- `eval_list_agents(project_path, session?)`: wraps `list_agents_workflow()` + `format_table()`. Returns formatted agent table + JSONL paths.
- `eval_extract(jsonl_path, calls?)`: without `calls` wraps `convert_workflow()` with dispatch=True (returns summary content directly). With `calls` wraps `extract_workflow()` (returns extracted tool calls).

**Cross-plugin:** jsonl_to_md is used by the RAG plugin's eval workflow for converting subagent sessions to readable markdown.

**Files:** `src/pipeline/jsonl_to_md.py`, `src/pipeline/list_agents.py`, `src/pipeline/extract_calls.py`

## Decisions at snapshot time

- `is_tool_error()`: keep (no change needed). Hard errors fully covered by the `is_error` flag. MCP soft errors handled via the suspicious marker + eval review — programmatic classification not feasible for content-based errors.
- `format_summary_table()`: keep the `[suspicious: N chars]` threshold at 500 chars. Consistent with the eval-agent skill (MCP Content Volume Check).
- `format_input_params()`: keep the content detection + newline sanitization.

## Open questions at snapshot time

- jsonl_to_md is the shared dependency — list_agents and extract_calls both import from it. A breaking change in jsonl_to_md affects both.
- The CC session JSONL format is undocumented — structure derived by reverse-engineering. Format changes in CC updates could break parsing.
