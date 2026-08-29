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
| 1 (preferred) | `.rite/plugin-root` file (legacy `.rite-plugin-root` as read fallback) | Written by `session-start.sh` at each session start | After first session start in the project |
| 2 (local dev) | `plugins/rite` directory check | Local development checkout | Always in local dev |
| 3 (fallback) | `installed_plugins.json` lookup | Claude Code marketplace metadata | After marketplace install |

## `installPath` Semantics

`installed_plugins.json`'s `installPath` field **is** the plugin root itself — it does **not** point to a parent directory containing a `plugins/rite/` subdirectory. Verified against a live marketplace install (`rite@rite-marketplace`, v0.8.1): `installPath` resolved to `~/.claude/plugins/cache/rite-marketplace/rite/0.8.1`, and `hooks/`, `skills/`, `scripts/`, `references/` exist directly under that path — there is no nested `plugins/rite/` directory.

Every consumer of `installPath` must derive the hooks/skills/scripts dir as `$INSTALL_PATH/hooks` (etc.), never `$INSTALL_PATH/plugins/rite/hooks`. This matches Priority 3 above and `skills/setup/SKILL.md` Phase 4.5.0. `hooks/hook-preamble.sh` previously assumed the wrong (`plugins/rite/`-nested) layout, which made its version-redirect check silently never match.

## Inline One-Liner (for command files)

**Use this one-liner directly in command files** instead of referencing this document. This prevents Claude LLM from improvising its own resolution logic:

```bash
plugin_root=$(cat .rite/plugin-root 2>/dev/null || cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
```

**Validation** (recommended after resolution):

```bash
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/hooks" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
```

## Resolution Script (Full Version)

The full multi-step script with structured output (used when detailed error reporting is needed):

```bash
# Priority 1: .rite/plugin-root (written by session-start.sh, version-independent)
# Legacy `.rite-plugin-root` is a read fallback only.
if [ -f ".rite/plugin-root" ] && [ -n "$(cat .rite/plugin-root 2>/dev/null)" ]; then
  _pr=$(cat .rite/plugin-root)
  if [ -d "$_pr/hooks" ]; then
    echo "PLUGIN_ROOT:$_pr"
  else
    echo "PLUGIN_ROOT_NOT_FOUND:STALE_MARKER"
  fi
elif [ -f ".rite-plugin-root" ] && [ -n "$(cat .rite-plugin-root 2>/dev/null)" ]; then
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
- `PLUGIN_ROOT_NOT_FOUND:STALE_MARKER` → `.rite/plugin-root` (or legacy `.rite-plugin-root`) exists but points to a deleted directory. Display warning: `Stale .rite/plugin-root detected. Re-run session or use /rite:setup.` The Full Version script does not auto-fallback to Priority 2/3 in this case; use the inline one-liner (which handles fallback automatically) instead.
- `PLUGIN_ROOT_NOT_FOUND:NO_INSTALL` → Display warning: `Plugin installation not found.` Fall back to hardcoded relative paths or inline fallback content.

## How `.rite/plugin-root` Works

`session-start.sh` writes the resolved plugin root to `$STATE_ROOT/.rite/plugin-root` at every session start (startup and `/clear`). The path is derived from the hook script's own location (`SCRIPT_DIR`), making it **version-independent** — no hardcoded version numbers or marketplace names. Readers fall back to the legacy `$STATE_ROOT/.rite-plugin-root` when the new file is absent.

```
session-start.sh 実行時:
  SCRIPT_DIR = hooks/ の絶対パス（BASH_SOURCE[0] から自動解決）
  PLUGIN_ROOT = dirname(SCRIPT_DIR)
  → $STATE_ROOT/.rite/plugin-root に書き出し
```

This is consistent with `hooks.json` using `${CLAUDE_PLUGIN_ROOT}`, an environment variable that Claude Code automatically sets when executing hooks registered in `hooks.json`. The variable points to the plugin's install directory (e.g., `~/.claude/plugins/cache/rite-marketplace/rite/0.3.3/`). Note that `${CLAUDE_PLUGIN_ROOT}` is only available during hook execution — it is NOT set during normal Bash tool calls from command/skill files, which is why `.rite/plugin-root` is needed.

## Usage Convention

### Placeholder

Use `{plugin_root}` as a placeholder in file paths throughout command files:

```
Read: {plugin_root}/templates/issue/default.md
Read: {plugin_root}/agents/{reviewer_type}-reviewer.md
```

### When to Resolve

Resolve `{plugin_root}` **once per command execution**, at the earliest phase that requires reading plugin files. Store the resolved path and reuse it for all subsequent Read tool calls within the same command.

### Reference in Command Files

Command files that need plugin path resolution should include the inline one-liner directly:

```markdown
> **Plugin Path**: Resolve `{plugin_root}` using the inline one-liner:
> ```bash
> plugin_root=$(cat .rite/plugin-root 2>/dev/null || cat .rite-plugin-root 2>/dev/null || bash -c '...')
> ```
```

**Important**: New command files should embed the one-liner directly rather than referencing this document with a link. Existing command files that still use the link-reference pattern (`per [Plugin Path Resolution](...)`) will be migrated incrementally to the inline one-liner in future Issues.

## Relationship to skills/setup/SKILL.md Hook Path Resolution

`skills/setup/SKILL.md` Phase 4.5.0 uses a similar but specialized detection for the `hooks/` subdirectory. This helper generalizes that pattern for the entire plugin root. The detection logic is intentionally consistent in approach (both look up `rite@*` entries in `installed_plugins.json`), though the two use **different jq shapes** that can diverge — see [Cross-Method Version Mismatch Check](#cross-method-version-mismatch-check-issue-1833) below for the divergence and its mitigation.

## Cross-Method Version Mismatch Check

The codebase contains **two jq lookup shapes** against `installed_plugins.json`:

| Shape | Used by | jq filter |
|-------|---------|-----------|
| Canonical one-liner | this document (Priority 3) + all skill/hook call sites | `limit(1; .plugins \| to_entries[] \| select(.key \| startswith("rite@"))) \| .value[0].installPath` — first `rite@*` entry |
| Direct key lookup | `skills/setup/SKILL.md` Phase 4.5.0 (hooks dir detection) | `.plugins["rite@rite-marketplace"][0].installPath` — exact key |

When `installed_plugins.json` holds more than one `rite@*` entry (e.g., right after a marketplace cache update), the two shapes can return **different versions**, so hooks (resolved by 4.5.0) and skills/helpers (resolved by the one-liner) silently reference mixed plugin versions within one session. If sentinel formats / JSON schemas / marker conventions differ between those versions, the drift is very hard to trace.

**Detection point**: `skills/setup/SKILL.md` Phase 4.5.0 runs both lookups and emits a WARNING with both paths when they differ. The resolved result stays the direct key lookup (no behavior change); the check itself is non-blocking — a jq failure in the canonical probe falls back to no warning. When `installed_plugins.json` is absent (local development), no probe runs and no warning appears.

**Do NOT add further resolution shapes**: any new call site must use the canonical one-liner above. The direct key lookup in 4.5.0 is retained for backward compatibility and is the only sanctioned exception (paired with the mismatch check).
