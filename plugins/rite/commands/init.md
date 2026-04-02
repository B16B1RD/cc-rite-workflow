---
description: rite workflow の初回セットアップウィザード
---

# /rite:init

Initial setup wizard for rite workflow

---

## Arguments

| Argument | Description |
|----------|-------------|
| `--upgrade` | Upgrade existing rite-config.yml to the latest schema version |

When `--upgrade` is specified, skip to [Phase 4.1.3 (Upgrade)](#413-upgrade-existing-configuration). Otherwise, run the following phases in order.

## Phase 1: Environment Check

### 1.1 Verify gh CLI Installation

```bash
gh --version
```

If not installed, show:
```
{i18n:init_gh_not_installed}

{i18n:init_install_instructions}:
- macOS: `brew install gh`
- Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
- Windows: `winget install GitHub.cli`
```
and exit.

### 1.2 Verify python3 Availability

```bash
python3 --version
```

If not installed, show:
```
⚠️ python3 が見つかりません。

rite workflow の作業メモリ機能（YAML frontmatter パース）に python3 が必要です。
インストール方法:
- macOS: `brew install python3` または Xcode Command Line Tools に含まれています
- Linux: `sudo apt install python3` (Debian/Ubuntu) / `sudo dnf install python3` (Fedora)
- Windows: https://www.python.org/downloads/
```
Display warning and continue (python3 is required for work memory parsing but not blocking for init).

### 1.3 Verify GitHub Authentication Status

```bash
gh auth status
```

If not authenticated, show:
```
{i18n:init_not_authenticated}

{i18n:init_auth_command}: `gh auth login`
```
and exit.

### 1.4 Retrieve Repository Information

```bash
gh repo view --json owner,name,id,url
```

If not a Git repository or not a GitHub repository, show:
```
{i18n:init_not_github_repo}
```
and exit.

---

## Phase 2: Determine Project Type

### 2.1 Auto-detect from File Structure

Check in the following order:

1. **webapp**: `package.json` exists and contains one of the following
   - dependencies include `react`, `vue`, `angular`, `svelte`, `next`, `nuxt`
   - `vite.config.*`, `webpack.config.*` exists

2. **library**: `package.json` exists and has a `main` or `exports` field

3. **cli**: One of the following
   - `pyproject.toml` has a `[project.scripts]` section
   - `package.json` has a `bin` field
   - `Cargo.toml` has a `[[bin]]` section

4. **documentation**: One of the following exists
   - `mkdocs.yml`, `docusaurus.config.js`, `vuepress.config.*`
   - Composed only of a `docs/` directory

5. **generic**: Does not match any of the above

### 2.2 User Confirmation

Confirm the detection result with AskUserQuestion:

```
{i18n:init_confirm_project_type}:
- webapp: {i18n:init_project_type_webapp}
- library: {i18n:init_project_type_library}
- cli: {i18n:init_project_type_cli}
- documentation: {i18n:init_project_type_documentation}
- generic: {i18n:init_project_type_generic}
```

---

## Phase 3: GitHub Projects Configuration

### 3.1 Detect Existing Projects

```bash
gh project list --owner {owner} --format json
```

### 3.2 Present Options

Select with AskUserQuestion:

オプション:
- {i18n:init_projects_use_existing}
- {i18n:init_projects_create_new}

### 3.3 If Creating New

```bash
gh project create --owner {owner} --title "{repo-name}" --format json
```

### 3.4 Verify and Configure Fields

```bash
gh project field-list {project-number} --owner {owner} --format json
```

Create any required fields that do not exist:

```bash
# Priority フィールド
gh project field-create {project-number} --owner {owner} --name "Priority" --data-type "SINGLE_SELECT" --single-select-options "High,Medium,Low"

# Complexity フィールド
gh project field-create {project-number} --owner {owner} --name "Complexity" --data-type "SINGLE_SELECT" --single-select-options "XS,S,M,L,XL"
```

If the Status field does not have "In Review", add it via GraphQL:

```bash
gh api graphql -f query='
mutation {
  updateProjectV2Field(input: {
    fieldId: "{status-field-id}"
    singleSelectOptions: [
      {name: "Todo", color: GRAY, description: "Not started"}
      {name: "In Progress", color: YELLOW, description: "Work in progress"}
      {name: "In Review", color: BLUE, description: "Under review"}
      {name: "Done", color: GREEN, description: "Completed"}
    ]
  }) {
    projectV2Field { ... on ProjectV2SingleSelectField { name } }
  }
}'
```

---

## Phase 3.5: Iteration Field Configuration (Optional)

### 3.5.1 Check for Iteration Field

Verify the existence of an Iteration field via GraphQL:

```bash
gh api graphql -f query='
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2IterationField {
            id
            name
            configuration {
              iterations {
                id
                title
                startDate
                duration
              }
            }
          }
        }
      }
    }
  }
}' -f projectId="{project-id}"
```

NOTE: `{project-id}` is the Projects Node ID obtained in Phase 3

### 3.5.2 Present Options

Confirm with AskUserQuestion:

```
Iteration/スプリント管理を使用しますか？

オプション:
- はい、使用する（Iteration フィールドを検出しました: {field_name}）
  → 3.5.3 へ
- はい、使用する（Iteration フィールドを作成する必要があります）
  → 3.5.4 へ
- いいえ、使用しない
  → Phase 4 へスキップ
```

### 3.5.3 If Iteration Field Exists

- Record the field name (used for `iteration.field_name` in rite-config.yml)
- Retrieve and display the current iteration information

### 3.5.4 If Iteration Field Does Not Exist

Display a manual creation guide:

```
{i18n:init_iteration_manual_create_note}

{i18n:init_iteration_creation_steps}:
1. {i18n:init_iteration_step1} (variables: project_url={project_url})
2. {i18n:init_iteration_step2}
3. {i18n:init_iteration_step3}
4. {i18n:init_iteration_step4}
5. {i18n:init_iteration_step5}

{i18n:init_iteration_after_creation}
```

If the user selects "set up later", proceed to Phase 4 with `iteration.enabled: false`.

---

## Phase 4: Template Generation

### 4.1 Generate rite-config.yml

#### 4.1.1 Check for Existing Configuration

Read `rite-config.yml` in the project root with the Read tool.

**If the file does not exist** (Read tool returns an error) → Proceed to 4.1.2 (new generation).

**If the file exists** → Check `schema_version` field:

1. Read `schema_version` value from the existing file. If missing, treat as v1.
2. Read `schema_version` from template config (`{plugin_root}/templates/config/rite-config.yml`). If missing, treat as v1.
3. If existing `schema_version` < template `schema_version`, display: `rite-config.yml のスキーマが古くなっています (v{current} → v{latest})。/rite:init --upgrade でアップグレードできます。`

Then compare the existing values with the values detected in Phases 2-3.5. Identify fields that differ:

| Field | Existing Value | Detected Value | Differs? |
|-------|---------------|----------------|----------|
| `project.type` | (from file) | (from Phase 2) | |
| `github.projects.project_number` | (from file) | (from Phase 3) | |
| `github.projects.owner` | (from file) | (from Phase 1.3) | |
| `iteration.enabled` | (from file) | (from Phase 3.5) | |
| `iteration.field_name` | (from file) | (from Phase 3.5) | |

**If no differences** → Display "{i18n:init_config_up_to_date}" and proceed to 4.2.

**If differences exist** → Show the diff table above and ask with AskUserQuestion:

```
rite-config.yml は既に存在します。以下の項目が検出値と異なります:
オプション:
- 検出値で更新する（推奨）: 差分のある項目のみ更新し、その他の設定（branch, commit, language 等）は保持します
- スキップ: 既存の rite-config.yml をそのまま使用します
- 上書き: 全項目をデフォルト値で再生成します（branch, commit, review, commands, notifications 等の全カスタマイズが失われます）
```

- **Update**: Use the Edit tool to update only the differing fields. Preserve all other existing values (branch patterns, commit style, custom settings, comments, etc.).
- **Skip**: Proceed to 4.2 without changes.
- **Overwrite**: Proceed to 4.1.2 (full generation, replacing existing file).

#### 4.1.2 New Generation (Template-Based)

Generate `rite-config.yml` from the template config file.

**Step 1**: Read the template config with the Read tool:

```
{plugin_root}/templates/config/rite-config.yml
```

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script).

**Step 2**: Extract content up to the Advanced marker (`# --- Advanced`). Everything after (and including) this line is **omitted** during new generation.

**Step 3**: Replace placeholders in the extracted content with detected values:

| Placeholder/Field | Replacement Value |
|-------------------|-------------------|
| `project.type` | `{detected-type}` from Phase 2 |
| `github.projects.project_number` | `{project-number}` from Phase 3 (null if not detected) |
| `github.projects.owner` | `"{owner}"` from Phase 1.3 (null if not detected) |
| `iteration.enabled` | `{iteration-enabled}` from Phase 3.5 |
| `iteration.field_name` | `"{iteration-field-name}"` from Phase 3.5 |

**Step 4**: Write the result to `rite-config.yml` in the project root using the Write tool.

#### 4.1.3 Upgrade Existing Configuration

> This phase is executed when `--upgrade` is specified. It upgrades an existing `rite-config.yml` to the latest schema version while preserving user-customized values.

**Step 1: Read current config and template**

Read both files with the Read tool:
- `rite-config.yml` (project root)
- `{plugin_root}/templates/config/rite-config.yml` (template)

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script).

**Step 2: Check schema versions**

- Current: Read `schema_version` from existing file. If missing, treat as v1.
- Latest: Read `schema_version` from template. If missing, treat as v1.

If current >= latest: Display "{i18n:init_upgrade_up_to_date}" and exit (no upgrade needed).

**Step 3: Create backup**

```bash
cp rite-config.yml "rite-config.yml.bak.$(date +%Y%m%d-%H%M%S)"
```

Display "{i18n:init_upgrade_backup_created}".

**Step 4: Identify changes**

Compare current config against the template and classify each key:

| Classification | Action |
|---------------|--------|
| **User-customized value** (project_number, owner, iteration settings, branch.base, language, etc.) | **Preserve** — keep the user's value |
| **Deprecated key** (`project.name`, `commit.style`, `commit.enforce`, `branch.release`, `branch.types`, `version`) | **Remove** — delete from config |
| **Missing section** (review.debate, review.fact_check, verification, safety, etc.) | **Add** — insert from template with default values |
| **Advanced section** (tdd, parallel, team, metrics, context_optimization, safety, investigate) | **Add as comments** — insert commented-out with default values |
| **Unknown key** (user-added keys not in template) | **Preserve with warning** — keep but display warning |

**Step 5: Preview and confirm**

Display the changes to the user:

```
{i18n:init_upgrade_diff_preview}

廃止キー削除: {deprecated_keys}
新規セクション追加: {new_sections}
Advanced セクション追加（コメントアウト）: {advanced_sections}
保持される既存設定: {preserved_keys}
```

Ask with `AskUserQuestion`:

```
{i18n:init_upgrade_confirm}
オプション:
- 適用する（推奨）: 上記の変更を適用します
- キャンセル: アップグレードを中止します
```

**Step 6: Apply changes**

If the user confirms:

1. Update `schema_version` to latest value
2. Remove deprecated keys using the Edit tool
3. Add missing sections from the template using the Edit tool
4. Add Advanced sections as comments (prefixed with `#`) using the Edit tool
5. Preserve all user-customized values

Display "{i18n:init_upgrade_applied}".

If the user cancels: Display "{i18n:init_upgrade_cancelled}" and exit.

**MUST requirements**:
- `schema_version` 未設定の config は暗黙的に v1 として扱う
- ユーザーカスタム値（project_number, owner, iteration, branch 等）を保持する
- バックアップ (`rite-config.yml.bak.{timestamp}`) を作成する
- 廃止キー (`project.name`, `commit.style`, `commit.enforce`, `branch.release`, `branch.types`, `version`) を削除する
- Advanced セクションはコメントアウトで追加する
- テンプレートにないユーザー追加キーを削除しない（Unknown key → Preserve with warning）

### 4.2 Check Issue Templates

If `.github/ISSUE_TEMPLATE/` does not exist, show:
```
{i18n:init_issue_template_missing}

{i18n:init_issue_template_suggestion}
```

---

## Phase 4.5: Hook Configuration

> **Placeholder convention**: All `{hooks_dir}` occurrences in fenced code blocks within Phase 4.5 are **templates**, not literal commands. Replace `{hooks_dir}` with the absolute path resolved in Phase 4.5.0 before executing each command via the Bash tool.

### 4.5.0 Resolve Hook Script Directory

Run the following bash command to detect the hook scripts directory. This command assumes CWD is the project root (Claude Code's Bash tool resets CWD to the project root on each invocation):

```bash
if [ -f "plugins/rite/hooks/stop-guard.sh" ]; then
  echo "LOCAL:$(cd plugins/rite/hooks && pwd)"
elif ! command -v jq >/dev/null 2>&1; then
  echo "NOT_FOUND:NO_JQ"
elif [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then
  INSTALL_PATH=$(jq -r '.plugins["rite@rite-marketplace"][0].installPath // empty' \
    "$HOME/.claude/plugins/installed_plugins.json")
  if [ -n "$INSTALL_PATH" ] && [ -f "$INSTALL_PATH/hooks/stop-guard.sh" ]; then
    echo "MARKETPLACE:$INSTALL_PATH/hooks"
  else
    echo "NOT_FOUND:NO_HOOKS"
  fi
else
  echo "NOT_FOUND:NO_HOOKS"
fi
```

- If `LOCAL:<path>` or `MARKETPLACE:<path>` → extract all text after the first `:` (the absolute path) and use it as `{hooks_dir}` for all subsequent phases. Also retain the source type (`LOCAL` or `MARKETPLACE`) for use in the Phase 5 completion report.
- If `NOT_FOUND:NO_JQ` → display warning and **skip the rest of Phase 4.5**:
    ```
    ⚠️ Hook scripts not found. jq is required for hook scripts but was not detected.
    Install jq (https://jqlang.github.io/jq/) to enable hooks.
    Skipping hook registration. Workflow will function normally without hooks.
    ```
- If `NOT_FOUND:NO_HOOKS` → display warning and **skip the rest of Phase 4.5**:
    ```
    ⚠️ Hook scripts not found. Skipping hook registration.
    Workflow will function normally, but auto-stop-guard and state persistence hooks will not be active.
    ```

### 4.5.0.5 Copy-Type Install Detection and Update Guidance

**Condition**: Execute only when Phase 4.5.0 returns `MARKETPLACE`.

**Purpose**: Detect copy-type installations that don't receive automatic updates, compare versions with the latest release, and guide users to update if outdated.

> **Placeholder convention**: Step 1 derives `{marketplace_name}` and `{marketplace_dir}` from `{hooks_dir}`. Replace these placeholders in all subsequent bash blocks before execution, following the same convention as `{hooks_dir}` in Phase 4.5.
>
> **Path note**: `~/.claude/plugins/marketplaces/{marketplace_name}/` is the directory where Claude Code clones marketplace source repositories during plugin installation. This is distinct from `~/.claude/plugins/cache/` (the extracted plugin files used at runtime).

#### Step 1: Determine Install Type

From `{hooks_dir}` (resolved in Phase 4.5.0), derive the marketplace source directory and check its installation type:

```bash
INSTALL_ROOT=$(dirname "{hooks_dir}")
MARKETPLACE_NAME=$(basename "$(dirname "$(dirname "$INSTALL_ROOT")")")
MARKETPLACE_DIR="$HOME/.claude/plugins/marketplaces/$MARKETPLACE_NAME"

if [ -L "$MARKETPLACE_DIR" ]; then
  echo "SYMLINK"
elif [ -d "$MARKETPLACE_DIR/.git" ]; then
  echo "GIT_CLONE"
elif [ -d "$MARKETPLACE_DIR" ]; then
  echo "COPY"
else
  echo "NOT_FOUND"
fi
```

> **Path derivation**: `{hooks_dir}` has the format `.../cache/{marketplace_name}/{plugin_name}/{version}/hooks`. Removing the last component (`hooks`) gives the install root, then navigating two levels up yields a directory whose basename is the marketplace name. This name is used to construct the marketplace source directory path `$HOME/.claude/plugins/marketplaces/{marketplace_name}`.

**Result handling**:
- `SYMLINK` → Display "✅ Symlink インストールを検出（自動更新可能）" and **skip to Phase 4.5.0.2**.
- `GIT_CLONE` → Proceed to Step 2a.
- `COPY` → Proceed to Step 2b.
- `NOT_FOUND` → Display "ℹ️ マーケットプレースソースディレクトリが見つかりません。更新チェックをスキップします。" and **skip to Phase 4.5.0.2**.

#### Step 2a: Git Clone Freshness Check (GIT_CLONE only)

Check if the local clone is behind the remote:

```bash
cd "{marketplace_dir}" && \
  git fetch origin --quiet 2>/dev/null && \
  LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null) && \
  DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p') && \
  DEFAULT_BRANCH=${DEFAULT_BRANCH:-main} && \
  REMOTE_HEAD=$(git rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null) && \
  if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
    echo "UP_TO_DATE"
  else
    BEHIND=$(git rev-list --count "HEAD..origin/$DEFAULT_BRANCH" 2>/dev/null || echo "?")
    echo "BEHIND:$BEHIND"
  fi
```

- `UP_TO_DATE` → Display "✅ プラグインは最新です（git clone）" and **skip to Phase 4.5.0.2**.
- `BEHIND:{n}` → Display:
    ```
    ⚠️ プラグインの更新があります（{n} コミット遅れ）。
    更新するには:
      cd {marketplace_dir} && git pull
      または: claude plugin update rite
    ```
    Continue to Phase 4.5.0.2.
- If `git fetch` fails (network error etc.) → Display "ℹ️ リモートの確認に失敗しました。更新チェックをスキップします。" and **skip to Phase 4.5.0.2**.

#### Step 2b: Version Comparison (COPY only)

Read installed version and attempt to compare with the latest release:

```bash
INSTALLED_VERSION=$(jq -r '.plugins[0].version // empty' \
  "{marketplace_dir}/.claude-plugin/marketplace.json" 2>/dev/null)
OWNER=$(jq -r '.owner.name // empty' \
  "{marketplace_dir}/.claude-plugin/marketplace.json" 2>/dev/null)

echo "INSTALLED:${INSTALLED_VERSION:-unknown}"
echo "OWNER:${OWNER:-unknown}"
```

If `INSTALLED_VERSION` or `OWNER` is empty/unknown → Display the copy-type warning without version comparison (see "Version unknown" below) and **skip to Phase 4.5.0.2**.

Otherwise, attempt to retrieve the latest release version. Try the marketplace name as repo name, then search the owner's repos for a `claude-plugin` topic match:

```bash
LATEST_VERSION=""

# Try 1: marketplace name as repo name ({marketplace_name})
LATEST_VERSION=$(gh release view --repo "$OWNER/{marketplace_name}" \
  --json tagName --jq '.tagName' 2>/dev/null | sed 's/^v//')

# Try 2: search owner's repos for claude-plugin topic
if [ -z "$LATEST_VERSION" ]; then
  REPO_NAME=$(gh api "/search/repositories?q=topic:claude-plugin+user:$OWNER" \
    --jq '.items[0].name // empty' 2>/dev/null)
  if [ -n "$REPO_NAME" ]; then
    LATEST_VERSION=$(gh release view --repo "$OWNER/$REPO_NAME" \
      --json tagName --jq '.tagName' 2>/dev/null | sed 's/^v//')
  fi
fi

echo "LATEST:${LATEST_VERSION:-unknown}"
```

**Display based on comparison** (use string equality check: `[ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]`):

**Version unknown** (latest could not be determined, i.e. `LATEST_VERSION` is empty or "unknown"):
```
⚠️ コピー型インストールを検出しました（symlink ではありません）。
現在のバージョン: v{INSTALLED_VERSION}
最新バージョン: 確認できませんでした

コピー型インストールでは自動更新が反映されません。
プラグインを更新するには:
  claude plugin update rite
```

**Versions match**:
```
✅ コピー型インストールですが、最新バージョンです（v{INSTALLED_VERSION}）。
```

**Versions differ**:
```
⚠️ コピー型インストールを検出しました（symlink ではありません）。
現在のバージョン: v{INSTALLED_VERSION}
最新バージョン: v{LATEST_VERSION}

プラグインを更新するには:
  claude plugin update rite
```

Continue to Phase 4.5.0.1.

### 4.5.0.1 Check for Conflicting Hooks in settings.json

Read `.claude/settings.json` (the project-level, non-local settings file) and check for hooks that may conflict with rite hooks.

**Purpose**: Claude Code executes hooks from both `.claude/settings.json` and `.claude/settings.local.json`. If non-rite hooks exist in `settings.json` for the same events that rite registers (e.g., SessionStart, SessionEnd, PreCompact), they will be executed alongside rite hooks, causing duplicate execution. This check warns the user about such conflicts.

**Check procedure**:

1. Read `.claude/settings.json` with the Read tool. If the file does not exist or has no `.hooks` section (empty `{}` or missing), skip this sub-phase entirely and proceed to Phase 4.5.0.2.
2. For each hook event in `.hooks`, examine all `.hooks.{EventName}[*].hooks[*].command` values.
3. **Exclude** commands containing `rite/hooks/` (these are rite's own hooks, which may be registered here in older installations).
4. Collect remaining (non-rite) hook commands as **conflicting hooks**.

**If conflicting hooks are found**, display:
```
⚠️ .claude/settings.json に既存の hooks が検出されました:
| Hook Event | Command |
|------------|---------|
| {event}    | {command} |

rite は .claude/settings.local.json で hooks を管理します。
settings.json の hooks は rite hooks と二重実行されます。

→ settings.json の hooks セクションを `"hooks": {}` に変更することを推奨します。
```

**If no conflicting hooks are found**, no output is displayed.

**Important**: This check is **advisory only**. Do not modify `.claude/settings.json` automatically. Do not block init execution regardless of the result. Continue to Phase 4.5.0.2 in all cases.

### 4.5.0.2 Native Hook Management Check (hooks.json)

**Purpose**: `hooks.json` が存在する場合、Claude Code はプラグインの hook をネイティブに管理する（`${CLAUDE_PLUGIN_ROOT}` を動的に解決）。この場合、`settings.local.json` への hook 登録は不要であり、バージョン更新時にパスが壊れる原因となる。

**Check procedure**:

```bash
# hooks.json の存在を確認（{hooks_dir} の親ディレクトリに hooks.json があるか）
_hooks_json="{hooks_dir}/hooks.json"
if [ -f "{hooks_dir}/../hooks/hooks.json" ]; then
  _hooks_json="{hooks_dir}/../hooks/hooks.json"
elif [ -f "{hooks_dir}/hooks.json" ]; then
  _hooks_json="{hooks_dir}/hooks.json"
fi
[ -f "$_hooks_json" ] && echo "NATIVE" || echo "LEGACY"
```

**Note**: `{hooks_dir}` は Phase 4.5.0 で解決された hooks ディレクトリの絶対パス。`hooks.json` は通常 `{hooks_dir}/hooks.json` に存在する。

**When `NATIVE` is returned** (hooks.json exists):

1. Display:
   ```
   ✅ hooks.json によるネイティブ hook 管理を検出。settings.local.json の hook 登録をスキップします。
   ```

2. **Clean up stale rite hooks from `settings.local.json`**: Read `.claude/settings.local.json` and remove all hook entries whose command contains `rite/hooks/`. Non-rite hooks must be preserved. If the file does not exist or has no rite hooks, skip this step silently.

   ```bash
   # settings.local.json から rite hook エントリを削除
   _settings_local=".claude/settings.local.json"
   if [ -f "$_settings_local" ] && command -v python3 &>/dev/null; then
     _tmp=$(mktemp "${_settings_local}.XXXXXX" 2>/dev/null) || _tmp=""
     if [ -n "$_tmp" ] && python3 -c '
   import json, sys, re
   settings_path = sys.argv[1]
   out_path = sys.argv[2]
   with open(settings_path, "r") as f:
       data = json.load(f)
   hooks = data.get("hooks", {})
   if not hooks:
       sys.exit(1)
   rite_hook_re = re.compile(r"rite.*?/hooks/")
   changed = False
   for event_name in list(hooks.keys()):
       entries = hooks[event_name]
       if not isinstance(entries, list):
           continue
       new_entries = []
       for entry in entries:
           hook_list = entry.get("hooks", [])
           has_rite = any(rite_hook_re.search(h.get("command", "")) for h in hook_list)
           if has_rite:
               changed = True
           else:
               new_entries.append(entry)
       if new_entries:
           hooks[event_name] = new_entries
       else:
           del hooks[event_name]
   if not changed:
       sys.exit(1)
   with open(out_path, "w") as f:
       json.dump(data, f, indent=2, ensure_ascii=False)
       f.write("\n")
   ' "$_settings_local" "$_tmp" 2>/dev/null; then
       mv "$_tmp" "$_settings_local" 2>/dev/null
       echo "CLEANED"
     else
       rm -f "$_tmp" 2>/dev/null
       echo "NO_RITE_HOOKS"
     fi
   fi
   ```

   - If `CLEANED` → display `ℹ️ settings.local.json からレガシー rite hook エントリを削除しました。`
   - If `NO_RITE_HOOKS` → no output (already clean)

3. Write cleanup marker:
   ```bash
   echo "cleaned" > ".rite-settings-hooks-cleaned" 2>/dev/null || true
   ```

4. **Skip Phase 4.5.1 and Phase 4.5.2** entirely. Proceed directly to **Phase 4.5.3** (chmod).

**When `LEGACY` is returned** (hooks.json does not exist):

Proceed to Phase 4.5.1 (existing flow — validate and register hooks in `settings.local.json`).

### 4.5.1 Check Existing Hook Configuration

> **Note**: This phase is only executed when Phase 4.5.0.2 returned `LEGACY` (hooks.json does not exist).

Read `.claude/settings.local.json` and check for existing hooks section. If the file does not exist, it will be created.

**⚠️ 重要: 4.5.1.1 と 4.5.1.2 は両方とも必ず実行すること。4.5.1.1 で全パスが正常でも 4.5.1.2 は必ず実行する。** 4.5.1.1 は既存フックのパス検証のみを行い、フックイベント自体の欠落は検出しない。4.5.1.2 が必須フックの存在チェックを担当する。

#### 4.5.1.1 Validate Existing Hook Paths

If the file already contains hooks, check each hook command for rite hook patterns:

1. Scan all `.hooks.{EventName}[*].hooks[*].command` values across Stop, PreCompact, PostCompact, SessionStart, SessionEnd, PreToolUse, and PostToolUse events
2. Identify commands containing `rite/hooks/` (this covers both `plugins/rite/hooks/` relative paths and any previous absolute paths)
3. For each matching command, construct the expected full command string `bash {hooks_dir}/{script_name}` (where `{hooks_dir}` is the absolute path resolved in Phase 4.5.0 and `{script_name}` is the filename like `stop-guard.sh`). Compare the existing command string with the expected one
4. If the existing command does NOT match the expected command, mark it as **needs update**

**Note**: Phase 4.5.0 resolves `{hooks_dir}` as an absolute path (via `cd ... && pwd`). If existing hooks use relative paths (e.g., `bash plugins/rite/hooks/stop-guard.sh`), they will not match the absolute path and will be correctly marked for update. This is intentional — converting relative paths to absolute paths is one of the goals of this validation.

**Display when outdated paths are detected** (where `{event}` is the hook event name such as Stop/PreCompact/PostCompact/SessionStart/SessionEnd/PreToolUse, and `{current_cmd}` is the existing command string):
```
⚠️ Outdated rite hook paths detected:
| Hook Event | Current Command | Expected Command |
|------------|----------------|-----------------|
| {event}    | {current_cmd}  | bash {hooks_dir}/{script_name} |

→ Paths will be updated in Phase 4.5.2.
```

#### 4.5.1.2 Check Required Hook Presence

**⚠️ このサブフェーズは 4.5.1.1 の結果に関わらず必ず実行する。** 4.5.1.1 が「全パス正常」と判定しても、フックイベント自体が欠落している可能性がある（例: SessionEnd, PreToolUse が未登録）。

After validating existing hook paths in 4.5.1.1, verify that **all** required rite hooks are registered. This check prevents the scenario where some hooks (e.g., Stop, PreCompact, SessionStart) are correctly configured but others (e.g., SessionEnd, PostCompact) are missing entirely.

**Required hooks**:

| Hook Event | Script | Matcher | Purpose |
|------------|--------|---------|---------|
| Stop | `stop-guard.sh` | `""` | Prevent premature workflow stops |
| PreCompact | `pre-compact.sh` | `""` | Save state before compaction |
| PostCompact | `post-compact.sh` | `""` | Auto-recover workflow after compaction |
| SessionStart | `session-start.sh` | `""` | Re-inject state on startup/resume |
| SessionEnd | `session-end.sh` | `""` | Reset flow state on session end |
| PreToolUse | `pre-tool-bash-guard.sh` | `"Bash"` | Block known-bad Bash command patterns |
| PostToolUse | `post-tool-wm-sync.sh` | `"Bash"` | Auto-create local WM |
| PostToolUse | `context-pressure.sh` | `""` | Context pressure monitoring (#889) |

**Check procedure**:

1. For each required hook event above, check if `.hooks.{EventName}` exists in `.claude/settings.local.json`. If the event is not present, mark it as **missing**.
2. For each required hook event that **exists** in `.hooks`, check if any hook command contains `rite/hooks/{script_name}`. If no matching command is found, mark it as **missing**.
3. Collect all **missing** hook events from steps 1 and 2.

**Note**: If no required hooks are missing, no output is displayed from this sub-phase. The decision is deferred to the combined Decision logic below.

**Display when missing hooks are detected** (`{total_count}` = number of required hooks, currently 8):
```
⚠️ Required rite hooks are missing ({missing_count}/{total_count}):
| Hook Event | Script | Status |
|------------|--------|--------|
| {event}    | {script_name} | ❌ Missing |

→ Missing hooks will be registered in Phase 4.5.2.
```

**Decision logic** (combines 4.5.1.1 and 4.5.1.2 results):

- If **all** rite hook paths match `{hooks_dir}` (from 4.5.1.1) **AND** **no** required hooks are missing (from 4.5.1.2) → display "✅ Hook configuration is up to date" and skip **Phase 4.5.2**, proceeding directly to Phase 4.5.3.
- If **any** hook paths need update (from 4.5.1.1) **OR** **any** required hooks are missing (from 4.5.1.2) → proceed to **Phase 4.5.2** to register/update all hooks.

### 4.5.2 Register rite Hooks

Add the following hooks to `.claude/settings.local.json`:

| Hook Event | Script | Purpose |
|------------|--------|---------|
| Stop | `bash {hooks_dir}/stop-guard.sh` | Prevent premature workflow stops |
| PreCompact | `bash {hooks_dir}/pre-compact.sh` | Save state before compaction |
| PostCompact | `bash {hooks_dir}/post-compact.sh` | Auto-recover workflow after compaction |
| SessionStart | `bash {hooks_dir}/session-start.sh` | Re-inject state on startup/resume |
| PreToolUse (Bash) | `bash {hooks_dir}/pre-tool-bash-guard.sh` | Block known-bad Bash command patterns |
| SessionEnd | `bash {hooks_dir}/session-end.sh` | Reset flow state on session end |
| PostToolUse (Bash) | `bash {hooks_dir}/post-tool-wm-sync.sh` | Auto-create local WM |
| PostToolUse | `bash {hooks_dir}/context-pressure.sh` | Context pressure monitoring (#889) |

**Hook registration format** (merge into existing settings without overwriting other entries):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/stop-guard.sh"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/pre-compact.sh"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/session-start.sh"
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/post-compact.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/pre-tool-bash-guard.sh"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/session-end.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/post-tool-wm-sync.sh"
          }
        ]
      },
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/context-pressure.sh"
          }
        ]
      }
    ]
  }
}
```

**Important**:
- **Non-rite hooks**: If `.claude/settings.local.json` already has hooks that do NOT contain `rite/hooks/` in their command, preserve them as-is. Do not overwrite or remove user-defined hooks.
- **rite hooks (path update)**: If existing hooks contain `rite/hooks/` in their command but use an outdated path (detected in Phase 4.5.1.1), **replace** those hook entries with the updated `{hooks_dir}` path. This ensures re-running `/rite:init` always corrects stale paths.
- **Missing rite hooks**: If any of the required rite hooks (Stop, PreCompact, PostCompact, SessionStart, SessionEnd, PreToolUse, PostToolUse) are not present, add them.
- **Obsolete hooks**: If `post-compact-guard.sh` exists in PreToolUse, **remove** it (replaced by PostCompact `post-compact.sh` in #133).
- **Matcher rules**: `post-tool-wm-sync.sh` and `pre-tool-bash-guard.sh` use `"matcher": "Bash"` to fire only on Bash tool calls. `context-pressure.sh` uses `"matcher": ""` to fire on all tool calls. All other hooks use `"matcher": ""`. When multiple PreToolUse or PostToolUse entries exist (different matchers), they are separate array elements.
- **Permission for WM_SOURCE**: Add `"Bash(WM_SOURCE:*)"` to `.permissions.allow` if not already present. This allows the LLM to execute work memory update commands without prompting (defense-in-depth alongside the PostToolUse hook).

### 4.5.3 Make Scripts Executable

Attempt to set executable permissions regardless of source type (LOCAL or MARKETPLACE):

```bash
chmod +x {hooks_dir}/stop-guard.sh {hooks_dir}/pre-compact.sh {hooks_dir}/post-compact.sh {hooks_dir}/session-start.sh {hooks_dir}/pre-tool-bash-guard.sh {hooks_dir}/session-end.sh {hooks_dir}/post-tool-wm-sync.sh {hooks_dir}/context-pressure.sh
```

If `chmod` fails (e.g., permission denied, read-only filesystem), display a warning and continue:
```
⚠️ Could not set executable permissions on hook scripts.
If hooks fail to run, manually run: chmod +x {hooks_dir}/*.sh
```

### 4.5.4 Verify Hook Scripts

Verify the hook scripts exist and are executable:

```bash
ls -la {hooks_dir}/stop-guard.sh {hooks_dir}/pre-compact.sh {hooks_dir}/post-compact.sh {hooks_dir}/session-start.sh {hooks_dir}/pre-tool-bash-guard.sh {hooks_dir}/session-end.sh {hooks_dir}/post-tool-wm-sync.sh {hooks_dir}/context-pressure.sh
```

If any file is missing or lacks execute permission, display a warning and continue to Phase 5:
```
⚠️ Hook script verification found issues. Hooks may not function correctly.
Missing or non-executable scripts will be skipped at runtime.
```

---

### 4.5.5 Record Installed Version

Write the current plugin version to a marker file for update detection by `session-start.sh`:

```bash
PLUGIN_JSON="{hooks_dir}/../.claude-plugin/plugin.json"
VERSION=$(jq -r '.version' "$PLUGIN_JSON" 2>/dev/null)
if [ -n "$VERSION" ] && [ "$VERSION" != "null" ]; then
  echo "$VERSION" > "{state_root}/.rite-initialized-version"
fi
```

---

## Phase 4.6: Work Memory Directory Setup

Create the local work memory directory:

```bash
mkdir -p .rite-work-memory
chmod 700 .rite-work-memory 2>/dev/null || true
```

Add `.rite-work-memory/` and `.rite-compact-state*` to `.gitignore` if not already present:

```bash
# Check and add entries if missing
for entry in ".rite-work-memory/" ".rite-compact-state" ".rite-compact-state.lockdir/" ".rite-compact-state.tmp.*" ".rite-initialized-version" ".rite-settings-hooks-cleaned"; do
  if ! grep -qF "$entry" .gitignore 2>/dev/null; then
    echo "$entry" >> .gitignore
  fi
done
```

Display: `✅ Work memory directory initialized (.rite-work-memory/)`

---

## Phase 5: Completion Report

### Display Configuration Summary

```
{i18n:init_complete}

## {i18n:init_summary_config}
- {i18n:init_summary_project_type}: {type}
- GitHub Projects: {project-url}
- {i18n:init_summary_iteration}: {iteration-status}
- {i18n:init_summary_config_file}: rite-config.yml
<!-- If hooks were registered in Phase 4.5 (LOCAL or MARKETPLACE detected): -->
- {i18n:init_summary_hooks}
<!-- If hooks were skipped due to NOT_FOUND in Phase 4.5.0: -->
- {i18n:init_summary_hooks_skipped}

## {i18n:init_summary_next_steps}
1. {i18n:init_summary_step1}
2. {i18n:init_summary_step2}
3. {i18n:init_summary_step3}

<!-- Iteration が有効な場合のみ表示 -->
## {i18n:init_summary_sprint_mgmt}
- {i18n:init_summary_sprint_list}
- {i18n:init_summary_sprint_current}
- {i18n:init_summary_sprint_plan}

{i18n:init_summary_workflow_check}

## {i18n:init_summary_view_config}

{i18n:init_summary_view_note}

| {i18n:init_summary_view_name} | {i18n:init_summary_view_layout} | {i18n:init_summary_view_group} | {i18n:init_summary_view_purpose} |
|---------|-----------|-----------|------|
| Kanban | Board | Status | {i18n:init_summary_view_kanban_purpose} |
| Priority | Table | Priority | {i18n:init_summary_view_priority_purpose} |
| Sprint | Board | Iteration | {i18n:init_summary_view_sprint_purpose} |

{i18n:init_summary_view_sprint_note}
```
