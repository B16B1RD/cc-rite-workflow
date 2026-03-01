# Plugin Path Resolution

Common helper for dynamically resolving the plugin root directory. Supports both local development (`--plugin-dir`) and marketplace installation environments.

## Overview

Plugin files are located at different paths depending on the installation method:

| Environment | Plugin Root |
|-------------|-------------|
| Local development | `{project_root}/plugins/rite/` |
| Marketplace install | `~/.claude/plugins/cache/rite-marketplace/rite/{version}/` |

Commands that need to read plugin files (templates, agents, references, skills) must resolve the plugin root dynamically to work in both environments.

## Resolution Script

Run the following bash command to detect the plugin root. This command assumes CWD is the project root (Claude Code's Bash tool resets CWD to the project root on each invocation):

```bash
if [ -d "plugins/rite" ]; then
  echo "PLUGIN_ROOT:$(cd plugins/rite && pwd)"
elif ! command -v jq >/dev/null 2>&1; then
  echo "PLUGIN_ROOT_NOT_FOUND:NO_JQ"
elif [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then
  INSTALL_PATH=$(jq -r '.plugins["rite@rite-marketplace"][0].installPath // empty' \
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
- `PLUGIN_ROOT_NOT_FOUND:NO_JQ` → Display warning: `jq is required for plugin path resolution but was not detected.` Fall back to hardcoded relative paths (`plugins/rite/...`) or inline fallback content.
- `PLUGIN_ROOT_NOT_FOUND:NO_INSTALL` → Display warning: `Plugin installation not found.` Fall back to hardcoded relative paths or inline fallback content.

## Usage Convention

### Placeholder

Use `{plugin_root}` as a placeholder in file paths throughout command files:

```
Read: {plugin_root}/templates/completion-report.md
Read: {plugin_root}/agents/{reviewer_type}-reviewer.md
Read: {plugin_root}/commands/pr/references/reviewer-fallbacks.md
```

### When to Resolve

Resolve `{plugin_root}` **once per command execution**, at the earliest phase that requires reading plugin files. Store the resolved path and reuse it for all subsequent Read tool calls within the same command.

### Reference in Command Files

Command files that need plugin path resolution should include:

```markdown
> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before reading plugin files.
```

## Relationship to init.md Hook Path Resolution

`init.md` Phase 4.5.0 uses a similar but specialized detection for the `hooks/` subdirectory. This helper generalizes that pattern for the entire plugin root. The detection logic is intentionally consistent between the two.
