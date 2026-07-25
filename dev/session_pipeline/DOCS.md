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
**Output:** `dev/session_pipeline/md/error_patterns_<timestamp>.md` (script writes to `reports/` relative to itself — see Gotchas)

## Gotchas

- `audit_error_patterns.py:25` has `REPORTS_DIR = Path(__file__).parent / 'reports'` — the on-disk report folder was renamed to `md/` per the dev-report convention; the script constant still says `reports/`, so the NEXT run will recreate a `reports/` folder. Fix the constant to `'md'` on next touch (source edit — worker task).
