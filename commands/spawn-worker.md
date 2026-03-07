# Spawn Worker — Sonnet in Worktree via tmux

Spawn an interactive Claude Sonnet session in a git worktree, accessible via tmux.

Input: $ARGUMENTS
Format: `<worker-name> <task-description>`
Example: `/spawn-worker auth-module Implement JWT authentication in src/auth/`

---

## Step 1: Parse Arguments

Extract worker name (first word) and task description (rest) from $ARGUMENTS.
If no arguments provided, ask the user for worker name and task.

## Step 2: Create Worktree

```bash
git worktree add -b <worker-name> .claude/worktrees/<worker-name>
```

Verify the worktree was created. If the branch already exists, STOP and inform the user.

## Step 3: Write Task Prompt

Write the task description to a temp file to avoid shell escaping issues:

```bash
cat > /tmp/spawn-worker-prompt.txt << 'PROMPT_EOF'
<task-description goes here>
PROMPT_EOF
```

The task prompt MUST include:
- The specific task from the user's arguments
- Reference to the plan file if one exists: "Read .claude/plans/*.md for full context"
- Instruction: "You are working in a git worktree. Commit your changes to this branch when done."

## Step 4: Spawn tmux Window

```bash
# Create session if needed (idempotent)
tmux new-session -d -s workers 2>/dev/null || true

# Create window with claude sonnet
TASK_PROMPT=$(cat /tmp/spawn-worker-prompt.txt)
tmux new-window -t workers -n <worker-name> \
  "cd $(pwd)/.claude/worktrees/<worker-name> && claude --model sonnet --append-system-prompt \"$TASK_PROMPT\""
```

## Step 5: Confirm

Report to user:
- Worker name and branch
- Worktree path
- tmux attach command: `tmux attach -t workers`
- List all current workers: `tmux list-windows -t workers`

## Step 6: Cleanup Instructions

When the user says a worker is done and wants to merge:

```bash
# Review what the worker committed
git log master..<worker-name> --oneline

# Merge into current branch
git merge <worker-name>

# Cleanup
tmux kill-window -t workers:<worker-name> 2>/dev/null
git worktree remove .claude/worktrees/<worker-name>
git branch -d <worker-name>
```
