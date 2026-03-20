# Plugin Path Resolution

Common helper for dynamically resolving the plugin root directory. Supports both local development (`--plugin-dir`) and marketplace installation environments.

## Overview

Plugin files are located at different paths depending on the installation method:

| Environment | Plugin Root |
|-------------|-------------|
| Local development | `{project_root}/plugins/rite/` |
| Marketplace install | `~/.claude/plugins/cache/rite-marketplace/rite/{version}/` |

Commands that need to read plugin files (templates, agents, references, skills) must resolve the plugin root dynamically to work in both environments.

## Resolution Priority

The plugin root is resolved using a 3-tier priority system:

| Priority | Method | Source | When Available |
|----------|--------|--------|----------------|
| 1 (preferred) | `.rite-plugin-root` file | Written by `session-start.sh` at each session start | After first session start in the project |
| 2 (local dev) | `plugins/rite` directory check | Local development checkout | Always in local dev |
| 3 (fallback) | `installed_plugins.json` lookup | Claude Code marketplace metadata | After marketplace install |

## Inline One-Liner (for command files)

**Use this one-liner directly in command files** instead of referencing this document. This prevents Claude LLM from improvising its own resolution logic:

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
```

**Validation** (recommended after resolution):

```bash
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/hooks" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
fi
```

## Resolution Script (Full Version)

The full multi-step script with structured output (used when detailed error reporting is needed):

```bash
# Priority 1: .rite-plugin-root (written by session-start.sh, version-independent)
if [ -f ".rite-plugin-root" ] && [ -n "$(cat .rite-plugin-root 2>/dev/null)" ]; then
  _pr=$(cat .rite-plugin-root)
  if [ -d "$_pr/hooks" ]; then
    echo "PLUGIN_ROOT:$_pr"
  else
    echo "PLUGIN_ROOT_NOT_FOUND:STALE_MARKER"
  fi
# Priority 2: Local development directory
elif [ -d "plugins/rite" ]; then
  echo "PLUGIN_ROOT:$(cd plugins/rite && pwd)"
# Priority 3: Marketplace install via installed_plugins.json
elif command -v jq >/dev/null 2>&1 && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then
  INSTALL_PATH=$(jq -r 'limit(1; .plugins | to_entries[] | select(.key | startswith("rite@"))) | .value[0].installPath // empty' \
    "$HOME/.claude/plugins/installed_plugins.json")
  if [ -n "$INSTALL_PATH" ] && [ -d "$INSTALL_PATH" ]; then
    echo "PLUGIN_ROOT:$INSTALL_PATH"
  else
    echo "PLUGIN_ROOT_NOT_FOUND:NO_INSTALL"
  fi
else
  echo "PLUGIN_ROOT_NOT_FOUND:NO_INSTALL"
fi
```

### Result Handling

- `PLUGIN_ROOT:<path>` → Extract the absolute path after `PLUGIN_ROOT:` and use it as `{plugin_root}` for all subsequent file reads in the current command.
- `PLUGIN_ROOT_NOT_FOUND:STALE_MARKER` → `.rite-plugin-root` exists but points to a deleted directory. Display warning and fall back to Priority 2/3.
- `PLUGIN_ROOT_NOT_FOUND:NO_INSTALL` → Display warning: `Plugin installation not found.` Fall back to hardcoded relative paths or inline fallback content.

## How `.rite-plugin-root` Works

`session-start.sh` writes the resolved plugin root to `$STATE_ROOT/.rite-plugin-root` at every session start (startup and `/clear`). The path is derived from the hook script's own location (`SCRIPT_DIR`), making it **version-independent** — no hardcoded version numbers or marketplace names.

```
session-start.sh 実行時:
  SCRIPT_DIR = hooks/ の絶対パス（BASH_SOURCE[0] から自動解決）
  PLUGIN_ROOT = dirname(SCRIPT_DIR)
  → $STATE_ROOT/.rite-plugin-root に書き出し
```

This is consistent with `hooks.json` using `${CLAUDE_PLUGIN_ROOT}` (resolved by Claude Code natively).

## Usage Convention

### Placeholder

Use `{plugin_root}` as a placeholder in file paths throughout command files:

```
Read: {plugin_root}/templates/completion-report.md
Read: {plugin_root}/agents/{reviewer_type}-reviewer.md
```

### When to Resolve

Resolve `{plugin_root}` **once per command execution**, at the earliest phase that requires reading plugin files. Store the resolved path and reuse it for all subsequent Read tool calls within the same command.

### Reference in Command Files

Command files that need plugin path resolution should include the inline one-liner directly:

```markdown
> **Plugin Path**: Resolve `{plugin_root}` using the inline one-liner:
> ```bash
> plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c '...')
> ```
```

**Important**: Do NOT reference this document with a link and expect Claude to read it. Embed the one-liner directly in the command file to prevent Claude from improvising its own resolution logic.

## Relationship to init.md Hook Path Resolution

`init.md` Phase 4.5.0 uses a similar but specialized detection for the `hooks/` subdirectory. This helper generalizes that pattern for the entire plugin root. The detection logic is intentionally consistent between the two.
