---
name: agent-code-investigate
description: Tool reference and usage guidelines for the code-investigate-specialist agent
---

# Code Investigation — Tool Reference

## Tool Usage Guidelines (Safe Exploration)

**CRITICAL:** Prevent context pollution from large directories and data files.

### Rules

1. **NEVER** use `find` without `-maxdepth` on unknown directories
2. **NEVER** use `ls -R` unless you know file count is <50
3. **ALWAYS** start with `find . -maxdepth 2` to understand structure
4. **ALWAYS** filter for code files: `-name "*.py"` or exclude data: `-not -path "*/data/*"`
5. **IF** output is truncated or huge → immediately switch to more specific query

### Tool Selection Guide

| Scenario | Tool | Why |
|----------|------|-----|
| Find files by name/pattern | `Glob` | Fast pattern matching, no shell needed |
| Search content across files | `Grep` | Regex support, file filtering |
| Read known file | `Read` | Direct access, line numbers included |
| Directory overview | `Bash(find)` | Depth control, type filtering |
| Count files/lines | `Bash(wc)` | Quick metrics before deeper dive |
| Parse JSON/JSONL | `Bash(jq)` or `Bash(python3)` | Structured data needs structured tools |
| Parse CSV | `Bash(python3)` or `Bash(awk)` | Never grep CSV fields |
| Check file vs directory | `Bash(ls -F)` | Directories end with `/` |

### Glob vs Grep vs Bash

**Use Glob when:**
- Finding files by name pattern (`**/*.py`, `**/config*`)
- Listing files in a directory tree
- No content search needed

**Use Grep when:**
- Searching for content inside files
- Regex pattern matching
- Need file paths + line numbers + context

**Use Bash when:**
- Need `find` with `-maxdepth`, `-type`, `-not -path`
- Need `wc -l` for counting
- Need `head -n 5` for sampling
- Need `jq` or `python3` for structured data
- Need to combine multiple operations

## Directory Guard

Before using Read tool, verify target is FILE not directory.

1. **If unsure:** Run `ls -F <path>` first (directories end with `/`)
2. **If EISDIR error:** Immediately switch to `ls` or `find`
3. **NEVER** assume a path is a file - verify first

## Data Inspection Rules

When searching values in data files (CSVs, logs, JSON):

1. **COUNT first** - Use `wc -l` or `head -n 5` before printing full results
2. **NO temp files** - Do NOT use the Write tool. Do not create scratchpad/plan files for read-only tasks. Investigation tasks are always read-only.
3. **Sample before full scan** - Check 1 file before looping all
4. **Structured data = structured tools:**
   - CSV → `python3 -c "import csv..."` or `awk`
   - JSON/JSONL → `jq` or `python3 -c "import json..."`
   - NEVER grep for field values in structured data

### CSV Best Practices

```bash
# BAD: grep "-" file.csv (matches hyphens everywhere)
# GOOD: awk -F',' '$3 < 0' file.csv (numeric comparison on correct column)

# BAD: cut + sort + uniq pipeline (fragile with special chars)
# GOOD: python3 -c "import pandas as pd; print(pd.read_csv('file.csv')['col'].value_counts())"
```

### JSON/JSONL Best Practices

```bash
# BAD: grep '"status": "error"' data.jsonl
# GOOD: jq 'select(.status == "error")' data.jsonl
# GOOD: python3 -c "import json; [print(l) for l in open('data.jsonl') if json.loads(l).get('status')=='error']"
```

## Read Tool Best Practices

- Use `offset` and `limit` for large files (>500 lines)
- Read frontmatter/header first to understand structure
- When reading config files: read ENTIRE file (usually short)
- When reading source code: start with imports + class/function signatures

## Performance Tips

- **Batch parallel reads:** When you need to read 3+ related files, call Read on all of them in a single response
- **Grep before Read:** Use Grep with context (`-C 5`) first. Only Read full file if context is insufficient
- **Stop early:** If you found the answer in 2 reads, don't keep searching "just in case"
- **Depth-first:** Follow one promising lead to conclusion before starting another search branch
