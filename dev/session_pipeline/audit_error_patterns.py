#!/usr/bin/env python3
"""Audit error patterns in Claude Code session JSONLs.

Scans all session JSONLs to find tool_result blocks that indicate errors.
Separates hard errors (is_error=True) from soft errors (no flag but error content).
Produces MD report with pattern counts and examples.

Usage:
    python3 dev/pipeline/audit_error_patterns.py
    python3 dev/pipeline/audit_error_patterns.py path/to/specific.jsonl

Default: all JSONLs under ~/.claude/projects/
Output: dev/pipeline/reports/error_patterns_<timestamp>.md
"""

# INFRASTRUCTURE
import json
import logging
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

PROJECTS_DIR = Path.home() / '.claude' / 'projects'
REPORTS_DIR = Path(__file__).parent / 'reports'

SOFT_ERROR_INDICATORS = [
    'Traceback (most recent call last)',
    'ModuleNotFoundError:',
    'FileNotFoundError:',
    'ImportError:',
    'SyntaxError:',
    'PermissionError:',
    'ConnectionError:',
    'TimeoutError:',
    'OSError:',
    'RuntimeError:',
    'CalledProcessError',
    'Error: result exceeds',
    'Connection closed',
    'ENOENT',
    'EACCES',
    'Command failed',
]

logging.basicConfig(level=logging.INFO, format='%(message)s')
log = logging.getLogger(__name__)


# ORCHESTRATOR
def audit_workflow(jsonl_paths: list[Path]) -> None:
    hard_errors, soft_errors, stats = scan_all_jsonls(jsonl_paths)
    report = format_report(hard_errors, soft_errors, stats)
    report_path = write_report(report)
    log.info(f"Report: {report_path}")
    log.info(f"Files scanned: {stats['files_scanned']}, tool_results: {stats['total_tool_results']}")
    log.info(f"Hard errors: {stats['hard_error_count']}, Soft errors: {stats['soft_error_count']}")


# FUNCTIONS

# Collect all JSONL files from projects directory
def collect_jsonl_paths() -> list[Path]:
    return sorted(PROJECTS_DIR.rglob('*.jsonl'))


# Scan all JSONLs and collect error patterns
def scan_all_jsonls(jsonl_paths: list[Path]) -> tuple[dict, dict, dict]:
    hard_errors = defaultdict(lambda: {'count': 0, 'example': ''})
    soft_errors = defaultdict(lambda: {'count': 0, 'example': '', 'files': set()})
    stats = {'files_scanned': 0, 'total_tool_results': 0, 'hard_error_count': 0, 'soft_error_count': 0}

    for path in jsonl_paths:
        scan_single_jsonl(path, hard_errors, soft_errors, stats)

    return hard_errors, soft_errors, stats


# Scan a single JSONL file for error patterns
def scan_single_jsonl(path: Path, hard_errors: dict, soft_errors: dict, stats: dict) -> None:
    stats['files_scanned'] += 1
    try:
        with open(path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                process_message(msg, path, hard_errors, soft_errors, stats)
    except (OSError, UnicodeDecodeError):
        pass


# Process a single JSONL message for tool_result blocks
def process_message(msg: dict, path: Path, hard_errors: dict, soft_errors: dict, stats: dict) -> None:
    if 'message' not in msg or not isinstance(msg.get('message'), dict):
        return
    content = msg['message'].get('content', [])
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict) or block.get('type') != 'tool_result':
            continue
        stats['total_tool_results'] += 1
        text = extract_tool_result_text(block)
        classify_error(block, text, path, hard_errors, soft_errors, stats)


# Extract text content from a tool_result block
def extract_tool_result_text(block: dict) -> str:
    content = block.get('content', '')
    if isinstance(content, list) and len(content) > 0:
        first = content[0]
        return first.get('text', '') if isinstance(first, dict) else str(first)
    return str(content)


# Classify a tool_result as hard error, soft error, or success
def classify_error(block: dict, text: str, path: Path, hard_errors: dict, soft_errors: dict, stats: dict) -> None:
    if block.get('is_error'):
        stats['hard_error_count'] += 1
        pattern = extract_hard_error_pattern(text)
        hard_errors[pattern]['count'] += 1
        if not hard_errors[pattern]['example']:
            hard_errors[pattern]['example'] = text[:200]
        return

    snippet = text[:500]
    for indicator in SOFT_ERROR_INDICATORS:
        if indicator in snippet:
            stats['soft_error_count'] += 1
            soft_errors[indicator]['count'] += 1
            soft_errors[indicator]['files'].add(str(path.name))
            if not soft_errors[indicator]['example']:
                soft_errors[indicator]['example'] = text[:200]
            break


# Extract pattern category from hard error text
def extract_hard_error_pattern(text: str) -> str:
    if '<tool_use_error>' in text:
        if 'No such tool available' in text:
            return 'No such tool available'
        if 'not allowed' in text.lower():
            return 'Tool not allowed'
        return 'tool_use_error (other)'
    if 'is_error flag only' in text or not text.strip():
        return 'is_error flag (no text)'
    return text[:80].replace('\n', ' ')


# Format the audit report as markdown
def format_report(hard_errors: dict, soft_errors: dict, stats: dict) -> str:
    lines = [
        '# Error Pattern Audit',
        '',
        f'**Date:** {datetime.now().strftime("%Y-%m-%d %H:%M")}',
        f'**Files scanned:** {stats["files_scanned"]}',
        f'**Total tool_results:** {stats["total_tool_results"]}',
        f'**Hard errors (is_error=True):** {stats["hard_error_count"]}',
        f'**Soft errors (no is_error flag):** {stats["soft_error_count"]}',
        '',
        '## Hard Errors',
        '',
        '| Pattern | Count | Example |',
        '|---------|-------|---------|',
    ]

    for pattern, data in sorted(hard_errors.items(), key=lambda x: -x[1]['count']):
        example = data['example'].replace('\n', ' ')[:80]
        lines.append(f'| {pattern} | {data["count"]} | {example} |')

    lines.extend([
        '',
        '## Soft Errors (Candidates for is_tool_error)',
        '',
        'These tool_results have NO is_error flag but contain error indicators in the first 500 chars.',
        '',
        '| Indicator | Count | Files | Example |',
        '|-----------|-------|-------|---------|',
    ])

    for indicator, data in sorted(soft_errors.items(), key=lambda x: -x[1]['count']):
        example = data['example'].replace('\n', ' ')[:80]
        file_count = len(data['files'])
        lines.append(f'| `{indicator}` | {data["count"]} | {file_count} files | {example} |')

    if not soft_errors:
        lines.append('| (none found) | 0 | 0 | — |')

    lines.extend([
        '',
        '## Recommendation',
        '',
    ])

    if soft_errors:
        lines.append('Soft error patterns found. Evaluate each for inclusion in `is_tool_error()`:')
        lines.append('')
        for indicator, data in sorted(soft_errors.items(), key=lambda x: -x[1]['count']):
            lines.append(f'- `{indicator}`: {data["count"]}x across {len(data["files"])} files')
    else:
        lines.append('No soft error patterns found. `is_tool_error()` covers all observed errors via `is_error` flag. No change needed.')

    return '\n'.join(lines)


# Write report to file
def write_report(report: str) -> Path:
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    report_path = REPORTS_DIR / f'error_patterns_{timestamp}.md'
    report_path.write_text(report, encoding='utf-8')
    return report_path


if __name__ == '__main__':
    if len(sys.argv) > 1:
        paths = [Path(p) for p in sys.argv[1:]]
    else:
        paths = collect_jsonl_paths()
        log.info(f"Scanning {len(paths)} JSONL files...")
    audit_workflow(paths)
