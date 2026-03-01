# Plugin Development Skill

Activate manually when working on Claude Code plugin development, distribution, or cache management.

---

## Plugin Architecture (3-Repo Chain)

```
Source Repo              Marketplace Repo                    Plugin Cache
(brunowinter8192/RAG)    (brunowinter8192/claude-plugins)    (~/.claude/plugins/cache/)
  ↓ git push               ↓ git push (only for new plugins)   ↓ plugin-sync.sh
  Code changes              Registry: name → repo               Local copy, loaded by CC
```

| Component | Purpose | When to Update |
|-----------|---------|----------------|
| **Source Repo** | Actual plugin code (skills, agents, commands, MCP server) | Every change |
| **Marketplace Repo** | Registry mapping plugin names to GitHub repos | New plugin, repo rename, version bump |
| **Plugin Cache** | Local clone loaded by Claude Code at session start | After every source push |

### Key Files

| File | Location | Purpose |
|------|----------|---------|
| `plugin.json` | `<repo>/.claude-plugin/plugin.json` | Plugin manifest (name, version, components) |
| `marketplace.json` | `<marketplace-repo>/.claude-plugin/marketplace.json` | Registry: plugin name → GitHub repo |
| `installed_plugins.json` | `~/.claude/plugins/installed_plugins.json` | Cache metadata (SHA, timestamp, scope, path) |
| `known_marketplaces.json` | `~/.claude/plugins/known_marketplaces.json` | Registered marketplace repos |

---

## plugin.json Best Practice

### Explicit Declaration (REQUIRED)

ALWAYS declare `skills`, `agents`, `mcpServers`, `commands` explicitly.

**Good (Reddit pattern):**
```json
{
  "name": "reddit",
  "version": "1.0.0",
  "skills": ["./skills/reddit/", "./skills/agent-reddit-search/"],
  "agents": ["./agents/reddit-search.md"],
  "commands": ["./commands/some-command.md"],
  "mcpServers": {
    "reddit": {
      "command": "${CLAUDE_PLUGIN_ROOT}/mcp-start.sh",
      "args": []
    }
  }
}
```
→ Clean tool names: `mcp__reddit__<tool>`

**Bad (minimal pattern):**
```json
{
  "name": "github-research",
  "version": "1.0.0"
}
```
→ Ugly auto-generated names: `mcp__plugin_github-research_github__<tool>`

### Component Types

| Field | Value | Notes |
|-------|-------|-------|
| `skills` | Array of paths or single path | Directories containing SKILL.md |
| `agents` | Array of .md file paths | Agent definition files |
| `commands` | Array of .md file paths | Slash command files |
| `mcpServers` | Object with server configs | MCP server definitions |

### ${CLAUDE_PLUGIN_ROOT}

Special variable in plugin commands/configs. Resolves to the plugin's cache directory at runtime.

- Use for ALL paths in `mcpServers` config and command files
- Never hardcode absolute paths in distribution files
- Only available in plugin context (not in `.claude/` source files)

---

## Source vs Distribution

### Two-Copy Pattern

| Aspect | Source (edit here) | Distribution (auto-synced) |
|--------|-------------------|---------------------------|
| **Path** | `.claude/commands/`, `.claude/skills/`, `.claude/agents/` | `commands/`, `skills/`, `agents/` (repo root) |
| **Paths inside** | Absolute (local dev) | `${CLAUDE_PLUGIN_ROOT}` (portable) |
| **Tracked by git** | Yes | Yes |
| **What CC loads** | Local dev only | Plugin users via cache |

### Path Substitution

Distribution copies replace absolute paths with variables:
- `/Users/.../project/` → `${CLAUDE_PLUGIN_ROOT}/`
- Custom env paths → `${MINERU_PATH}` etc.

### Sync

Source → Distribution sync must happen before commit.
Options:
- Pre-commit hook (can be overwritten by other tools like beads)
- Manual copy before commit
- Script that does both

---

## Cache System

### Structure

```
~/.claude/plugins/
├── cache/
│   └── brunowinter-plugins/
│       ├── rag/1.0.0/              ← Full repo clone
│       ├── reddit/1.0.0/
│       └── iterative-dev/1.0.0/
├── marketplaces/
│   └── brunowinter-plugins/        ← Marketplace repo clone
├── installed_plugins.json           ← Metadata (SHA, timestamp, scope)
├── known_marketplaces.json          ← Registered marketplaces
└── blocklist.json
```

### installed_plugins.json

```json
{
  "rag@brunowinter-plugins": [{
    "scope": "user",
    "installPath": "~/.claude/plugins/cache/brunowinter-plugins/rag/1.0.0",
    "version": "1.0.0",
    "gitCommitSha": "da3614b...",
    "lastUpdated": "2026-02-22T21:37:34.954Z"
  }]
}
```

Key fields:
- **scope:** `"user"` (global) or `"local"` (single project)
- **gitCommitSha:** Exact commit in cache — stale if behind HEAD
- **version:** From plugin.json — same version does NOT guarantee fresh cache

### Cache Update Methods

| Method | Reliability | Speed |
|--------|-------------|-------|
| `/plugin install` | Unreliable (version caching) | Slow (GitHub fetch) |
| **`plugin-sync.sh`** | **Reliable (direct rsync)** | **Fast (local copy)** |

**ALWAYS use `plugin-sync.sh` for development.**

---

## Plugin Scope Management

### Installation Scopes

| Scope | Meaning | Use When |
|-------|---------|----------|
| `user` | Available in ALL projects | Infrastructure plugins (iterative-dev) |
| `local` | Available in ONE project | Project-specific plugins |

### Multi-Project Scoping

Claude Code does NOT support `scope: ["project-a", "project-b"]`.

**Workaround:** Install globally (`scope: "user"`), then enable per-project:

```json
// In <project>/.claude/settings.local.json
{
  "enabledPlugins": {
    "github-research@brunowinter-plugins": true
  }
}
```

Disable in other projects by not adding the entry.

---

## Update Workflow

### After Code Changes (Every Time)

```
1. Edit source files (.claude/)
2. Sync to distribution (commands/, skills/)
3. Check plugin.json (new components listed?)
4. git add + commit + push
5. plugin-sync.sh <name> <repo-path>
6. Start new CC session
7. /context → verify changes visible
```

### After New Plugin (One-Time)

Additional steps:
1. Add to `marketplace.json` in marketplace repo
2. Commit + push marketplace repo
3. `/plugin install <name>@brunowinter-plugins` (initial install)
4. Then use `plugin-sync.sh` for all future updates

---

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| Command not in `/context` | Cache outdated | `plugin-sync.sh` |
| Ugly tool names (`mcp__plugin_...`) | Minimal plugin.json, no explicit mcpServers | Add explicit `mcpServers` field |
| Source deleted, only distribution exists | Accidental deletion, no backup | Restore from distribution copy |
| Plugin.json missing new command | Forgot to add to `commands` array | Update plugin.json |
| Pre-commit hook not syncing | Hook overwritten by other tools (beads) | Manual sync or separate hook |
| `/plugin install` doesn't update | Same version cached | Use `plugin-sync.sh` instead |
| Plugin works in one project only | `scope: "local"` | Reinstall as `scope: "user"` or use `enabledPlugins` |

---

## LSP Plugins

LSP (Language Server Protocol) plugins give Claude Code real-time code intelligence — go-to-definition, find-references, type checking, instant diagnostics after edits.

### How LSP Plugins Work

Unlike normal plugins (skills, agents, MCP servers), LSP plugins are **lightweight wrappers** around existing language server binaries. They contain:
- A `.lsp.json` config file telling Claude Code which binary to run
- A README and LICENSE
- **No code** — the language server binary must be installed separately

Claude Code connects to the language server via stdio and uses it for code navigation instead of grep-based text search.

### Official LSP Plugins (Anthropic)

Source: `anthropics/claude-plugins-official` (8.6k stars)

| Plugin | Language | Binary Install |
|--------|----------|----------------|
| `pyright-lsp` | Python | `pipx install pyright` |
| `typescript-lsp` | TypeScript/JS | `npm i -g typescript-language-server typescript` |
| `gopls-lsp` | Go | `go install golang.org/x/tools/gopls@latest` |
| `rust-analyzer-lsp` | Rust | `rustup component add rust-analyzer` |
| `jdtls-lsp` | Java | `brew install jdtls` |
| `clangd-lsp` | C/C++ | `brew install llvm` |
| `csharp-lsp` | C# | `dotnet tool install -g csharp-ls` |
| `kotlin-lsp` | Kotlin | — |
| `lua-lsp` | Lua | — |
| `php-lsp` | PHP | — |
| `swift-lsp` | Swift | — |

### Installation

1. Install the language server binary (e.g., `pipx install pyright`)
2. Claude Code auto-detects `.py` files + `pyright-langserver` on PATH → prompts to install LSP plugin
3. Accept the prompt, restart Claude Code

### Creating Custom LSP Plugins

Add `.lsp.json` to plugin root (or inline as `lspServers` in `plugin.json`):

```json
{
  "python": {
    "command": "pyright-langserver",
    "args": ["--stdio"],
    "extensionToLanguage": {
      ".py": "python",
      ".pyi": "python"
    }
  }
}
```

**Required fields:**

| Field | Description |
|-------|-------------|
| `command` | LSP binary to execute (must be in PATH) |
| `extensionToLanguage` | Maps file extensions to language identifiers |

**Optional fields:**

| Field | Description |
|-------|-------------|
| `args` | Command-line arguments for the LSP server |
| `transport` | `stdio` (default) or `socket` |
| `env` | Environment variables for the server |
| `initializationOptions` | Options passed during server initialization |
| `settings` | Settings passed via `workspace/didChangeConfiguration` |
| `startupTimeout` | Max wait for server startup (ms) |
| `shutdownTimeout` | Max wait for graceful shutdown (ms) |
| `restartOnCrash` | Auto-restart on crash (boolean) |
| `maxRestarts` | Max restart attempts |

### Standalone LSP (Without Plugin)

Place `.lsp.json` directly in the project root for project-scoped LSP support without creating a full plugin. Claude Code discovers it automatically.

### Performance Impact

| | Without LSP (grep) | With LSP |
|---|---|---|
| Code navigation | 30-60 seconds | ~50ms |
| Accuracy | Fuzzy text matches | Exact semantic matches |
| Error detection | Manual | Instant after each edit |
