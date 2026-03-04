---
name: iterative-dev
description: (project)
---

# Iterative Development Skill

## Task Management Hierarchy

- **Beads** (`.beads/`) - Cross-session (days/weeks/months). Rules and formats in `~/.claude/CLAUDE.md`
- **Plan-File** (`.claude/plans/`) - Within a session (hours)
- **TodoWrite** - Within an iteration (minutes)

### Beads (MANDATORY)

Rules, types, and content requirements: `~/.claude/CLAUDE.md`

Beads are **always active** — not tied to specific phases. After every significant action (file changed, decision made, bug found, scope change), comment the relevant bead immediately. Don't batch comments for phase transitions.

**MANDATORY: After every `git commit`, immediately `bd comments add <bead-id>` with what was changed and why.** A commit without a bead comment = lost context. This is the minimum granularity — no exceptions.

**Session start:** `bd list -s open` → read relevant work beads. No bead for current work → create one before starting.

## CRITICAL CYCLE

```
PLAN (Plan Mode) -> IMPLEMENT -> RECAP -> IMPROVE -> CLOSING -> PLAN (new cycle)
```

EVERY RESPONSE STARTS WITH A PHASE INDICATOR:
- `📋 PLAN` - Planning phase (Plan Mode active)
- `🔨 IMPLEMENT` - Implementation phase
- `🔍 RECAP` - Report phase (Plan Mode active - read-only enforced)
- `🛠️ IMPROVE` - Improvements phase
- `✅ CLOSING` - Cycle completion

**Plan Mode Usage:**
- PLAN: Native Plan Mode for implementation planning
- RECAP: Plan Mode for read-only protection (prevents accidental edits)

**Phase Detection:** System message contains "Plan mode is active" → Check context to determine if PLAN or RECAP.

---

## Planning Phase (PLAN)

### Beads Check (BEFORE Exploration)

**MANDATORY:** Run `bd list -s open` BEFORE launching any exploration agents.

Beads provide cross-session context. Agent exploration without bead context = wasted effort.

**Note:** Always use `-s open` by default. Show closed beads only when user explicitly asks.

### Scoping (BEFORE Exploration)

BEFORE you explore, clarify with the user:

**1. SCOPE - What is the end goal?**
→ "What should the output be?"
→ File? Script? Documentation? Analysis?
→ **If Documentation:** "Who is the target reader?"
  - **Default assumption:** AI (you) is the primary reader
  - Docs should be perfect for AI consumption, but human-readable when needed
  - Optimize for: clarity, structure, completeness (AI needs full context)

**2. SOURCES - Which files/folders are relevant?**
→ "Which folders should I look at?"
→ "Is there a reference script?"
→ User knows the structure better than you

**3. CONNECTIONS - How do the sources relate?**
→ "How does X use data from Y?"
→ Only when connections are clear: read DOCS.md

**4. REFERENCES - Is there an existing pattern to follow?**
→ "Is there an existing pattern in your other projects we should follow?"
→ Especially for testing, debug, infrastructure tasks
→ User's existing patterns beat generic best practices (e.g., scraping suite > unit tests for web scrapers)

**Question Pacing:**
- Structure questions by topic steps, not as a single dump
- 5 questions in one round is fine IF they are thematically coherent
- Consider whether an answer to question N makes question N+1 obsolete — if so, ask sequentially
- Do NOT ask one question per round when they are independent — that wastes exchanges
- Do NOT overload the user with unrelated questions in a single block

**EXCEPTION — Concrete Usecase First:**
When user describes a concrete usecase ("verify these numbers", "run this workflow"), execute the usecase FIRST before asking scope questions. The concrete experience reveals the actual scope better than abstract discussion. AskUserQuestion only AFTER the usecase exposed gaps or decision points.

**Targeted vs Exploratory:**
- When user provides specific claims/data to verify → **targeted search**
  - Ask user for concrete path/directory BEFORE exploring
  - User has the mapping context (section name → directory)
  - Check bead descriptions for path hints
- When user asks to explore/discover → **exploratory search**
  - Navigate freely, no need to ask for paths upfront

**THEN:** Explore with direction (DOCS.md → relevant scripts → structures)

### Exploration

**Documentation First (MANDATORY):**

BEFORE any action in a directory (running scripts, editing files, exploring code):
1. STOP
2. READ the DOCS.md in that directory
3. ONLY THEN proceed

This is NON-NEGOTIABLE. Skipping DOCS.md leads to: wrong paths, wrong arguments, wrong understanding.

**"Exploring code" includes:**
- Grep/Search in that directory
- Reading scripts
- Running scripts
- Editing files

**Bug Investigation Pattern:**
1. User reports bug (e.g., "threshold should be >150")
2. **WRONG:** Grep for "150" or "threshold" immediately
3. **RIGHT:** Read DOCS.md first → shows which script handles threshold → read THAT script

**Why DOCS first for bugs:**
- DOCS shows the workflow and which script does what
- DOCS shows the default values and parameters
- Grep without context = searching blind
- DOCS → targeted read = efficient investigation

**SOURCE CODE VERIFICATION (Bugs & Code Changes):**

When fixing bugs or making code changes involving system behavior (terminal escape codes, protocols, APIs):
1. **ASK:** "Is there a reference implementation I should check?"
2. **CHECK:** Look in local repos (e.g., `repo/` folder) for authoritative source code
3. **VERIFY:** Before implementing, confirm behavior against reference

**ASK THE FUCKING USER**
- the user knows best, ask him for reference scripts,
	- REFERENCE SCRIPTS OR SOURCE CODE IS A GAME CHANGER, MAKES LIFE MUCH EASIER
- ask him for things which are critical to understand in order to be able to make a Plan file
	- USER HAS A BROAD KNOWLEDGE, TAKE ADVANTAGE OF IT
- **External Dependencies/Versions:** ASK USER, don't self-verify
	- Docker images, tool versions, library versions
	- User knows what was ACTUALLY USED vs what's CURRENTLY AVAILABLE
	- Reproducibility > Recency

### Communication

| Channel | Purpose |
|---------|---------|
| Chat | Brainstorming, asking questions |
| Plan file | Key points and implementation steps |

**Proactivity (CRITICAL):**
- On skill start: Ask context questions IMMEDIATELY, don't wait
- Clarify SCOPE, SOURCES, CONNECTIONS first
- THEN explore with clear direction

**Questions:**
- One question at a time, based on previous answer, prefer multiple choice, 'askuserquestion' tool
- Questions building up on each other, one leads to another

**Plan-File:**
- Use system-provided plan file path from Plan Mode message
- ALWAYS use Write/Edit tool to update plan file
- NEVER write plan content directly in chat

### Plan File Management

**Core Principle:** Build the plan ITERATIVELY.

- **CRITICAL:**
- After each chat exchange: UPDATE the plan file
- Never write the complete plan at once
- Plan grows organically through conversation
- Only call ExitPlanMode when plan reflects current understanding

### Verification Planning (MANDATORY)

**BEFORE finalizing plan, ask yourself:**
- How will I verify that the implementation succeeded?
- What command/test/check proves correctness?

**Plan file MUST include a Verification section:**
- Concrete command to run
- Expected output/behavior
- What to check (file exists, content matches, test passes, etc.)

**Verification is PART of IMPLEMENT, not optional.**

### Verify Before Plan (MANDATORY)

**When a fix depends on external behavior (API responses, CLI output, file formats):**
1. FIRST: Inspect the actual response/output (curl, debug script, MCP tool call)
2. THEN: Write the plan based on verified data
3. NEVER plan a fix based on assumed external behavior

**Debug scripts** go in `debug/` folder when verification needs more than a one-liner.

**Testing/Debug Tasks (MANDATORY):**
Before proposing a test framework or debug approach, ask:
→ "What is the real risk we need to catch?"
→ Match the testing approach to the actual failure mode
→ Quantity (76 tests) != Quality (catches the right risk)
→ Example: Unit tests against static HTML fixtures don't catch the real risk for web scrapers (HTML structure changes). A scraping suite with live baselines + regression detection does.

**Red Flags:**
- "The API returns X" without having seen it
- Planning isinstance/type checks without knowing the actual type
- First verification attempt fails (e.g. auth error) and you proceed anyway
- Plan says "no code change needed" without thinking through edge cases
- Proposing a test pattern without asking "what failure mode does this actually catch?"

**"No Code Change" Plans (MANDATORY):**
When your plan concludes "existing code handles this, just run it":
1. Ask: What happens at the BOUNDARY between existing data and new data?
2. Ask: What failure modes exist? (overlaps, gaps, duplicates, ordering)
3. Ask: Has this exact scenario been tested before, or am I the first?
If ANY answer is uncertain → plan a verification step BEFORE declaring "no code change needed".

### Execution During Planning

If the planning session requires module execution to refine the plan:
1. Call ExitPlanMode
2. Execute only what is needed to refine the plan
3. Ask user to manually return to plan mode

### Before ExitPlanMode

- Plan file MUST reflect current implementation approach
- NEVER call ExitPlanMode with stale plan
- **ALWAYS ask "Any remarks?" and wait for user signal** ("done", "continue", "implement")
  - Saves tokens (no rejected ExitPlanMode calls)
  - User controls transition timing

---

## Implementation Phase (IMPLEMENT)

- execute whats stated in the PLAN file

### After IMPLEMENTATION

**Principle:** One phase per response. Never combine IMPLEMENT and RECAP in same response.

1. Verify all plan items were executed
2. **If open points remain:** Inform user: "Open items: [list]"
3. Ask: "Continue implementing or proceed to RECAP?"

User confirms → next response starts with 🔍 RECAP

### Ad-hoc Window

After completing plan edits, BEFORE transition to RECAP:

1. Claude: "Plan edits completed. Proceed to RECAP?"
2. User can request ad-hoc edits
3. Claude executes ad-hoc edits
4. Back to step 1 until user says "eval"

**CRITICAL:** This window is the ONLY place for ad-hoc edits.

---

## Recap Phase (RECAP)

### Phase Entry

1. Ask user: "Activate Plan Mode for RECAP (`/plan`)"
2. Wait for Plan Mode system message
3. Proceed with evaluation report (read-only enforced by Plan Mode)

### Plan File Handling

**CRITICAL:** Report OVERWRITES plan file completely.

- **Executed tasks:** Only mentioned in Execution summary
- **Open items:** Listed in "## Open Items" section → handled in CLOSING phase (Bead or discard)
- **No "ORIGINAL PLAN" section** - plan is consumed by execution

### Report

Claude writes a report that OVERWRITES the plan file:

#### 1. Execution

- What matched the Plan File, what deviated from the Plan File

#### 2. Process Reflection

Explicitly analyze the planning phase across two dimensions:

##### 2.1 Efficiency

###### Questions During Planning
- Were my questions focused or scattered?
- Did we iterate too much? Could we have reached the finished plan faster?
- Did I correctly understand the user's answers?
- Did the user give insightful answers?

###### Red Flags
- More than 3 back-and-forth exchanges before stable plan
- User had to correct my assumptions multiple times
- I proposed solutions before understanding the problem
- Execution Path Errors (Most IMPLEMENT failures trace back to skipped verification in PLAN)
- User did not explicitly state what he wants, gave bad directions
- User did not understand you

###### References
- Did I explicitly ask for references early enough?
- Were the references helpful or did they lead me astray?
  - Should the references have been more granular or broader?

##### 2.2 Assumptions/Hallucinations

###### Questions
- Did I make assumptions that needed correction?
- Was the user's intent clear from the start?
- Did I verify assumptions or just proceed?

###### Categories
- **Structural:** Directory layout, file locations, naming conventions
- **Semantic:** What columns mean, what functions do, data flow
- **Behavioral:** Expected output format, error handling, edge cases

###### Rule
Every assumption should be either:
1. Verified by reading code/docs
2. Explicitly confirmed with user
3. Documented as "ASSUMPTION: ..." in plan file

##### 2.3 Algorithm Investigation

When investigating WHY something behaves a certain way (selection logic, thresholds, metrics):

1. **ASK FOR SOURCE CODE IMMEDIATELY**
   - "Where is [metric] calculated?"
   - "Which file contains the selection logic?"

2. **NEVER assume metric definitions**
   - Metric names can be misleading — always read the actual calculation
   - Read the calculation, don't infer from name

3. **Trace the data flow**
   - What data goes in?
   - When is it calculated? (Once? Per iteration?)
   - What triggers recalculation?

**Red Flag:** Making hypothesis about algorithm without reading source = hallucination risk

#### 3. Hooks Evaluation

Evaluate current hooks for improvements:

**Questions:**
- Did a hook block something it shouldn't have?
- Did a hook allow something it should have blocked?
- Is output silencing helping or hiding problems?
- Should a recurring command pattern become a hook rule?

**Improvement Candidates:**
- Commands that failed due to missing hook rules
- Verbose output that polluted context
- Security patterns that should be blocked

**Reference:** `~/.claude/scripts/README.md`

#### 4. Agent Evaluation

Evaluate subagent usage during the cycle (if agents were used).

##### Output Quality

| Aspect | Rating | Criteria |
|--------|--------|----------|
| Format | ✅/⚠️/❌ | Did agent follow requested output format? |
| Relevance | ✅/⚠️/❌ | Were findings relevant to the task? |
| Completeness | ✅/⚠️/❌ | Did agent find all critical files/info? |
| Actionability | ✅/⚠️/❌ | Could I act on the output without additional research? |

##### What Helped
- List concrete benefits from agent usage

##### What Could Be Better
- Specific improvements for agent prompts or output

##### Missed Agent Usage

Identify situations where agent should have been used but wasn't:

| Situation | What I Did | What I Should Have Done |
|-----------|-----------|------------------------|
| ... | Manual search | Use agent for exploration |

**When to Use Agent:**
- Exploration over >3 files
- Unknown directory structure
- Pipeline tracing (input → output)
- When hook requests it

**Domain Skill Compliance Check (MANDATORY):**
For each active domain skill (reddit, github, etc.):
- Was the subagent dispatched when dispatch rules required it?
- If not: why? (single lookup = OK, multi-query research without sub = NOT OK)
- This catches the pattern: "I did it myself instead of dispatching" — which bypasses the skill's Dispatch First → Verify workflow

**When NOT to Use Agent (do it yourself):**
- Direct reads of known paths
- Verification after agent output
- Single targeted grep/glob

#### 5. Beads Evaluation

Run `bd list -s open` to check open beads, then evaluate:

##### 5.1 Active Beads

For each open bead touched this cycle:
- Was it commented after every significant action? If not → note the gap
- Is the latest comment sufficient for a fresh session to continue? If not → add comment in IMPROVE

##### 5.2 New Beads

Discovered work that needs cross-session tracking?
- List candidates with proposed title and description
- Title = topic, not date (e.g., "LSP Integration" not "Session 02.03")

##### 5.3 Close Completed Beads

For each bead where the topic is fully resolved:
- Mark for closing with reason

**Format:** `<id>: <reason>`

Example: `project-abc-e0m: Fixed threshold logic by adding null check in src/selection.py:42`

##### 5.4 Continuation Check (MANDATORY)

After listing all beads to close in 5.3, check: **Would closing them leave ZERO open beads?**

If yes → a Continuation-Bead MUST be created in IMPROVE phase:
- Title: Next work topic (NOT "Session YYYY-MM-DD")
- Description: What was done (context), what's next (scope), key files/repos

**Rationale:** A session with zero open beads = next session starts with zero context. The continuation bead is the bridge.

**This check is part of "Presenting Beads Hygiene" in chat text.** When all beads are proposed for closing, explicitly state: "All beads closed → Continuation-Bead needed" with proposed title and description.

#### 6. Improvements

**CRITICAL:** Every Process Improvement MUST reference an exact Automation File path + section.
Format: `[Description] → [Automation File path] → [Section to add/extend]`
Example: `API-Endpoints verifizieren → ~/.claude/CLAUDE.md → "Verify Before Execution"`
Improvements without concrete target path are not actionable → reject.

**Automation File Categories:**
1. `~/.claude/CLAUDE.md` (global — applies to ALL projects)
2. `<project>/CLAUDE.md` (project — applies to THIS project only)
3. Plugin files — see **Global Plugins** registry in `~/.claude/CLAUDE.md`
4. `.claude/commands/*.md` (project slash commands)
5. `~/.claude/scripts/` (hooks)

**Path Clarity (CRITICAL):** Always use FULL paths to distinguish global from project:
- Global: `~/.claude/CLAUDE.md`
- Project: `<project>/CLAUDE.md` or `CLAUDE.md (project)`
- NEVER write just `CLAUDE.md` without qualifier — ambiguous which one is meant

**Discovery:** Run `find ~/.claude/plugins/cache/brunowinter-plugins/ -name "plugin.json"` to locate plugin source paths.

##### 6.1 Content Improvements (Code/Docs)

Prioritization:
- **Critical:** Must fix (breaks functionality, wrong behavior)
- **Important:** Should fix (code quality, maintainability)
- **Optional:** Nice to have (style, minor optimizations)

**Handling in IMPROVE Phase:**
- Code (*.py, *.yml, etc.) → **Bead** (needs own PLAN→IMPLEMENT→RECAP cycle)
- Docs/README/Automation Files → **Direct Edit** in IMPROVE

##### 6.2 Process Improvements

Prioritization (by OUTCOME):
- **Critical:** Process errors that WOULD HAVE caused critical code issues
- **Important:** Process errors that caused detours but correct outcome
- **Optional:** Minor process inefficiencies

**Handling in IMPROVE Phase:**
- Automation Files (Skills, Commands, Agents, Hooks) → **Direct Edit** in IMPROVE
- Code → **Bead**

**CRITICAL: Process Improvements = Automation Files ONLY.**
Docs/README are Content Improvements (6.1), never Process Improvements.
If an "improvement" targets a DOCS.md or README → it belongs in 6.1, not here.

**Key insight:** OUTCOME determines severity. Wrong process + correct result = Important (not Critical).

**Recurring vs One-Off (CRITICAL):**
- Automation Files are for RECURRING issues that need persistent rules
- One-off problems (single edge case, one-time fix) do NOT belong in Automation Files
- Ask: "Will this issue come up again across multiple sessions/projects?" → YES = Automation File, NO = skip
- Polluting Automation Files with one-off rules degrades their signal-to-noise ratio

**CRITICAL: Every process error MUST produce a config change.**
- Identified process error without config change = wasted insight, error WILL repeat
- Each process improvement in RECAP MUST name the exact config file + section to change
- In IMPROVE: Execute that change. No exceptions.
- "Lesson Learned" that stays only in the RECAP report = FAILURE

**READ BEFORE PROPOSING (MANDATORY):**
- Before proposing ANY process improvement, READ the target automation file first
- You need to see what's already there to propose a meaningful change
- Without reading: you guess where it goes and what already exists → wrong proposal

##### 6.3 DOCS.md Check (MANDATORY)

**ALWAYS explicitly answer:**
- Does DOCS.md need updating? YES/NO
- If YES: What sections? (new scripts, changed parameters, new outputs)

**CRITICAL - NON-NEGOTIABLE:**
- DOCS/README updates are **NEVER optional**
- DOCS/README updates are **NEVER skippable**
- DOCS/README updates are **NEVER "insignificant"**
- Every new script, changed behavior, or new parameter MUST be reflected **IMMEDIATELY**
- Skipping DOCS updates = **BROKEN WORKFLOW** for future sessions
- If Open Items include DOCS update → **DO IT IN IMPROVE, NOT LATER**

#### 7. Open Items

List any tasks from the original plan that were NOT executed.

**CRITICAL - EMPTY PLATE RULE:**
- Every Open Item MUST become a Bead before CLOSING
- NO exceptions - even "small" items get Beads
- Rationale: New session = zero context. Beads preserve continuity.
- Test: After CLOSING, could someone pick up this work with ONLY the Bead info?

### Presenting Beads Hygiene

**Section 5 Beads Hygiene MUST appear in BOTH the plan file AND in chat text.** The user cannot see the plan file — beads status only in the plan file is invisible to them.

**Format in chat (BEFORE Process Improvements):**

For each open bead:
```
**<id>** (<title>) — <ACTIVE or CLOSE vorgeschlagen>
- Stand: <last comment summary>
- Kommentiert diese Session: JA/NEIN
- Reason (if close): <why>
```

### Presenting Process Improvements

**Section 6.2 Process Improvements MUST appear in BOTH the plan file AND in chat text.** The user cannot see the plan file — improvements only in the plan file are invisible to them.

**Automation File Rule (CRITICAL):** BEFORE proposing WHERE an improvement goes, READ the target automation file. Decide placement based on actual content, not assumptions about what's in there. This means: read ALL target files DURING RECAP, BEFORE writing the Improvements section — not after presenting it to the user.

### Collecting Improvements

After presenting improvements:
1. Ask: "Any remarks?"
2. User gives remark → **Analyze for system improvement**
3. Ask: "More remarks?"
4. Repeat until user says "done" or "improve"

**CRITICAL: Remarks → Analyze → Propose Improvement + Location**

When user gives ANY remark:
1. **Analyze:** What went wrong? What could be better?
2. **Propose:** Concrete improvement
3. **Locate:** WHERE the improvement would happen (Automation File + path)

**Output Format:**
```
Remark: [User's remark]
Analysis: [What went wrong]
Improvement: [Concrete change]
Location: [Automation File + file path]
```

**The Goal:** Every remark → concrete improvement proposal with exact location.

### Phase Exit

1. Ensure all improvements are written to plan file
2. Call ExitPlanMode
3. Next response starts with 🛠️ IMPROVE

---

## Improve Phase (IMPROVE)

**Purpose:** Execute improvements from plan file.

**CRITICAL:** IMPROVE has no validation after it. Therefore:
- Code → Bead (own cycle with validation)
- Everything else → Direct Edit

### Workflow

1. Read plan file "## Improvements" and "## Open Items" sections
2. **DOCS/README updates FIRST** - these are NEVER skippable:
   - If any new script was created → update DOCS.md
   - If any script behavior changed → update DOCS.md
   - If any new output was generated → update DOCS.md
3. For each other improvement (see 6.1/6.2 Handling):
   - **Code?** → `bd create --title "..." --type=...`
   - **Automation Files?** → Edit workflow:
     1. READ the target file fully
     2. SEARCH for overlapping rules/sections
     3. If overlap: EXTEND existing section with new content
     4. If no overlap: ADD new section, keeping all existing sections untouched
     5. If restructuring needed: MOVE text, never delete it
4. Handle Beads (from RECAP Section 5):
   - Create: `bd create --title "..." --type=...`
   - Update: `bd comments add <id> "..."`
   - Close: `bd close <id> --reason="..."`
5. **Handle Open Items (MANDATORY - EMPTY PLATE RULE):**
   - For EACH Open Item from RECAP Section 7:
   - `bd create --title "..." --description="..." --type=task`
   - NO exceptions - session ends with ZERO open items
6. Ask: "Proceed to CLOSING?"

User confirms → next response starts with ✅ CLOSING

---

## Closing Phase (CLOSING)

Only enter when user confirms (e.g., "proceed", "close", "done").

**PRE-CLOSE CHECK (MANDATORY):**
- Verify ALL Open Items from RECAP have Beads
- If ANY Open Item has no Bead → CREATE IT NOW before proceeding
- This check is NON-NEGOTIABLE

**PLUGIN-SYNC CHECK (MANDATORY):**
- Were ANY plugin-distributed files edited this session? (Skills, Agents, Commands, server.py, src/ modules)
- Check: Does the current project have a `plugin-sync.sh` entry? (see `~/.claude/CLAUDE.md` Plugin Cache Management)
- If YES → run `plugin-sync.sh <plugin-name> <repo-path>` BEFORE commit
- If NO → skip
- **Without sync: edited Skills/Agents/Tools stay in source repo but never reach the plugin cache. The MCP server runs from cache — unsyncronized changes are invisible to Claude Code.**

**EVAL CLEANUP (MANDATORY):**
- Delete ONLY the reports that were read and processed in THIS session's RECAP
- Track which agent IDs were processed during RECAP — delete only those
- `rm -f Evaluation_Proposals/<agent_id_1>.md Evaluation_Proposals/<agent_id_2>.md`
- NEVER `rm -f Evaluation_Proposals/*.md` — other sessions may have unprocessed reports

1. `bd export` (JSONL export — replaces old `bd sync`)
2. Plugin-Sync (if applicable — see check above)
3. **Commit ALL repos with changes** — not just the project repo:
   - Project repo: `git add . && git commit && git push`
   - Plugin source repos (e.g., `~/Documents/ai/Meta/blank`): `git add . && git commit && git push`
   - Any other repo touched this session
   - **A repo with uncommitted changes = lost work in the next session**
4. Ask: "New cycle or done for now?"

---

## Explore Agent (code-investigate-specialist)

**This agent is part of the iterative-dev skill.** It is the ONLY agent used during the PLAN phase for codebase exploration. Always use `subagent_type="code-investigate-specialist"` — never use system agents (Explore, general-purpose, etc.) for codebase investigation.

### General Agent Rules

**Rule of thumb:** Better one agent too many than one too few.

Use agent when:
- Exploration scope unclear
- Multiple sources to check
- >20k tokens of reading expected

Do NOT use when:
- Single file/URL (known path)
- Quick verification

### Agent Info

| Agent | subagent_type | Model | Output |
|-------|---------------|-------|--------|
| code-investigate-specialist | `code-investigate-specialist` | Haiku | FILE/LINES/RELEVANT |

**Usage:** `Task(subagent_type="code-investigate-specialist", prompt="...")`

### When to Use

**Simple Rule:**
- **User provides file path** -> Read directly (no agent)
- **User provides directory path** -> Use agent (content unknown)

Use agent when:
- User gives directory instead of file
- "Where is X?" / "How does Y work?" questions
- Comparing between directories
- Searching >3 unknown files

### When NOT to Use

- User provides exact file path
- Reading single known files
- Targeted grep/glob with clear scope

### How to Prompt

**BAD:**
- "Find where features are defined"
- "How does pattern selection work?"
- "List all subdirectories and their contents" (too broad)

**GOOD:**
- "Find FEATURES constant definition in src/"
- "Find function that filters by threshold in selection/"
- "List subdirectories and source files in lib/. Exclude data files."

**Pattern:**
1. Specific target (constant, function, class)
2. Scope (directory)
3. Constraints: "Exclude *.csv, *.png" or "Limit depth to 2"
4. Context if needed
5. **Follow imports:** "If code imports from external modules, locate and READ those files"

**Exploration Constraints:**
- Always specify: "Exclude data files (*.csv, *.png, *.jpg)"
- For unknown directories: "Limit initial depth to 2 levels"
- For doc audits: "Focus on *.py files and DOCS.md"

**Tool Recommendations (include in prompt):**
- "Use `find` to locate files. Do NOT use `ls -R`"
- For CSV: "Use awk for numeric comparison, not grep"
- For JSON/JSONL: "Use jq or Python script. NEVER grep for field values."

### Parallel Agent Rules

Parallel agents only efficient with **disjoint datasets**.

**Partition by:**
- **Layer:** Agent A = Docs only, Agent B = Code only
- **Scope:** Agent A = src/, Agent B = tests/
- **Aspect:** Agent A = Input/Output flow, Agent B = Algorithm logic

**NEVER:** Have multiple agents read the same files.

### After Agent Returns

**CRITICAL: Agent = Scout, not Authority**

Agent provides:
- WHERE: Location (file path + lines)
- WHAT: Its interpretation

**You MUST:**
1. Present results directly to user (don't summarize the summary)
2. Verify critical findings yourself if needed
3. When in doubt: check yourself instead of trusting blindly

**NEVER** trust agent output blindly. The agent may:
- Miss files
- Misinterpret code
- Hallucinate paths

**Verification Checklist:**
- [ ] Read at least 1 critical file mentioned by agent
- [ ] Confirm key claims (file exists, function does X)
- [ ] If agent provided summary: spot-check 1-2 details

**If you skip verification:**
→ State explicitly: "Agent output not verified"

**Retry Logic:**
If results are useless (generic, wrong topic, no insights):
- Re-run with feedback: "Previous results were [problem]. This time: [fix]"
- Max 2 retries, then report failure to user

### Known Pitfalls

#### 1. Path Hallucinations
- **Symptom:** `Tool_use_error: File does not exist`
- **Fix:** "Only read files explicitly listed in your previous `find` or `ls` output"

#### 2. Serial Reads (Latency)
- **Symptom:** Multiple sequential Read calls for related files
- **Fix:** "Read related config files in a single step when possible"

#### 3. Missing File Chase
- **Symptom:** 5+ attempts to find a file that doesn't exist
- **Fix:** "If a referenced file is missing after 2 search attempts, log as 'MISSING: <file>' and continue"

#### 4. Redundant grep + read
- **Symptom:** grep output followed by full file read
- **Fix:** "Use grep with `-C 5` context. Only read full file if context is insufficient"

#### 5. Pattern Blindness
- **Symptom:** Simple text search misses array/struct definitions
- **Fix:** "Note: Some codebases store parameters in static arrays, not individual constants"
