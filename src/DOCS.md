# src/

Source modules for the iterative-dev plugin infrastructure.

## Documentation Tree

- [spawn/DOCS.md](spawn/DOCS.md) — Worker spawning (tmux_spawn.sh + spawn.py)
- [git/DOCS.md](git/DOCS.md) — Git automation utilities (pre-commit, commit, staging, post-commit)
- [pipeline/DOCS.md](pipeline/DOCS.md) — Session JSONL analysis (conversion, listing, extraction)

## Directory Map

| Subdir | Role | LOC | Modules |
|---|---|---:|---:|
| spawn/ | Worker spawning and orchestration | 1055 | 3 (tmux_spawn.sh, _capture_clean.py, spawn.py) |
| git/ | Git automation utilities | 439 | 4 (check.py, commit.py, staged.py, post.py) |
| pipeline/ | Session JSONL analysis | 682 | 3 (jsonl_to_md.py, list_agents.py, extract_calls.py) |
