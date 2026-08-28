---
name: setup
description: |
  rite workflow の初回セットアップウィザード: rite-config 生成・Projects 連携・Wiki 初期化等を行う。
  /rite:open から programmatic に呼ばれる sub-step、または手動 /rite:setup。汎用の「初期化」
  ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:setup
argument-hint: ""
---

# /rite:setup

Initial setup wizard for rite workflow

---

## Arguments

| Argument | Description |
|----------|-------------|
| `--upgrade` | Upgrade existing rite-config.yml to the latest schema version |

When `--upgrade` is specified, skip to [Phase 4.1.3 (Upgrade)](#413-upgrade-existing-configuration). Otherwise, run the following phases in order.

## Phase 1: Environment Check

### 1.0 Verify Core Dependencies (bash ≥4 / jq / flock)

bash 4+ / jq / flock を検査し、欠落時は OS 別インストール案内を出す。**この検査は non-blocking**（欠落しても `exit 1` しない）。全依存 OK なら 1 行サマリのみ。
rationale: references/rationale.md#dep-check-nonblocking

```bash
# OS 検出（uname -s ベース。テスト時は uname() 関数を定義して shadow 可能）
os=$(uname -s 2>/dev/null || echo "unknown")
case "$os" in
  Darwin) os_kind=macos ;;
  Linux)  os_kind=linux ;;
  MINGW*|MSYS*|CYGWIN*) os_kind=windows ;;
  *) os_kind=unknown ;;
esac

dep_bash=ok; dep_jq=ok; dep_flock=ok

# bash バージョン検査（実行中の bash の BASH_VERSION を基準。テスト時は先頭で
# BASH_VERSION=3.2.57 を注入すれば <4 経路を実際に踏める — BASH_VERSION は再代入可能）
if [ -z "${BASH_VERSION:-}" ]; then
  dep_bash=nonbash
  echo "⚠️ BASH_VERSION が空です（bash 以外で実行されている可能性）。bash 依存検査をスキップします。"
  echo "   rite の hook / スクリプトは bash 実行を前提とします。bash で再実行してください。"
else
  bash_major=${BASH_VERSION%%.*}
  if [ "$bash_major" -lt 4 ] 2>/dev/null; then
    dep_bash=old
    echo "⚠️ bash ${BASH_VERSION} を検出しました。rite の一部スクリプト（pr-review の review-source-resolve.sh 等）は bash 4 以上を必要とします。"
    case "$os_kind" in
      macos)   echo "   インストール: brew install bash（macOS 標準の bash 3.2 は古すぎます）" ;;
      linux)   echo "   インストール: sudo apt install --only-upgrade bash（Debian/Ubuntu）/ sudo dnf upgrade bash（Fedora）" ;;
      windows) echo "   インストール: Git for Windows 同梱の bash（4+）を使うか、winget/scoop で更新してください" ;;
      *)       echo "   インストール: お使いの環境のパッケージマネージャで bash 4+ を導入してください（https://www.gnu.org/software/bash/）" ;;
    esac
  fi
fi

# jq 検査（欠落は ⚠️ 警告 + OS 別案内。案内は本フェーズで 1 回だけ出し、Phase 4.5.0 の
# NO_JQ 経路では繰り返さない — AC-3）
if ! command -v jq >/dev/null 2>&1; then
  dep_jq=missing
  echo "⚠️ jq が見つかりません。rite の hook / スクリプトは JSON 処理に jq を必要とします。"
  case "$os_kind" in
    macos)   echo "   インストール: brew install jq" ;;
    linux)   echo "   インストール: sudo apt install jq（Debian/Ubuntu）/ sudo dnf install jq（Fedora）" ;;
    windows) echo "   インストール: winget install jqlang.jq または scoop install jq" ;;
    *)       echo "   インストール: https://jqlang.github.io/jq/ を参照してください" ;;
  esac
fi

# flock 検査（non-blocking = ℹ️ 情報表示のみ。警告レベルにしない — AC-4）
if ! command -v flock >/dev/null 2>&1; then
  dep_flock=missing
  echo "ℹ️ flock が見つかりません（macOS / Git Bash では標準未同梱）。flow-state のロックは degrade 動作（ロックなし）になりますが、rite の動作は妨げません。"
fi

# 全依存 OK なら 1 行サマリのみ（AC-1）
if [ "$dep_bash" = "ok" ] && [ "$dep_jq" = "ok" ] && [ "$dep_flock" = "ok" ]; then
  echo "✅ 依存検査: bash ${BASH_VERSION%%.*}+ / jq / flock をすべて検出しました（os=$os）"
fi

# 機械可読 marker（data contract として全ケースで emit する。現状どの後続フェーズも機械 parse しない
# — jq 案内の重複排除は Phase 4.5.0 の NO_JQ メッセージが Phase 1.0 を文言で参照して達成する）
echo "[CONTEXT] DEP_CHECK; bash=$dep_bash; jq=$dep_jq; flock=$dep_flock; os=$os_kind"
```

この bash ブロックは **常に exit 0** で終わる。`[CONTEXT] DEP_CHECK` の各フィールド（`bash=ok|old|nonbash` / `jq=ok|missing` / `flock=ok|missing` / `os=macos|linux|windows|unknown`）は全ケースで emit する。欠落があっても 1.1 へ続行する。
rationale: references/rationale.md#dep-check-nonblocking

### 1.1 Verify gh CLI Installation

```bash
gh --version
```

If not installed, show:
```
GitHub CLI (gh) がインストールされていません

インストール手順:
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
gh auth status --active --hostname github.com
```

If not authenticated, use AskUserQuestion to ask whether to authenticate now.

- If the user chooses to authenticate, show the following command and ask them to run it with Claude Code's ！ prefix so the interactive login owns the user's TTY:

  ```text
  ! gh auth login --hostname github.com --web --scopes project
  ```

  If the ！ prefix is unavailable in the current environment, show `gh auth login --hostname github.com --web --scopes project` for execution in another terminal and end setup with instructions to rerun `/rite:setup` after authentication.
- After the user reports that login is complete, run `gh auth status --active --hostname github.com` again. Continue to Phase 1.4 only when it succeeds.
- If verification still fails, show the command output and use AskUserQuestion to offer retrying authentication or stopping setup. On retry, repeat the login guidance and verification above; do not poll in a Bash loop.
- If the user declines authentication, show:

```
GitHub に認証されていません

認証コマンド: `gh auth login --hostname github.com --web --scopes project`
```

  and exit without an error.

If already authenticated, verify that the active token includes the `project` scope:

```bash
gh auth status --hostname github.com --json hosts --jq '[.hosts["github.com"][] | select(.active == true) | .scopes | split(",")[] | ltrimstr(" ")] | any(. == "project")'
```

If the result is not `true`, show `gh auth refresh --hostname github.com -s project` and ask the user to run it (with the ！ prefix when available). After the user reports completion, run `gh auth status --active --hostname github.com` and the scope check again. Continue to Phase 1.4 only when both succeed. If verification fails, show the failure and use AskUserQuestion to offer retrying the refresh or stopping setup; do not poll in a Bash loop.

### 1.4 Retrieve Repository Information

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) — 下記 snippet の `git-remote.sh` 呼び出しで使用する。
rationale: references/rationale.md#plugin-path-before-git-remote

First classify the local repository before attempting GitHub resolution:

```bash
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_initialized=true
  if [ -n "$(git remote -v 2>/dev/null)" ]; then remotes_present=true; else remotes_present=false; fi
else
  git_initialized=false
  remotes_present=false
fi
echo "[CONTEXT] REPO_LOCAL_STATE; git_initialized=$git_initialized; remotes_present=$remotes_present"
```

Route by this marker:

- `git_initialized=false`: use AskUserQuestion to confirm `git init`. If declined, show `GitHub リポジトリではありません` and exit without an error. If approved, run `git init`, verify success, then continue below.
- `git_initialized=true; remotes_present=false`: continue below.
- `remotes_present=true`: skip repository creation entirely and use the existing resolution path below. A remote that cannot be resolved may use an SSH host alias and MUST NOT be treated as an empty repository.

Before creating an initial commit, check for an existing commit:

```bash
git rev-parse --verify HEAD >/dev/null 2>&1
```

If no commit exists, display the number and list of files that `git add -A` would include. Before asking for approval, scan those paths for likely sensitive files (`.env` and `.env.*`, private keys, `*.pem`, `*.p12`, credentials, and token/secret-named files). If any are found, do not stage or commit; show the paths and require the user to exclude or move them before rerunning setup. Never override this gate for a public repository. When the scan is clean, use AskUserQuestion to confirm the exact initial-commit file list. If declined, exit without an error. If approved, run `git add -A` followed by `git commit -m "chore: initial commit"`; stop and show the command error if either operation fails. Do not create a commit when `HEAD` already exists.

When `remotes_present=false`, use AskUserQuestion to collect the owner, repository name (default: current directory name), and exactly one visibility (`public`, `private`, or `internal`). Validate the owner against `^[A-Za-z0-9][A-Za-z0-9-]{0,38}$`, the repository name against `^[A-Za-z0-9._-]+$`, and the visibility against the three-value allowlist. Reject invalid values and ask again without executing a shell command. Map the selected visibility to one fixed flag; do not interpolate arbitrary text as an option. Bind the validated owner and repository name to shell variables and pass `"$owner/$repo_name"` as one argument. Then use a separate AskUserQuestion to confirm the repository creation before running:

```bash
owner="{validated-owner}"
repo_name="{validated-repo-name}"
visibility_flag="{--public|--private|--internal}"
gh repo create "$owner/$repo_name" --source . "$visibility_flag" --remote origin --push
```

The visibility flag is mandatory; never invoke the interactive form. If the command fails, display gh's stderr and probe both `gh repo view "$owner/$repo_name"` and `git remote get-url origin` before choosing recovery:

- If neither repository nor origin exists, the create step failed before side effects. Use AskUserQuestion to offer retrying the create command or stopping.
- If the repository and origin exist, treat this as a partial success in the push step. Resolve `current_branch=$(git branch --show-current)` and fail loudly if it is empty. Use AskUserQuestion to offer retrying only `git push -u origin "$current_branch"` or stopping; never rerun `gh repo create` on this path.
- If only one of repository/origin exists, show the observed state and stop for manual recovery rather than guessing.

For a name collision, resolve `current_branch=$(git branch --show-current)` and the existing repository URL with `gh repo view "$owner/$repo_name" --json url --jq .url`. Fail loudly if either is empty. Then stop after showing these commands with the resolved values; do not execute them automatically:

```text
git remote add origin {resolved-existing-repository-url}
git push -u origin {resolved-current-branch}
```

After successful creation, always display:

```bash
git remote get-url origin
```

If existing remotes in other local repositories or `~/.ssh/config` indicate a GitHub SSH alias, also show an informational `git remote set-url origin git@{alias}:{owner}/{repo-name}.git` example. Do not rewrite the URL automatically.

For an existing remote, or after repository creation succeeds, resolve the repository through the existing SSH-alias-safe path:

```bash
# owner/repo は SSH host alias 環境でも解決できる git-remote.sh を優先し、
# id/url は解決済み repo を明示指定した gh repo view で取得する。
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
if [ -n "$owner" ] && [ -n "$repo" ]; then
  gh repo view "$owner/$repo" --json owner,name,id,url
else
  gh repo view --json owner,name,id,url
fi
```

If this resolution fails while `remotes_present=true`, show `GitHub リポジトリではありません` and exit. Do not propose `gh repo create` on this path.

---

## Phase 3: GitHub Projects Configuration

### 3.1 Detect Existing Projects

```bash
gh project list --owner {owner} --format json
```

### 3.2 Present Options

Select with AskUserQuestion:

オプション:
- 既存の Projects と連携する（リストから選択）
- 新規 Projects を作成する

どちらを選んでも、Project 番号確定後に 3.3.5（`gh project link`）を必ず実行する（既存 Project 選択時は 3.3 をスキップして 3.3.5 へ進む）。

### 3.3 If Creating New

```bash
gh project create --owner {owner} --title "{repo-name}" --format json
```

### 3.3.5 Link Project to Repository (Both Paths)

新規作成（3.3）・既存 Project 選択（3.2）のどちらのパスでも、Project 番号が確定したら必ず実行する。
rationale: references/rationale.md#project-link

```bash
# 冪等: 既にリンク済みでも成功する。失敗しても setup は続行する（non-blocking）
if ! gh project link {project-number} --owner {owner} 2>&1; then
  echo "WARNING: gh project link に失敗しました。Projects のフィールド設定が初回 Issue 作成時に partial になる可能性があります" >&2
  echo "手動で以下を実行してください: gh project link {project-number} --owner {owner} --repo {owner}/{repo-name}" >&2
fi
```

link 失敗（権限不足・API エラー等）は WARNING と上記の手動コマンド案内のみで、setup 全体は停止せず次の Phase へ続行する。

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
Iteration フィールドは GitHub CLI から自動作成できないため、手動で作成する必要があります。

作成手順:
1. GitHub Projects の画面を開く: {project_url}
2. 「+」ボタンをクリックして新規フィールドを追加
3. 「Iteration」を選択
4. フィールド名を設定（推奨: 「Sprint」）
5. 開始日とスプリント期間を設定（推奨: 2週間）

作成後、/rite:setup を再度実行するか、rite-config.yml の iteration.enabled を手動で true に設定してください。
```

If the user selects "set up later", proceed to Phase 4 with `iteration.enabled: false`.

---

## Phase 4: Template Generation

### 4.1 Generate rite-config.yml

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing any steps in Phase 4.1（1.4 / 4.1.1 / 4.1.2 / 4.1.3。通常は 1.4 到達時点で解決済み）。

#### 4.1.1 Check for Existing Configuration

Read `rite-config.yml` in the project root with the Read tool.

**If the file does not exist** (Read tool returns an error) → Proceed to 4.1.2 (new generation).

**If the file exists** → Check `schema_version` field:

1. Read `schema_version` value from the existing file. If missing, treat as v1.
2. Read `schema_version` from template config (`{plugin_root}/templates/config/rite-config.yml`). If missing, treat as v1.
3. If existing `schema_version` < template `schema_version`, display: `rite-config.yml のスキーマが古くなっています (v{current} → v{latest})。/rite:setup --upgrade でアップグレードできます。`

Then compare the existing values with the values detected in Phases 3-3.5. Identify fields that differ:

| Field | Existing Value | Detected Value | Differs? |
|-------|---------------|----------------|----------|
| `github.projects.project_number` | (from file) | (from Phase 3) | |
| `github.projects.owner` | (from file) | (from Phase 1.4) | |
| `iteration.enabled` | (from file) | (from Phase 3.5) | |
| `iteration.field_name` | (from file) | (from Phase 3.5) | |

**If no differences** → Display "rite-config.yml は最新です。スキップします。" and proceed to 4.2.

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

**Step 2**: Extract content up to (and excluding) the line `# --- Advanced (below this line) ---`. Everything after (and including) this line is **omitted** during new generation.

**Step 3**: Replace placeholders in the extracted content with detected values:

| Placeholder/Field | Replacement Value |
|-------------------|-------------------|
| `github.projects.project_number` | `{project-number}` from Phase 3 (null if not detected) |
| `github.projects.owner` | `"{owner}"` from Phase 1.4 (null if not detected) |
| `iteration.enabled` | `{iteration-enabled}` from Phase 3.5 |
| `iteration.field_name` | `"{iteration-field-name}"` from Phase 3.5 |

**Step 4**: Write the result to `rite-config.yml` in the project root using the Write tool.

> **Note on wiki section**: 新規生成は Advanced 境界より上を抽出するだけ。追加 append は不要。
rationale: references/rationale.md#wiki-section-new-gen

#### 4.1.3 Upgrade Existing Configuration

> `--upgrade` 指定時に実行。既存 `rite-config.yml` を最新 schema へ上げ、ユーザーカスタム値は保持する。

**Step 1: Read current config and template**

Display "rite-config.yml のアップグレードを開始します" and "スキーマバージョンを確認しています...".

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) (required when entering via `--upgrade` skip, which bypasses the Phase 4.1 blockquote).

Read both files with the Read tool:
- `rite-config.yml` (project root)
- `{plugin_root}/templates/config/rite-config.yml` (template)

**Step 2: Check schema versions**

- Current: Read `schema_version` from existing file. If missing, treat as v1.
- Latest: Read `schema_version` from template. If missing, treat as v1.

**Branching** (全 drift 追従。**表の実行順序は左から右** — Step 番号順ではなく矢印順):
rationale: references/rationale.md#upgrade-branching

| Condition | Execution order (left → right) |
|-----------|--------------------------------|
| `current < latest` | (1) Step 3 Backup → (2) Step 4 Identify → (3) Step 5 Preview → (4) Step 6 Apply → (5) Step 7 Phase 4.7 |
| `current >= latest` | (1) Step 3 Backup → (2) Step 4 Identify（drift のみ）→ (3) Step 6 Apply（multi_session/新規セクション/欠落サブキー/Wiki の back-add。User-customized 保全・冪等・preview なし）→ (4) Step 7 Phase 4.7 |

両経路とも Step 3 Backup を必ず先に実行する (precondition)。`current >= latest` は Step 5 を挟まず、欠落 active セクション/サブキーのみを冪等に back-add する（User-customized 値と明示的な `enabled: false` は保全）。back-add 対象が皆無なら Step 6 は書き換えず `rite-config.yml は最新です (v{current})` を表示する。Phase 4.7 はそのまま実行（Wiki 初期化済みなら Skill は skip）。
rationale: references/rationale.md#upgrade-branching

**Step 3: Create backup**

```bash
cp rite-config.yml "rite-config.yml.bak.$(date +%Y%m%d-%H%M%S)"
```

Display "バックアップを作成しました: {path}".

**Step 4: Identify changes**

Compare current config against the template and classify each key:

| Classification | Action |
|---------------|--------|
| **User-customized value** (project_number, owner, iteration settings, branch.base, language, etc.) | **Preserve** — keep the user's value |
| **Deprecated key** (`project.name`, `commit.style`, `commit.enforce`, `commit.contextual`, `branch.release`, `branch.types`, `version`) | **Remove** — delete from config |
| **Missing section** — any active top-level section above the `--- Advanced ---` marker (github, iteration, branch, commands, verification, issue, review, etc. — **excluding `wiki:` and `multi_session:`**, which have dedicated rows below) | **Add** — insert the whole section from the template with default values |
| **Missing sub-key** — a key newly added to the template *inside* a section the config already has (e.g., `review.fact_check.verify_internal_likelihood`) | **Add the missing key only** from the template default; **preserve** all existing sibling values (e.g., a customized `review.fact_check.max_claims`). No-op when the key already exists |
| **`multi_session:` section** | **Back-add on --upgrade with `enabled: true`** (default-on). `multi_session:` is declared above the `--- Advanced ---` marker (active). When missing from an existing config, insert the template active block (`enabled: true` + `worktree_base`) so `--upgrade`-ed projects receive the same default-on behavior as new `/rite:setup` generation. If a user's config already has a `multi_session:` block, it is preserved as a User-customized value (no overwrite — **including an explicit `enabled: false`**). Idempotent: no-op when the active section already exists |
| **Advanced section** (parallel, metrics, investigate) | **Add as comments** — insert commented-out with default values |
| **`wiki:` section** | **Step 3/4 は扱わない**。wiki セクションの追加は **Phase 4.1.2 Step 2 (新規生成: template の Advanced 境界より上にある active block が自動コピーされる) および Phase 4.1.3 Step 6 item 7 (Upgrade path: 未存在時に active block として append。`current < latest` / `current >= latest` 両経路で実行) の専権**。template 側にはコメント形式の `# wiki:` ブロックは存在しない (active 位置に移動済み) ため、重複追加経路はない |
| **Unknown key** (user-added keys not in template) | **Preserve with warning** — keep but display warning |

**Unknown key 判定の scope**: Step 4 の "Unknown key" 判定は **template の `# --- Advanced (below this line) ---` 境界より上の active section のみ**を参照する。
rationale: references/rationale.md#unknown-key-scope

**Active top-level sections covered on --upgrade** (drift anchor): `schema_version`, `github`, `iteration`, `branch`, `commands`, `verification`, `issue`, `review`, `language`, `wiki`, `multi_session`, `tdd`, `safety`. Step 4/6 が扱う。**When a new active top-level section is added to the template, add it to this list too** — otherwise the drift test fails and `--upgrade` would silently miss it.

**Active sub-keys covered on --upgrade** (drift anchor。スカラー `schema_version` / `language` は省略):

- `github`: `projects`
- `iteration`: `enabled`, `field_name`, `auto_assign`, `show_in_list`
- `branch`: `base`, `pattern`
- `commands`: `build`, `test`, `lint`
- `verification`: `run_tests_before_pr`, `acceptance_criteria_check`
- `issue`: `auto_decompose_threshold`
- `review`: `min_reviewers`, `max_reviewers`, `criteria`, `loop`, `security_reviewer`, `debate`, `confidence_threshold`, `fact_check`, `scope_assignment`
- `wiki`: `enabled`, `branch_strategy`, `branch_name`, `auto_ingest`, `auto_query`
- `multi_session`: `enabled`, `worktree_base`
- `tdd`: `enabled`
- `safety`: `max_implementation_rounds`, `max_review_cycles`, `time_budget_minutes`, `auto_stop_on_repeated_failure`, `repeated_failure_threshold`

**When a new sub-key is added to an existing template section, add it to the matching row above too** — otherwise the T-12 sub-key drift test fails and `--upgrade` would silently miss it.

**Step 5: Preview and confirm** (`current < latest` 経路のみ。`current >= latest` は Step 5 を挟まない)

Display the changes to the user:

```
以下の変更が適用されます:

廃止キー削除: {deprecated_keys}
新規セクション追加: {new_sections}
サブキー補完: {new_subkeys}
multi_session back-add: {multi_session_status}
Advanced セクション追加（コメントアウト）: {advanced_sections}
保持される既存設定: {preserved_keys}
```

> `{multi_session_status}` は back-add を実行した場合 `enabled: true`、既存ブロックが存在し変更しなかった場合 `（既存のため変更なし）` を表示する。

Ask with `AskUserQuestion`:

```
アップグレードを適用しますか？
オプション:
- 適用する（推奨）: 上記の変更を適用します
- キャンセル: アップグレードを中止します
```

**Step 6: Apply changes**

**Path-dependent application**: On the `current < latest` path, apply all items below after the user confirms in Step 5. On the `current >= latest` short-circuit path (Step 5 skipped), apply **only items 3, 4, 6, 7** — the drift back-add (missing active sections / missing sub-keys / multi_session / wiki) — directly without confirmation. Items 1, 2, 5 は full-upgrade-only。back-add（3, 4, 6, 7）は冪等で User-customized（明示的な `enabled: false` を含む）を保全する。対象が皆無なら config は不変で `rite-config.yml は最新です (v{current})` を表示する。
rationale: references/rationale.md#upgrade-apply-ssot

Apply the following:

1. Update `schema_version` to latest value
2. Remove deprecated keys using the Edit tool. Display "廃止キーを削除しました: {keys}".
3. Add missing sections from the template using the Edit tool. Display "新しいセクションを追加しました: {sections}".
4. **Merge missing sub-keys**: for each active section already present in the config, compare its keys against the template section and add **only the missing sub-keys** (with their template default values) using the Edit tool, preserving every existing sibling value. No-op for keys already present (idempotent). Display "サブキーを補完しました: {section.key, ...}" only when at least one key was added.
5. Add Advanced sections as comments (prefixed with `#`) using the Edit tool
6. **If `multi_session:` section is absent**: append the active `multi_session:` block from the template (`enabled: true` + `worktree_base`) so `--upgrade`-ed projects get the same default-on session-worktree behavior as new generation.

   **Block source (SSOT)**: Read `{plugin_root}/templates/config/rite-config.yml` and extract the active `multi_session:` block (the `multi_session:` key line through its last sub-key, above the `# --- Advanced (below this line) ---` marker)。本文にリテラルを複製しない。
rationale: references/rationale.md#upgrade-apply-ssot

   **Idempotency guard**: Before inserting, Grep `^multi_session:` (excluding comment lines starting with `#`) in the project's `rite-config.yml`. If an active section already exists, skip the Edit entirely (no-op) — this preserves a user's existing block, **including an explicit `enabled: false`** (never overwrite `enabled`).

   **Anchor selection**: insert immediately before the `# --- Advanced (below this line) ---` marker line (`old_string` = marker line, `new_string` = multi_session block + `\n\n` + marker line). If the Advanced marker is absent (user-trimmed config), append after the last top-level active key. Display `rite-config.yml に multi_session セクションを追加しました（active, enabled: true）。` only when the Edit actually ran.
7. **If `wiki:` section is absent**: append the active `wiki:` block from the template (single source of truth) so Phase 4.7 can auto-initialize Wiki.

   **Wiki block source (SSOT)**: Read `{plugin_root}/templates/config/rite-config.yml` and extract the block from `# Wiki settings` through the end of the `wiki:` section (the lines above the `# --- Advanced (below this line) ---` marker)。本文にリテラルを複製しない。
rationale: references/rationale.md#upgrade-apply-ssot

   **Idempotency guard**: Before inserting, Grep `^wiki:` (excluding comment lines starting with `#`) in the project's `rite-config.yml`. If an active section already exists, skip the Edit entirely (no-op).

   **Anchor selection**:
   - **Primary anchor**: the `language:` line in `rite-config.yml`. This is unique in the default template and provides a stable insertion point.
   - **Fallback anchor** (if `language:` line is absent due to user customization): the `# --- Advanced (below this line) ---` boundary marker line. Insert the wiki block **immediately before** this marker (`old_string` = marker line, `new_string` = wiki block + `\n\n` + marker line). If the Advanced marker is also absent, use the last top-level active key (line starting with `[a-z]` followed by `:`) before any comment-only tail region.
   - **NOT tail-based**: do not anchor to the last non-empty line of the file。
rationale: references/rationale.md#upgrade-apply-ssot

   **Edit action**:
   - `old_string` = the anchor line exactly as read (preserving trailing whitespace)
   - `new_string` = anchor line + `\n\n` + extracted wiki block
   (For the Advanced-marker fallback, swap: `new_string` = wiki block + `\n\n` + marker line)

   Display `rite-config.yml に wiki セクションを追加しました（active）。` only when the Edit actually ran (skip the message on idempotency no-op).
8. Preserve all user-customized values

Display "rite-config.yml をアップグレードしました (v{current} → v{latest})".

**Step 7: Run Phase 4.7 and display status**

Step 7 has two sub-steps:

**Step 7a: Invoke Phase 4.7**

Execute [Phase 4.7: Wiki Initialization](#phase-47-wiki-initialization-491) to bring existing users up to Wiki-initialized state. This is non-blocking; Phase 4.7 failure does not affect `--upgrade` success.

Phase 4.7 内部の「次のステップ」は **Step 7b へ戻る**（7a への再入ではない）。
rationale: references/rationale.md#upgrade-step7

**Step 7b: Display status line and exit**

After Phase 4.7.1/4.7.2/4.7.4 returns control to Step 7, display a Wiki status line selected based on the `wiki_status` value in LLM context, using the same explicit if/else mapping as Phase 5 (select exactly one literal below; do not construct the message dynamically from `wiki_status`):

- If `wiki_status == "initialized"` → `Wiki: 初期化完了`
- Else if `wiki_status == "already_initialized"` → `Wiki: 既に初期化済み`
- Else if `wiki_status == "skipped_disabled"` → `Wiki: スキップ（無効）`
- Else if `wiki_status == "failed"` → `Wiki: 失敗`

Before exiting, execute [Phase 4.8: Sandbox Write-Allowlist 自動設定](#phase-48-sandbox-write-allowlist-自動設定multi_session-有効時1896--1942) and then [Phase 4.9: SSH Host Alias Remote の Sandbox 事前案内](#phase-49-ssh-host-alias-remote-の-sandbox-事前案内1907) (both non-blocking, each self-gated — invoke unconditionally). Then display the status line and exit.
rationale: references/rationale.md#upgrade-step7

If the user cancels: Display "アップグレードをキャンセルしました" and exit.

**MUST requirements**: Step 4 分類表が SoT。`schema_version` 欠落は v1。Backup 必須。Unknown key は削除しない。

### 4.2 Check Issue Templates

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version), then detect each missing GitHub template individually:

```bash
missing_templates=""
for relative_path in \
  "ISSUE_TEMPLATE/bug_report.md" \
  "ISSUE_TEMPLATE/feature_request.md" \
  "ISSUE_TEMPLATE/config.yml" \
  "PULL_REQUEST_TEMPLATE.md"
do
  destination_path=".github/$relative_path"
  { [ -e "$destination_path" ] || [ -L "$destination_path" ]; } || missing_templates="${missing_templates}${missing_templates:+,}$relative_path"
done

if [ -n "$missing_templates" ]; then
  echo "[CONTEXT] GITHUB_TEMPLATES=missing; files=$missing_templates"
else
  echo "[CONTEXT] GITHUB_TEMPLATES=complete"
fi
```

- `GITHUB_TEMPLATES=complete`: generate nothing and continue to Phase 4.5.
- `GITHUB_TEMPLATES=missing`: show the missing file list and use AskUserQuestion with exactly two choices: `生成する` / `スキップ`.
  - If the user chooses `スキップ`, generate nothing and continue to Phase 4.5.
  - If the user chooses `生成する`, copy only the missing files from the plugin's `templates/github/` SoT with the following Bash block. Replace `{plugin_root}` with the resolved absolute path before execution; do not reproduce template bodies in this skill.

```bash
template_source_root="{plugin_root}/templates/github"
project_root=$(pwd -P)

if [ -L ".github" ] || [ -L ".github/ISSUE_TEMPLATE" ]; then
  echo "WARNING: GitHub template generation skipped because .github path contains a symbolic link" >&2
else

for relative_path in \
  "ISSUE_TEMPLATE/bug_report.md" \
  "ISSUE_TEMPLATE/feature_request.md" \
  "ISSUE_TEMPLATE/config.yml" \
  "PULL_REQUEST_TEMPLATE.md"
do
  source_path="$template_source_root/$relative_path"
  destination_path=".github/$relative_path"

  # Re-check immediately before copying so an existing user file is never overwritten.
  if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
    echo "SKIP: existing $destination_path"
    continue
  fi
  if [ ! -f "$source_path" ]; then
    echo "WARNING: GitHub template source not found: $source_path" >&2
    continue
  fi
  if ! mkdir -p "$(dirname "$destination_path")"; then
    echo "WARNING: GitHub template directory could not be created: $(dirname "$destination_path")" >&2
    continue
  fi
  destination_parent=$(cd "$(dirname "$destination_path")" 2>/dev/null && pwd -P) || destination_parent=""
  case "$destination_parent/" in
    "$project_root/"*) ;;
    *) echo "WARNING: GitHub template destination escapes project root: $destination_path" >&2; continue ;;
  esac
  temp_path=$(mktemp "$destination_parent/.rite-github-template-XXXXXX") || {
    echo "WARNING: GitHub template temporary file could not be created: $destination_path" >&2
    continue
  }
  # Hard-link publication is atomic and no-clobber: ln fails if a competing entry appeared.
  if cp "$source_path" "$temp_path" && ln "$temp_path" "$destination_path"; then
    rm -f "$temp_path"
    echo "CREATED: $destination_path"
  else
    rm -f "$temp_path"
    echo "WARNING: GitHub template could not be written: $destination_path" >&2
  fi
done
fi
```

SoT 欠落・ディレクトリ作成失敗・copy 失敗はすべて non-blocking。既存 destination は不変のまま Phase 4.5 へ続行する。

---

## Phase 4.5: Hook Configuration

> **Placeholder convention**: All `{hooks_dir}` occurrences in fenced code blocks within Phase 4.5 are **templates**, not literal commands. Replace `{hooks_dir}` with the absolute path resolved in Phase 4.5.0 before executing each command via the Bash tool.

> **rite hook command の判定基準 (SoT)**: command path 中で `rite` が **hooks ディレクトリ直上の完全な path segment** である場合のみ（間に version segment を 1 個まで許容）。`…/rite/hooks/` と `…/rite-marketplace/rite/<version>/hooks/` がマッチ。`favorite/hooks/`・`prerite/hooks/`・`rite-something/hooks/` はマッチしない。正規表現の単一定義は `scripts/settings-local-rite-hook-cleanup.py` の `RITE_HOOK_RE`（`(?:^|/)rite/(?:[^/]+/)?hooks/`）。本ドキュメントの **「rite hook command」** はすべてこの基準。substring `rite/hooks/` 一致は使わない。
rationale: references/rationale.md#rite-hook-command

### 4.5.0 Resolve Hook Script Directory

次の bash で hook scripts ディレクトリを検出する。CWD はプロジェクト root（Bash tool は呼び出しごとに root へ戻す）:

```bash
if [ -f "plugins/rite/hooks/pre-compact.sh" ]; then
  echo "LOCAL:$(cd plugins/rite/hooks && pwd)"
elif ! command -v jq >/dev/null 2>&1; then
  echo "NOT_FOUND:NO_JQ"
elif [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then
  INSTALL_PATH=$(jq -r '.plugins["rite@rite-marketplace"][0].installPath // empty' \
    "$HOME/.claude/plugins/installed_plugins.json")
  # 解決方式間のバージョン照合: 本 block の direct key lookup と、他スキル・hook が使う正準
  # one-liner (plugin-path-resolution.md の rite@* 先頭エントリ) は、installed_plugins.json に
  # 複数の rite@* エントリがあると異なるバージョンのパスを返し、1 セッション内で hooks と
  # skills が別バージョンを参照する混在が silent に進行する。照合失敗・不一致は non-blocking
  # (解決結果は従来どおり direct key を採用し、解決フロー自体は退行させない)
  CANON_PATH=$(jq -r 'limit(1; .plugins | to_entries[] | select(.key | startswith("rite@"))) | .value[0].installPath // empty' \
    "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null) || CANON_PATH=""
  if [ -n "$CANON_PATH" ] && [ -n "$INSTALL_PATH" ] && [ "$CANON_PATH" != "$INSTALL_PATH" ]; then
    echo "WARNING: plugin パスの解決方式間で不一致を検出しました (バージョン混在の可能性)" >&2
    echo "  direct key lookup (.plugins[\"rite@rite-marketplace\"][0]): $INSTALL_PATH" >&2
    echo "  正準 one-liner (rite@* 先頭エントリ): $CANON_PATH" >&2
    echo "  影響: hooks は前者、他スキル・hook の plugin_root 解決は後者を参照するため、バージョン間で" >&2
    echo "        sentinel / スキーマ契約が変わると追跡困難な drift になります" >&2
    echo "  対処: Claude Code を再起動して plugin キャッシュを更新し、/rite:setup を再実行してください" >&2
  fi
  if [ -n "$INSTALL_PATH" ] && [ -f "$INSTALL_PATH/hooks/pre-compact.sh" ]; then
    echo "MARKETPLACE:$INSTALL_PATH/hooks"
  else
    echo "NOT_FOUND:NO_HOOKS"
  fi
else
  echo "NOT_FOUND:NO_HOOKS"
fi
```

- If `LOCAL:<path>` or `MARKETPLACE:<path>` → extract all text after the first `:` (the absolute path) and use it as `{hooks_dir}` for all subsequent phases. Also retain the source type (`LOCAL` or `MARKETPLACE`) for use in the Phase 5 completion report.
rationale: references/rationale.md#plugin-path-mismatch
- If `NOT_FOUND:NO_JQ` → display warning and **skip the rest of Phase 4.5**（jq 案内は Phase 1.0 で既出 — 繰り返さない）:
    ```
    ⚠️ Hook scripts not found. jq was not detected, so hook registration is skipped.
    (See the Phase 1.0 dependency check above for jq installation guidance.)
    Workflow will function normally without hooks.
    ```
- If `NOT_FOUND:NO_HOOKS` → display warning and **skip the rest of Phase 4.5**:
    ```
    ⚠️ Hook scripts not found. Skipping hook registration.
    Workflow will function normally, but state persistence hooks will not be active.
    ```

### 4.5.0.5 Copy-Type Install Detection and Update Guidance

**Condition**: Execute only when Phase 4.5.0 returns `MARKETPLACE`.

**Purpose**: copy 型インストール（自動更新なし）を検出し、最新リリースと版を比較して更新を案内する。
rationale: references/rationale.md#copy-type-install

> **Placeholder convention**: Step 1 が `{hooks_dir}` から `{marketplace_name}` / `{marketplace_dir}` を導出する。以降の bash では Phase 4.5 の `{hooks_dir}` と同じく実行前に置換する。

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

> **Path derivation**: `{hooks_dir}` = `.../cache/{marketplace_name}/{plugin_name}/{version}/hooks`。末尾 `hooks` を除き 2 階層上が marketplace 名。
rationale: references/rationale.md#copy-type-install

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

**Purpose**: `settings.json` の非-rite hook と rite hook の二重実行を警告する（advisory only）。
rationale: references/rationale.md#settings-json-conflict

**Check procedure**:

1. Read `.claude/settings.json` with the Read tool. If the file does not exist or has no `.hooks` section (empty `{}` or missing), skip this sub-phase entirely and proceed to Phase 4.5.0.2.
2. For each hook event in `.hooks`, examine all `.hooks.{EventName}[*].hooks[*].command` values.
3. **Exclude** **rite hook commands** (per the 判定基準 above — `rite` as a full path segment above the hooks dir; these are rite's own hooks, which may be registered here in older installations). Look-alikes such as `favorite/hooks/` are **not** excluded — they are genuine non-rite hooks and must be reported as conflicts.
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

**Important**: **advisory only**。`.claude/settings.json` は自動変更しない。結果に依らず init を止めず 4.5.0.2 へ進む。

### 4.5.0.2 Native Hook Management Check (hooks.json)

**Purpose**: `hooks.json` があるときは `settings.local.json` への hook 登録をスキップする。
rationale: references/rationale.md#native-hooks-json

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

**Note**: `{hooks_dir}` は Phase 4.5.0 の絶対パス。`hooks.json` は通常 `{hooks_dir}/hooks.json`。

**When `NATIVE` is returned** (hooks.json exists):

1. Display:
   ```
   ✅ hooks.json によるネイティブ hook 管理を検出。settings.local.json の hook 登録をスキップします。
   ```

2. **Clean up stale rite hooks from `settings.local.json`**: Read `.claude/settings.local.json` and remove all hook entries whose command is a **rite hook command** (per the 判定基準 above; the helper below is a `.sh` wrapper that enforces this via the `RITE_HOOK_RE` defined in `settings-local-rite-hook-cleanup.py`). Non-rite hooks — including look-alikes such as `favorite/hooks/` — must be preserved. If the file does not exist or has no rite hooks, skip this step silently.

   ```bash
   # settings.local.json から rite hook エントリを削除 (python3 guard・atomic write・JSON 変換は helper に委譲)
   bash "{hooks_dir}/scripts/settings-local-rite-hook-cleanup.sh" ".claude/settings.local.json"
   ```

   > **Helper contract**: 実際に除去したときのみ `CLEANED`。それ以外の安全側は `NO_RITE_HOOKS`。**mv 失敗**は `NO_RITE_HOOKS` のまま stderr に `[rite] WARNING: ... mv failed`。
rationale: references/rationale.md#cleanup-helper-contract

   - If `CLEANED` → display `ℹ️ settings.local.json からレガシー rite hook エントリを削除しました。`
   - If `NO_RITE_HOOKS` → no output (no rite hooks removed)

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

**⚠️ 重要: 4.5.1.1 と 4.5.1.2 は両方とも必ず実行すること。4.5.1.1 で全パスが正常でも 4.5.1.2 は必ず実行する。**
rationale: references/rationale.md#hook-path-absolute

#### 4.5.1.1 Validate Existing Hook Paths

If the file already contains hooks, check each hook command for rite hook patterns:

1. Scan all `.hooks.{EventName}[*].hooks[*].command` values across PreCompact, PostCompact, SessionStart, SessionEnd, PreToolUse, and PostToolUse events
2. Identify **rite hook commands** (per the 判定基準 above — `rite` as a full path segment above the hooks dir; this covers both `plugins/rite/hooks/` relative paths and any previous absolute paths, while excluding look-alikes such as `favorite/hooks/`)
3. For each matching command, construct the expected full command string `bash {hooks_dir}/{script_name}` (where `{hooks_dir}` is the absolute path resolved in Phase 4.5.0 and `{script_name}` is the filename like `pre-tool-bash-guard.sh`). Compare the existing command string with the expected one
4. If the existing command does NOT match the expected command, mark it as **needs update**

**Note**: 既存 hook が相対パスなら絶対パスと一致せず更新対象になる（意図どおり）。
rationale: references/rationale.md#hook-path-absolute

**Display when outdated paths are detected** (where `{event}` is the hook event name such as PreCompact/PostCompact/SessionStart/SessionEnd/PreToolUse, and `{current_cmd}` is the existing command string):
```
⚠️ Outdated rite hook paths detected:
| Hook Event | Current Command | Expected Command |
|------------|----------------|-----------------|
| {event}    | {current_cmd}  | bash {hooks_dir}/{script_name} |

→ Paths will be updated in Phase 4.5.2.
```

#### 4.5.1.2 Check Required Hook Presence

必須 rite hook がすべて登録されていることを確認する（4.5.1.1 の結果に関わらず実行）。

**Required hooks**:

| Hook Event | Script | Matcher | Purpose |
|------------|--------|---------|---------|
| PreCompact | `pre-compact.sh` | `""` | Save state before compaction |
| PostCompact | `post-compact.sh` | `""` | Auto-recover workflow after compaction |
| SessionStart | `session-start.sh` | `""` | Re-inject state on startup/resume |
| SessionEnd | `session-end.sh` | `""` | Reset flow state on session end |
| PreToolUse | `pre-tool-bash-guard.sh` | `"Bash"` | Block known-bad Bash command patterns |
| PostToolUse | `post-tool-wm-sync.sh` | `"Bash"` | Auto-create local WM |
| PostToolUse | `scripts/bang-backtick-edit-hook.sh` | `"Edit\|Write\|MultiEdit"` | Block bang-backtick adjacency that bash would interpret as history expansion |

**Check procedure**:

1. For each required hook event above, check if `.hooks.{EventName}` exists in `.claude/settings.local.json`. If the event is not present, mark it as **missing**.
2. For each required hook event that **exists** in `.hooks`, check if any hook command is a **rite hook command** (per the 判定基準 above) ending in `{script_name}`. If no matching command is found, mark it as **missing**.
3. Collect all **missing** hook events from steps 1 and 2.

**Note**: 欠落がなければ本サブフェーズは無出力。判定は下記 Decision logic。

**Display when missing hooks are detected** (`{total_count}` = number of required hooks, currently 7):
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
| PreCompact | `bash {hooks_dir}/pre-compact.sh` | Save state before compaction |
| PostCompact | `bash {hooks_dir}/post-compact.sh` | Auto-recover workflow after compaction |
| SessionStart | `bash {hooks_dir}/session-start.sh` | Re-inject state on startup/resume |
| PreToolUse (Bash) | `bash {hooks_dir}/pre-tool-bash-guard.sh` | Block known-bad Bash command patterns |
| SessionEnd | `bash {hooks_dir}/session-end.sh` | Reset flow state on session end |
| PostToolUse (Bash) | `bash {hooks_dir}/post-tool-wm-sync.sh` | Auto-create local WM |
| PostToolUse (Edit\|Write\|MultiEdit) | `bash {hooks_dir}/scripts/bang-backtick-edit-hook.sh` | Block bang-backtick adjacency that bash would interpret as history expansion |

**Hook registration format** (merge into existing settings without overwriting other entries):

```json
{
  "hooks": {
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
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash {hooks_dir}/scripts/bang-backtick-edit-hook.sh"
          }
        ]
      }
    ]
  }
}
```

**Important**:
- **Non-rite hooks**: If `.claude/settings.local.json` already has hooks whose command is NOT a **rite hook command** (per the 判定基準 above — this includes look-alikes such as `favorite/hooks/`), preserve them as-is. Do not overwrite or remove user-defined hooks.
- **rite hooks (path update)**: outdated **rite hook commands**（4.5.1.1）は `{hooks_dir}` パスへ **replace**。
- **Missing rite hooks**: 必須 rite hook が無ければ追加。PostToolUse は 2 matcher（`Bash` と `Edit|Write|MultiEdit`）が共存必須。
- **Obsolete hooks**: `post-compact-guard.sh` (PreToolUse) または `context-pressure.sh` (PostToolUse) があれば **remove**。
- **Matcher rules**: `post-tool-wm-sync.sh` / `pre-tool-bash-guard.sh` は `"matcher": "Bash"`。`scripts/bang-backtick-edit-hook.sh` は `"matcher": "Edit|Write|MultiEdit"`。他は `"matcher": ""`。
- **Permission for WM_SOURCE**: 未設定なら `.permissions.allow` へ `"Bash(WM_SOURCE:*)"` を追加。

### 4.5.3 Make Scripts Executable

Attempt to set executable permissions regardless of source type (LOCAL or MARKETPLACE):

```bash
chmod +x {hooks_dir}/pre-compact.sh {hooks_dir}/post-compact.sh {hooks_dir}/session-start.sh {hooks_dir}/pre-tool-bash-guard.sh {hooks_dir}/session-end.sh {hooks_dir}/post-tool-wm-sync.sh {hooks_dir}/scripts/bang-backtick-edit-hook.sh
```

If `chmod` fails (e.g., permission denied, read-only filesystem), display a warning and continue:
```
⚠️ Could not set executable permissions on hook scripts.
If hooks fail to run, manually run: chmod +x {hooks_dir}/*.sh
```

### 4.5.4 Verify Hook Scripts

Verify the hook scripts exist and are executable:

```bash
ls -la {hooks_dir}/pre-compact.sh {hooks_dir}/post-compact.sh {hooks_dir}/session-start.sh {hooks_dir}/pre-tool-bash-guard.sh {hooks_dir}/session-end.sh {hooks_dir}/post-tool-wm-sync.sh
```

If any file is missing or lacks execute permission, display a warning and continue to Phase 5:
```
⚠️ Hook script verification found issues. Hooks may not function correctly.
Missing or non-executable scripts will be skipped at runtime.
```

---

### 4.5.5 Record Installed Version

現在の plugin 版を marker ファイルへ書く（`session-start.sh` の更新検出用）:

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

# .rite/ 配下のディレクトリエントリは実効判定でゲートする: 既に `.rite/` 広域ルール等で
# 実効的に ignore されている場合は書かない（親ルールに包含される到達不能な行を作らない）。
# 未カバーのときのみ追記する（gitignore-health-check.sh の probe と同じ check-ignore 方式）。
# `.rite/review-results/` は非実測指摘の `description` / `suggestion` 全文を持つ。マージ後も
# `/rite:cleanup` が `archive/` へ退避して残す設計 (記録コメントはポインタと降格理由しか載せないため) なので、
# ignore されていないと脆弱性の詳細が `git add -A` で公開リポジトリへ恒久 commit されうる。
# `.rite/state/` は nb-sweep-done / run-since pin 等の skip 権威ファイルを持つ。
for dir_entry in ".rite/sessions/" ".rite/worktrees/" ".rite/review-results/" ".rite/state/"; do
  if ! git check-ignore -q "${dir_entry}.rite-lint-probe" 2>/dev/null; then
    echo "$dir_entry" >> .gitignore
  fi
done
```

Display: `✅ Work memory directory initialized (.rite-work-memory/)`

---

## Phase 4.7: Wiki Initialization

Wiki を自動初期化する（手動 `/rite:wiki-init` 不要）。新規は Phase 4.6 の後、`--upgrade` は Phase 4.1.3 Apply の後。

> **Non-blocking contract**: Phase 4.7 failure (Skill 呼び出し失敗を含む) MUST NOT abort `/rite:setup`。失敗時は警告を出して Phase 5 へ。Wiki 状態は完了レポートで必ず報告する。
rationale: references/rationale.md#wiki-init-contract

> **Status enum** (consumed by Phase 5 — identifier-compatible values, no whitespace/parens):
>
> | Status value | Meaning |
> |--------------|---------|
> | `initialized` | Newly initialized in this `/rite:setup` invocation |
> | `already_initialized` | Pre-existing Wiki detected and skipped |
> | `skipped_disabled` | `wiki.enabled: false` detected |
> | `failed` | Post-check after Skill invocation found Wiki still uninitialized |

**Retain `wiki_status` as LLM conversational state (NOT a shell variable)**。後続 Bash で `echo $wiki_status` してはならない。Phase 5 / Step 7b は明示 if/else でリテラルを選ぶ。`wiki_status` から文面を動的組み立てしない。
rationale: references/rationale.md#wiki-init-contract

### 4.7.1 Wiki Enabled Check

Read `wiki.enabled` from `rite-config.yml`。Wiki は **opt-out**: セクション欠落 / キー欠落 / 解釈不能 → `true`。`wiki-init` ステップ 1.1 と同じ（typo 検出 WARNING を含む）。
rationale: references/rationale.md#wiki-enabled-sed

```bash
wiki_enabled=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+enabled:' | head -1 | sed 's/#.*//' \
  | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]')
wiki_enabled=$(echo "$wiki_enabled" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *)
    # opt-out default: 未指定 / 不明値は有効として扱う
    _wiki_raw="$wiki_enabled"  # 上書き前に保存 (typo 検出用)
    wiki_enabled="true"
    if [ -z "$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null | grep -E '^[[:space:]]+enabled:')" ]; then
      echo "INFO: wiki.enabled キーが rite-config.yml に見つかりません。デフォルト値 'true' (opt-out) を使用します" >&2
    elif [ -n "$_wiki_raw" ]; then
      echo "WARNING: wiki.enabled の値 '$_wiki_raw' を解釈できません。デフォルト 'true' (opt-out) を使用します。値は true/false/yes/no/1/0 のいずれかを指定してください" >&2
    fi
    unset _wiki_raw
    ;;
esac
echo "wiki_enabled=$wiki_enabled"
```

**When `wiki_enabled=false`**:
- Display `Wiki が無効化されています（wiki.enabled: false）。Phase 4.7 をスキップします。`
- Set `wiki_status=skipped_disabled` (remember in LLM context)
- **Skip the rest of Phase 4.7** and proceed to the next step (new-install: Phase 4.8, then Phase 4.9, then Phase 5 full completion report / `--upgrade`: Phase 4.1.3 Step 7b status-line display and exit)

**When `wiki_enabled=true`**: Display `Wiki の自動初期化を開始します...` and proceed to 4.7.2.

### 4.7.2 Pre-check: Existing Wiki Detection

Determine if Wiki is already initialized. The detection logic depends on `branch_strategy` from `rite-config.yml`:

- `separate_branch` (default): check for `wiki` branch (local or remote)
- `same_branch`: check for `.rite/wiki/SCHEMA.md`

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"

branch_strategy=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_strategy:' | head -1 | sed 's/#.*//' \
  | sed 's/.*branch_strategy:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
branch_strategy="${branch_strategy:-separate_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
     git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
else
  if [ -f ".rite/wiki/SCHEMA.md" ]; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
fi
```

**When `WIKI_INITIALIZED=true`**:
- Display `Wiki は既に初期化されています（検知: {detection}）。スキップします。` (substitute `{detection}` with the matched branch name or file path)
- Set `wiki_status=already_initialized` (remember in LLM context)
- **Skip the rest of Phase 4.7** and proceed to the next step (new-install: Phase 4.8, then Phase 4.9, then Phase 5 / `--upgrade`: Phase 4.1.3 Step 7b status-line display and exit). Do NOT invoke Skill (preserves existing Wiki content per AC-2)

**When `WIKI_INITIALIZED=false`**: Proceed to 4.7.3.

### 4.7.3 Invoke rite:wiki-init Skill

Display `rite:wiki-init を呼び出して Wiki を初期化します...`, then invoke the Skill tool:

```
skill: "rite:wiki-init"
```

Wiki 初期化ロジックをここへ再実装しない — 常に Skill へ委譲する。
rationale: references/rationale.md#wiki-init-delegate

### 4.7.4 Post-check: Confirm Initialization

Skill 復帰後、4.7.2 の **検出部分だけ**（`if [ "$branch_strategy" = "separate_branch" ]; then ... fi`）を再実行する。`branch_strategy` / `wiki_branch` は 4.7.2 の観測値を literal 埋め込みし、`rite-config.yml` を再パースしない。
rationale: references/rationale.md#wiki-init-delegate

**Detection-only re-run** (embed literal values from 4.7.2):

```bash
# LLM: 4.7.2 の bash block 出力から observed した branch_strategy / wiki_branch 値を
#      以下の 2 行に literal に置き換えてから実行すること。プレースホルダー表記のまま
#      実行してはならない (例: branch_strategy="separate_branch"; wiki_branch="wiki")。
branch_strategy="{4.7.2 で取得した値 — literal に置換}"
wiki_branch="{4.7.2 で取得した値 — literal に置換}"

if [ "$branch_strategy" = "separate_branch" ]; then
  if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
     git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
else
  if [ -f ".rite/wiki/SCHEMA.md" ]; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
fi
```

Then:

**When `WIKI_INITIALIZED=true`**:
- Display `✅ Wiki の初期化が完了しました。`
- Set `wiki_status=initialized` (remember in LLM context)

**When `WIKI_INITIALIZED=false`** (Skill invocation failed or did not complete):
- Display `⚠️ Wiki の初期化に失敗しました。/rite:setup 全体は成功扱いで続行します。手動で /rite:wiki-init を実行してください。` (warning only — do NOT exit)
- Set `wiki_status=failed` (remember in LLM context)

**→ Proceed to the next step (new-install: Phase 4.8, then Phase 4.9, then Phase 5 full completion report / `--upgrade`: Phase 4.1.3 Step 7b status-line display and exit). Non-blocking regardless of outcome.**

---

## Phase 4.8: Sandbox Write-Allowlist 自動設定（multi_session 有効時、#1896 / #1942）

`multi_session.enabled: true`（Phase 4.1 で決定済み。新規生成・back-add いずれでも既定 ON）**かつ** Claude 自身の Bash tool 定義（sandbox セクション）が filesystem write 制限付き sandbox で動作している場合のみ実行する。いずれか一方でも該当しない場合は本節を完全に silent skip する（案内・warning 共に一切出さない — AC-3）。

判定は実行コンテキスト（system prompt の sandbox write 許可リスト）を読む。bash では検出できない。

該当時は `state-path-resolve.sh` で main checkout root を解決する（`git rev-parse --show-toplevel` は使わない）:
rationale: references/rationale.md#sandbox-allowlist

```bash
bash {plugin_root}/hooks/state-path-resolve.sh
```

その値を `{repo_root}` として、`.claude/settings.local.json`（`.claude/settings.json` は書き換えない）の `sandbox.filesystem.allowWrite` へ idempotent に自動追記する。先に対象リポジトリの `.gitignore` へ `.claude/settings.local.json` を保証してから書く（Phase 4.6 と同形式）。詳細: [git-worktree-patterns.md の Decision Log](../../references/git-worktree-patterns.md#sandbox-write-allowlist-設定の自動化decision-log)。
rationale: references/rationale.md#sandbox-allowlist

```bash
# .gitignore に .claude/settings.local.json エントリを保証（未カバー時のみ追記）。
# 追記が sandbox 等で失敗しても silent にしない — gitignore_ok=false は下の marker 判定に
# 反映し、settings 側が already_present でも retry させる（旧「案内のみ」フローで settings に
# 手動で path 追加済み・gitignore 未対応のユーザーが、gitignore 追記だけ失敗して
# 未保護のまま放置される回帰を防ぐ）。
gitignore_file="{repo_root}/.gitignore"
gitignore_ok=true
if ! grep -qF ".claude/settings.local.json" "$gitignore_file" 2>/dev/null; then
  echo ".claude/settings.local.json" >> "$gitignore_file" 2>/dev/null || gitignore_ok=false
fi

settings_file="{repo_root}/.claude/settings.local.json"
mkdir -p "$(dirname "$settings_file")"
[ -s "$settings_file" ] || echo '{}' > "$settings_file"

already=$(jq --arg p "{repo_root}" \
  '(.sandbox.filesystem.allowWrite // []) | any(. == $p)' \
  "$settings_file" 2>/dev/null)

if [ "$already" = "true" ] && [ "$gitignore_ok" = "true" ]; then
  echo "[CONTEXT] SANDBOX_ALLOWLIST_AUTOWRITE=already_present; path={repo_root}"
elif jq --arg p "{repo_root}" \
    '.sandbox.filesystem.allowWrite = ((.sandbox.filesystem.allowWrite // []) + [$p] | unique)' \
    "$settings_file" > "$settings_file.tmp" 2>/dev/null && mv "$settings_file.tmp" "$settings_file" \
    && [ "$gitignore_ok" = "true" ]; then
  echo "[CONTEXT] SANDBOX_ALLOWLIST_AUTOWRITE=added; path={repo_root}"
else
  rm -f "$settings_file.tmp"
  echo "[CONTEXT] SANDBOX_ALLOWLIST_AUTOWRITE=failed; path={repo_root}"
fi
```

**sandbox + multi_session では初回から marker `failed` になるのが既定経路**（例外ではない）。**「コマンド自体が失敗したか」を再試行条件にしない** — marker が `failed` なら理由を問わず、当該 bash ブロック全体を一度だけ `dangerouslyDisableSandbox: true` で再実行してよい（確認不要。ブロック全体は冪等）。再実行後も `failed` の場合のみ下記の手動案内へフォールバックする。
rationale: references/rationale.md#sandbox-allowlist

`SANDBOX_ALLOWLIST_AUTOWRITE` marker で分岐する:

| marker | アクション |
|---|---|
| `already_present` | 既に設定済み。何も表示せず Phase 4.9 へ（`--upgrade` の再実行毎にノイズを出さないため） |
| `added` | 下記「自動追加時のメッセージ」を表示して Phase 4.9 へ |
| `failed`（初回） | `dangerouslyDisableSandbox: true` で同一コマンドを一度だけ再試行し、再試行後の marker で再判定 |
| `failed`（`dangerouslyDisableSandbox: true` 再試行後も失敗） | 下記「フォールバック時のメッセージ」（手動案内）を表示して Phase 4.9 へ |

**自動追加時のメッセージ**（原因の詳細本文は複製せず、要約 + 1 行ポインタに留める）。以下のテンプレートをそのまま出力し、要約・言い換え（「〜旨を案内」等の間接話法を含む）をしないこと:

```
ℹ️ sandbox 環境かつ multi_session が有効です。EnterWorktree でセッション worktree へ入場後、
   main checkout 配下（.rite/sessions/ 等）への state 書込が拒否される問題に対応するため、
   main checkout root（{repo_root}）を .claude/settings.local.json の
   sandbox.filesystem.allowWrite へ自動追加しました。
   反映は次回セッションからになる場合があります（現在のセッションで反映されない場合は
   Claude Code を再起動してください）。
   詳細: git-worktree-patterns.md の #1896 対処節を参照
```

**フォールバック時のメッセージ**（自動設定に失敗した場合のみ、従来どおり手動設定を案内）。以下のテンプレートをそのまま出力し、要約・言い換え（「〜旨を案内」等の間接話法を含む）をしないこと:

```
ℹ️ sandbox 環境かつ multi_session が有効です。EnterWorktree でセッション worktree へ入場後、
   main checkout 配下（.rite/sessions/ 等）への state 書込が「読み込み専用ファイルシステムです」
   で拒否されることがあります。
   .claude/settings.local.json への自動設定に失敗したため、手動で以下を追加してください:
   恒久対処: /sandbox コマンド、または settings の sandbox 設定で、write 許可リストへ
     main checkout root の絶対パス（{repo_root}）を追加してください
   詳細: git-worktree-patterns.md の #1896 対処節を参照
```

**→ Proceed to Phase 4.9 (both new-install and `--upgrade` reach Phase 4.9 the same way they reach this Phase).**

## Phase 4.9: SSH Host Alias Remote の Sandbox 事前案内（#1907）

`origin` が SSH host alias 経由（例: `git@github.com-work:owner/repo.git`）**かつ** Claude 自身の Bash tool 定義がネットワーク制限付き sandbox のときのみ表示する。いずれか一方でも該当しない場合は本節を完全に silent skip する（案内・warning 共に一切出さない）。`multi_session` の有無には依存しない。

SSH host alias 判定は bash で行う:
rationale: references/rationale.md#ssh-alias-sandbox

```bash
origin_url=$(git remote get-url origin 2>/dev/null) || origin_url=""
host=""
case "$origin_url" in
  git@*)
    host="${origin_url#git@}"
    host="${host%%:*}"
    ;;
  ssh://*)
    host="${origin_url#ssh://}"
    host="${host#*@}"
    host="${host%%[:/]*}"
    ;;
esac
if [ -n "$host" ] && [ "$host" != "github.com" ]; then
  echo "SSH_ALIAS_REMOTE=yes; host=$host"
else
  echo "SSH_ALIAS_REMOTE=no"
fi
```

sandbox 有効判定は実行コンテキスト（system prompt のネットワーク許可リスト）を読む。settings の `sandbox.enabled` を `jq` で読まない。

`SSH_ALIAS_REMOTE=yes` **かつ** sandbox 有効のときのみ、以下を表示する。詳細は [git-worktree-patterns.md](../../references/git-worktree-patterns.md#ssh-host-alias-経由の-git-pushfetch-が-sandbox-のネットワーク許可リストでブロックされる)。テンプレートをそのまま出力し、要約・言い換え（「〜旨を案内」等の間接話法を含む）をしないこと:
rationale: references/rationale.md#ssh-alias-sandbox

```
ℹ️ sandbox 環境かつ origin remote が SSH host alias（{host}）経由です。sandbox 内からの
   git push / git fetch が「Bad Gateway」で失敗することがあります。
   回避策: 拒否された当該コマンドのみ dangerouslyDisableSandbox: true で再実行してください
     （確認は不要 — 既知の環境制約）。現状これが確実に機能する唯一の回避策です
   （sandbox.excludedCommands は一見恒久策に見えますが、Linux/WSL2 環境ではネットワーク
     sandbox をバイパスできず本問題は解消しません）
   詳細: git-worktree-patterns.md の SSH host alias 対処節を参照
```

settings ファイルへの自動書き込みは行わない（案内のみ、MUST NOT）。

**→ Proceed to Phase 5 (new-install)。`--upgrade` は Step 7b から Phase 4.8 の直後に本 Phase を呼び、Phase 5 なしで exit する。**

## Phase 5: Completion Report

### Display Configuration Summary

```
rite workflow セットアップが完了しました

## 設定内容
- GitHub Projects: {project-url}
- Iteration/スプリント: {iteration-status}
- 設定ファイル: rite-config.yml
<!-- If hooks were registered in Phase 4.5 (LOCAL or MARKETPLACE detected): -->
- Hooks: pre-compact, session-start, session-end (registered)
<!-- If hooks were skipped due to NOT_FOUND in Phase 4.5.0: -->
- Hooks: スキップ（未検出）
<!-- Wiki status line from Phase 4.7. Select exactly one of the following
     based on the wiki_status value retained in LLM context via explicit if/else.
     Do not construct the message dynamically from wiki_status: -->
<!-- If wiki_status == "initialized":         -->
- Wiki: 初期化完了
<!-- Else if wiki_status == "already_initialized": -->
- Wiki: 既に初期化済み
<!-- Else if wiki_status == "skipped_disabled":    -->
- Wiki: スキップ（無効）
<!-- Else if wiki_status == "failed":              -->
- Wiki: 失敗

## 次のステップ
1. /rite:issue-list で既存 Issue を確認
2. /rite:issue-create で新規 Issue を作成
3. /rite:open <番号> で作業開始

<!-- Iteration が有効な場合のみ表示 -->
## Iteration 管理（有効な場合）
- /rite:open 時に現在の active iteration へ自動 assign（`iteration.auto_assign: true`）
- /rite:issue-list --sprint current で現在の iteration の Issue を一覧
- /rite:issue-list --backlog で未割当の Issue を一覧

詳細は /rite:workflow でワークフロー全体を確認できます。

## 推奨ビュー設定（手動）

GitHub Projects のビュー設定は API で自動化できないため、以下の設定を推奨します。Projects 画面右上の「+ New view」から作成してください。

| ビュー名 | レイアウト | グループ化 | 用途 |
|---------|-----------|-----------|------|
| Kanban | Board | Status | タスク進捗の可視化 |
| Priority | Table | Priority | 優先度別の一覧 |
| Sprint | Board | Iteration | スプリント管理（Iteration 有効時） |

※ Sprint ビューは Iteration フィールドが有効な場合のみ使用できます。
```
