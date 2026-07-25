#!/usr/bin/env python3
# test_capture_clean.py — fixture-based smoke for src/spawn/_capture_clean.py
# Usage: python3 dev/spawn/test_capture_clean.py  (from project root)

# INFRASTRUCTURE
import os
import subprocess
import sys
import tempfile

SCRIPT = os.path.join(os.path.dirname(__file__), '../../src/spawn/_capture_clean.py')

# Hand-built fixture covering every filter case.
# Lines present:
#   boot welcome box (╭…╰), thinking spinner (✻), Read tool + ctrl+o sub-line,
#   Update() header + diff body (+/-) + Added counter, Bash() tool header + output,
#   Update() header with ... collapse + post-collapse body + wrap continuation,
#   worker prose + checklist, collapse ellipsis, rule, bare ❯, Sonnet footer, bypass
FIXTURE = (
    '╭──────────────── Claude Code ─────────────────╮\n'
    '│  ✻ API key configured                        │\n'
    '│  Ready.                                      │\n'
    '╰──────────────────────────────────────────────╯\n'
    '\n'
    '❯ worker send pollfix "fix the tail regex and add tests"\n'
    '\n'
    '✻ Thinking… (Crunched 12 seconds)\n'
    '\n'
    '⏺ Read(src/hooks/block_polling_loop.py)\n'
    "  ⎿ Read 133 lines (ctrl+o to expand)\n"
    '\n'
    '⏺ Update(src/hooks/block_polling_loop.py)\n'
    '  ⎿  Added 3 lines, removed 1 line\n'
    '      13\n'
    "      16 -_TAIL_N_FILE = re.compile(r'\\btail\\s+-\\d+\\s+(\\S+)')\n"
    "      16 +_TAIL_N_FILE = re.compile(r'\\btail\\s+-\\d+[^\\S\\n]+(\\S+)')\n"
    '\n'
    '⏺ Update(src/spawn/DOCS.md)\n'
    '  ⎿  Added 2 lines, removed 1 line\n'
    '      14\n'
    '     ...\n'
    '      22  **Called by:** after-collapse-leak\n'
    '      22 +post-collapse-plus\n'
    '\n'
    '⏺ Bash(python3 dev/hook_smoke/test_block_polling_loop.py > /tmp/out.md 2>&1)\n'
    'All 20 tests passed.\n'
    '\n'
    'This is the implementation report.\n'
    '\n'
    'COMPLETION CHECKLIST:\n'
    '- [x] Fix implemented\n'
    '\n'
    '… +5 lines (ctrl+o to expand)\n'
    '\n'
    '────────────────────────────────────────────────\n'
    '❯\n'
    'Sonnet | 45%\n'
    '⏵⏵ bypass permissions enabled\n'
)


# ORCHESTRATOR

def test_capture_clean_workflow():
    output = _run_script(FIXTURE, 'testworker')
    failures = _assert_cases(output)
    print()
    if failures:
        print(f'FAILED: {len(failures)} assertion(s):')
        for f in failures:
            print(f'  {f}')
        sys.exit(1)
    print('All assertions passed.')


# FUNCTIONS

# Write fixture to temp file, run _capture_clean.py, return stdout.
def _run_script(fixture_text, worker_name):
    fd, pane_file = tempfile.mkstemp(suffix='.txt')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(fixture_text)
        result = subprocess.run(
            ['python3', SCRIPT, pane_file, worker_name],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f'script exited {result.returncode}:\n{result.stderr}')
            sys.exit(1)
        return result.stdout
    finally:
        if os.path.exists(pane_file):
            os.unlink(pane_file)


# Run all assertions; return list of failure strings (empty = all pass).
def _assert_cases(output):
    failures = []

    def check(label, cond, detail=''):
        if not cond:
            failures.append(f'{label}{": " + detail if detail else ""}')

    # Header present
    check('header present', '=== capture from testworker (since last prompt,' in output)

    # No fallback warning — prompt marker must have been found
    check('no fallback warning', '⚠' not in output)

    # Body not empty (chars > 0 in header + content lines after header)
    body = '\n'.join(output.split('\n')[1:]).strip()
    check('body not empty', bool(body))

    # --- STRIP cases: must NOT appear in output ---
    must_not = [
        ('boot box top',       '╭──────────────── Claude Code'),
        ('boot box interior',  'Ready.'),
        ('thinking spinner',   'Crunched 12 seconds'),
        ('Read sub-line',      'Read 133 lines'),
        ('diff body context',   '      13'),
        ('diff body minus',    '      16 -_TAIL_N_FILE'),
        ('diff body plus',     '      16 +_TAIL_N_FILE'),
        ('diff collapse line',  '     ...'),
        ('post-collapse body',  'after-collapse-leak'),
        ('post-collapse plus',  'post-collapse-plus'),
        ('collapse ctrl+o',    'ctrl+o to expand'),
        ('collapse ellipsis',  '… +5 lines'),
        ('rule line',          '────────────────────────────────────────────────'),
        ('sonnet footer',      'Sonnet | 45%'),
        ('bypass line',        'bypass permissions enabled'),
        ('prompt echo',        'fix the tail regex and add tests'),
    ]
    for label, text in must_not:
        check(f'STRIPPED: {label}', text not in output, repr(text))

    # --- KEEP cases: must appear in output ---
    must_have = [
        ('Update header 1',                'Update(src/hooks/block_polling_loop.py)'),
        ('Update header 2 (with collapse)', 'Update(src/spawn/DOCS.md)'),
        ('Added counter (glyph stripped)',  'Added 3 lines, removed 1 line'),
        ('Read tool header',               'Read(src/hooks/block_polling_loop.py)'),
        ('Bash tool header',               'Bash(python3 dev/hook_smoke'),
        ('Bash output',                    'All 20 tests passed.'),
        ('worker prose',                   'This is the implementation report.'),
        ('checklist header',               'COMPLETION CHECKLIST:'),
        ('checklist item',                 '- [x] Fix implemented'),
    ]
    for label, text in must_have:
        check(f'KEPT: {label}', text in output, repr(text))

    return failures


if __name__ == '__main__':
    test_capture_clean_workflow()
