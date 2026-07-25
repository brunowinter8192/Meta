# dev/session_pipeline/

## Role

Scripts for auditing and evaluating the session pipeline (`src/pipeline/`). All commands assume CWD = project root (iterative-dev/).

## Modules

### audit_error_patterns.py

**Purpose:** Scans all Claude Code session JSONLs for error patterns in tool_result blocks. Produces evidence for `is_tool_error()` design decisions — separates hard errors (`is_error=True`) from soft errors (no flag but error content in first 500 chars).
**Usage:**
```bash
python3 dev/session_pipeline/audit_error_patterns.py
python3 dev/session_pipeline/audit_error_patterns.py path/to/specific.jsonl
```
**Output:** `dev/session_pipeline/md/error_patterns_<timestamp>.md`
