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

rite の hook / スクリプト群は bash 4+ / jq に依存し、flow-state のロックに flock を使う。導入時点でこれらを検査し、欠落があれば OS 別のインストール案内を出す（macOS stock bash 3.2 のまま pr-review 系が不可解に失敗する事故の予防）。**この検査は non-blocking**（欠落があっても setup は継続し、`exit 1` しない）。全依存 OK のときは 1 行サマリのみで邪魔をしない。

> **検査基準（Decision D-01）**: bash は「実行中の bash の `BASH_VERSION`」を基準にする。macOS での PATH 解決（Homebrew bash か `/bin/bash` 3.2 か）が環境依存で不確実なため、実行コンテキスト自身を測るのが最も正確。

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

この bash ブロックは **常に exit 0** で終わる（依存欠落を理由に setup を停止しない）。`[CONTEXT] DEP_CHECK` marker の各フィールド（`bash=ok|old|nonbash` / `jq=ok|missing` / `flock=ok|missing` / `os=macos|linux|windows|unknown`）は data contract / observability として全ケースで emit するが、現状どの bash フェーズも機械 parse しない（jq 案内の重複排除は Phase 4.5.0 の NO_JQ メッセージが Phase 1.0 を文言で参照して達成しており、marker の消費には依存しない）。出力を読んだうえで、欠落があってもそのまま 1.1 へ続行する。

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

- If the user chooses to authenticate, show the following command and ask them to run it with Claude Code's `!` prefix so the interactive login owns the user's TTY:

  ```text
  ! gh auth login --hostname github.com --web --scopes project
  ```

  If the `!` prefix is unavailable in the current environment, show `gh auth login --hostname github.com --web --scopes project` for execution in another terminal and end setup with instructions to rerun `/rite:setup` after authentication.
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

If the result is not `true`, show `gh auth refresh --hostname github.com -s project` and ask the user to run it (with `! ` when available). After the user reports completion, run `gh auth status --active --hostname github.com` and the scope check again. Continue to Phase 1.4 only when both succeed. If verification fails, show the failure and use AskUserQuestion to offer retrying the refresh or stopping setup; do not poll in a Bash loop.

### 1.4 Retrieve Repository Information

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) — 下記 snippet の `git-remote.sh` 呼び出しで使用する（未解決のまま実行すると git-remote.sh 経路が silent に失敗し、SSH host alias 環境で fallback の `gh repo view` も失敗する）。

```bash
# owner/repo は SSH host alias 環境でも解決できる git-remote.sh を優先し、
# id/url は解決済み repo を明示指定した gh repo view で取得する（明示指定なら alias 環境でも動く。
# canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe）
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
if [ -n "$owner" ] && [ -n "$repo" ]; then
  gh repo view "$owner/$repo" --json owner,name,id,url
else
  gh repo view --json owner,name,id,url
fi
```

If not a Git repository or not a GitHub repository, show:
```
GitHub リポジトリではありません
```
and exit.

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

新規作成（3.3）・既存 Project 選択（3.2）のどちらのパスでも、Project 番号が確定したら必ず実行する。`gh project link` はリポジトリと Project を関連付け、Issue 作成 helper のフィールド取得 GraphQL クエリ（`repository(owner:, name:) { projectV2(number:) }` ルート、[../../references/graphql-helpers.md](../../references/graphql-helpers.md) 参照）を解決可能にする。link しないままだと初回 `/rite:issue-create` が `project_registration: "partial"` で失敗する。

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

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing any steps in Phase 4.1. This resolved path is used by 1.4 (repository information retrieval — 通常は 1.4 到達時点で解決済み), 4.1.1 (template schema_version read), 4.1.2 (template-based generation), and 4.1.3 (upgrade).

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

> **Note on wiki section**: `templates/config/rite-config.yml` declares the `wiki:` section **above** the `# --- Advanced ---` boundary as an active (non-commented) block. Step 2 (extract content up to the Advanced boundary) therefore includes the active `wiki:` section automatically in the generated `rite-config.yml`. No additional append step is required for new-generation path. The Advanced boundary is the single source of truth for what gets emitted vs commented-out.

#### 4.1.3 Upgrade Existing Configuration

> This phase is executed when `--upgrade` is specified. It upgrades an existing `rite-config.yml` to the latest schema version while preserving user-customized values.

**Step 1: Read current config and template**

Display "rite-config.yml のアップグレードを開始します" and "スキーマバージョンを確認しています...".

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) (required when entering via `--upgrade` skip, which bypasses the Phase 4.1 blockquote).

Read both files with the Read tool:
- `rite-config.yml` (project root)
- `{plugin_root}/templates/config/rite-config.yml` (template)

**Step 2: Check schema versions**

- Current: Read `schema_version` from existing file. If missing, treat as v1.
- Latest: Read `schema_version` from template. If missing, treat as v1.

**Branching** (Wiki follow-through を含む全 drift 追従): schema 同等であってもテンプレートはスキーマ版を bump せずに active セクション/サブキー（`multi_session`・新規セクション・Wiki 等）を獲得し得るため、`current >= latest` 経路でも config に欠落している drift を back-add して最新デフォルトへ追従させる必要がある。以下のとおり分岐する。**表の実行順序は左から右** (Step 番号順ではなく矢印順):

| Condition | Execution order (left → right) |
|-----------|--------------------------------|
| `current < latest` | (1) Step 3 Backup → (2) Step 4 Identify → (3) Step 5 Preview → (4) Step 6 Apply → (5) Step 7 Phase 4.7 |
| `current >= latest` | (1) Step 3 Backup → (2) Step 4 Identify（drift のみ）→ (3) Step 6 Apply（multi_session/新規セクション/欠落サブキー/Wiki の back-add。User-customized 保全・冪等・preview なし）→ (4) Step 7 Phase 4.7 |

両経路とも Step 6 が config を変更し得るため Step 3 Backup を必ず先に実行する (precondition)。`current >= latest` 経路は Step 5 Preview/confirm を挟まず、欠落している active セクション/サブキーのみを冪等に back-add する（テンプレート defaults への追従であり、User-customized 値（明示的な `enabled: false` を含む）は保全されるため無確認で適用する）。旧 Step 3.5 の Wiki 専用救済はこの一般化に吸収され、Wiki も他の active セクションと同様に Step 6 item 7 で back-add される（drift anchor SoT に一貫化）。

`current >= latest` 経路で back-add 対象が皆無（全 active セクション/サブキーが既存）の場合、Step 6 は config を書き換えず `rite-config.yml は最新です (v{current})` を表示する。Phase 4.7 はそのまま実行され、Wiki 初期化済みなら Phase 4.7.2 が `wiki_status=already_initialized` を set して Skill 呼び出しは skip される (冪等)。

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

**Unknown key 判定の scope**: Step 4 の "Unknown key" 判定 (user-added keys not in template) は、**template の `# --- Advanced (below this line) ---` 境界より上の active section のみ**を参照する。境界より下 (コメント形式の Advanced sections + 末尾コメント) は template 側で意図的に省略または注記のため存在する領域であり、ユーザー設定の classification 対象外。

**Active top-level sections covered on --upgrade** (drift anchor — the `init-upgrade-drift` test asserts this list ⊇ the template's active top-level keys above the `--- Advanced ---` marker): `schema_version`, `github`, `iteration`, `branch`, `commands`, `verification`, `issue`, `review`, `language`, `wiki`, `multi_session`, `tdd`, `safety`. Each is handled by Step 4/Step 6 above (User-customized values are preserved, missing sections/sub-keys are added). **When a new active top-level section is added to the template, add it to this list too** — otherwise the drift test fails and `--upgrade` would silently miss it.

**Active sub-keys covered on --upgrade** (drift anchor — the `init-upgrade-drift` test T-12 asserts, per section, this list ⊇ each template active section's **direct** sub-keys above the `--- Advanced ---` marker; Step 6 item 4 adds any missing sub-key while preserving existing siblings). Sections whose value is a scalar (`schema_version`, `language`) have no sub-keys and are omitted:

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

**When a new sub-key is added to an existing template section, add it to the matching row above too** — otherwise the T-12 sub-key drift test fails and `--upgrade` would silently miss it (the same guard as the top-level list, one level down).

**Step 5: Preview and confirm** (`current < latest` 経路のみ — `current >= latest` 短絡経路は Step 5 を挟まず Step 6 で欠落 drift を冪等に back-add する)

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

**Path-dependent application**: On the `current < latest` path, apply all items below after the user confirms in Step 5. On the `current >= latest` short-circuit path (Step 5 skipped), apply **only items 3, 4, 6, 7** — the drift back-add (missing active sections / missing sub-keys / multi_session / wiki) — directly without confirmation. Items 1, 2, 5 (schema_version bump / deprecated-key removal / Advanced-section comments) are full-upgrade-only and are skipped on the short-circuit path (schema is already current, so item 1 would be a no-op anyway). Every back-add item (3, 4, 6, 7) is idempotent and preserves User-customized values (including an explicit `enabled: false`), so the short-circuit path applies unattended; when no item finds anything missing, the config is left unchanged and `rite-config.yml は最新です (v{current})` is displayed.

Apply the following:

1. Update `schema_version` to latest value
2. Remove deprecated keys using the Edit tool. Display "廃止キーを削除しました: {keys}".
3. Add missing sections from the template using the Edit tool. Display "新しいセクションを追加しました: {sections}".
4. **Merge missing sub-keys**: for each active section already present in the config, compare its keys against the template section and add **only the missing sub-keys** (with their template default values) using the Edit tool, preserving every existing sibling value. No-op for keys already present (idempotent). Display "サブキーを補完しました: {section.key, ...}" only when at least one key was added.
5. Add Advanced sections as comments (prefixed with `#`) using the Edit tool
6. **If `multi_session:` section is absent**: append the active `multi_session:` block from the template (`enabled: true` + `worktree_base`) so `--upgrade`-ed projects get the same default-on session-worktree behavior as new generation.

   **Block source (SSOT)**: Read `{plugin_root}/templates/config/rite-config.yml` and extract the active `multi_session:` block (the `multi_session:` key line through its last sub-key, above the `# --- Advanced (below this line) ---` marker). Do not duplicate the literal here — any change to template defaults propagates to both new-install and `--upgrade`.

   **Idempotency guard**: Before inserting, Grep `^multi_session:` (excluding comment lines starting with `#`) in the project's `rite-config.yml`. If an active section already exists, skip the Edit entirely (no-op) — this preserves a user's existing block, **including an explicit `enabled: false`** (never overwrite `enabled`).

   **Anchor selection**: insert immediately before the `# --- Advanced (below this line) ---` marker line (`old_string` = marker line, `new_string` = multi_session block + `\n\n` + marker line). If the Advanced marker is absent (user-trimmed config), append after the last top-level active key. Display `rite-config.yml に multi_session セクションを追加しました（active, enabled: true）。` only when the Edit actually ran.
7. **If `wiki:` section is absent**: append the active `wiki:` block from the template (single source of truth) so Phase 4.7 can auto-initialize Wiki.

   **Wiki block source (SSOT)**: Read `{plugin_root}/templates/config/rite-config.yml` and extract the block from `# Wiki settings` through the end of the `wiki:` section (the lines above the `# --- Advanced (below this line) ---` marker). This avoids literal duplication between `setup.md` and the template — any change to default values (e.g., `auto_ingest`, `branch_strategy`) in the template automatically propagates to both new-install and `--upgrade` paths.

   **Idempotency guard**: Before inserting, Grep `^wiki:` (excluding comment lines starting with `#`) in the project's `rite-config.yml`. If an active section already exists, skip the Edit entirely (no-op).

   **Anchor selection**:
   - **Primary anchor**: the `language:` line in `rite-config.yml`. This is unique in the default template and provides a stable insertion point.
   - **Fallback anchor** (if `language:` line is absent due to user customization): the `# --- Advanced (below this line) ---` boundary marker line. Insert the wiki block **immediately before** this marker (`old_string` = marker line, `new_string` = wiki block + `\n\n` + marker line). If the Advanced marker is also absent, use the last top-level active key (line starting with `[a-z]` followed by `:`) before any comment-only tail region.
   - **NOT tail-based**: do not anchor to the last non-empty line of the file — this can collide with the template's repeated `enabled: true` / `auto_query: true` lines in multi-section tails.

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

Phase 4.7's internal "next step" instructions (e.g., "proceed to the next step: `--upgrade`: Phase 4.1.3 Step 7b status-line display and exit") mean **return to Step 7b here** (continuation after Phase 4.7 completes), not a recursive re-entry into Step 7a.

**Step 7b: Display status line and exit**

After Phase 4.7.1/4.7.2/4.7.4 returns control to Step 7, display a Wiki status line selected based on the `wiki_status` value in LLM context, using the same explicit if/else mapping as Phase 5 (select exactly one literal below; do not construct the message dynamically from `wiki_status`):

- If `wiki_status == "initialized"` → `Wiki: 初期化完了`
- Else if `wiki_status == "already_initialized"` → `Wiki: 既に初期化済み`
- Else if `wiki_status == "skipped_disabled"` → `Wiki: スキップ（無効）`
- Else if `wiki_status == "failed"` → `Wiki: 失敗`

Before exiting, execute [Phase 4.8: Sandbox Write-Allowlist 自動設定](#phase-48-sandbox-write-allowlist-自動設定multi_session-有効時1896--1942) and then [Phase 4.9: SSH Host Alias Remote の Sandbox 事前案内](#phase-49-ssh-host-alias-remote-の-sandbox-事前案内1907) (both non-blocking, each self-gated by its own check — safe to invoke unconditionally). Then display the status line and exit. (`--upgrade` skips Phases 1-3 and the Phase 5 full completion report, so only the Wiki status (and, when applicable, the Phase 4.8 / 4.9 guidance) is reported — there is no merge conflict with Phase 5 because `--upgrade` does not enter the new-install path.)

If the user cancels: Display "アップグレードをキャンセルしました" and exit.

**MUST requirements**:
- `schema_version` 未設定の config は暗黙的に v1 として扱う
- ユーザーカスタム値（project_number, owner, iteration, branch 等）を保持する
- バックアップ (`rite-config.yml.bak.{timestamp}`) を作成する
- 廃止キー (`project.name`, `commit.style`, `commit.enforce`, `commit.contextual`, `branch.release`, `branch.types`, `version`) を削除する
- Advanced セクションはコメントアウトで追加する
- テンプレートにないユーザー追加キーを削除しない（Unknown key → Preserve with warning）

### 4.2 Check Issue Templates

If `.github/ISSUE_TEMPLATE/` does not exist, show:
```
.github/ISSUE_TEMPLATE/ が存在しません

Issue テンプレートの作成を推奨します
```

---

## Phase 4.5: Hook Configuration

> **Placeholder convention**: All `{hooks_dir}` occurrences in fenced code blocks within Phase 4.5 are **templates**, not literal commands. Replace `{hooks_dir}` with the absolute path resolved in Phase 4.5.0 before executing each command via the Bash tool.

> **rite hook command の判定基準 (SoT)**: Phase 4.5 の各サブフェーズで hook command が「rite 自身の hook か」を判定する箇所では、command path 中で `rite` が **hooks ディレクトリ直上の完全な path segment** である場合のみ rite hook とみなす（その間に version segment を 1 個まで許容）。具体的には dev/relative の `…/rite/hooks/` と cache install の `…/rite-marketplace/rite/<version>/hooks/` がマッチし、`favorite/hooks/`・`prerite/hooks/`・`rite-something/hooks/` のように `rite` が別 segment の部分文字列にすぎない look-alike はマッチしない。これは helper の正規表現の**単一定義実体** `scripts/settings-local-rite-hook-cleanup.py` の `RITE_HOOK_RE`（正規表現 `(?:^|/)rite/(?:[^/]+/)?hooks/`）と同一基準であり、本ドキュメントで **「rite hook command」** と表記する箇所はすべてこの基準を指す。同名 `.sh` wrapper（python3 guard・atomic write を担う）も `session-start.sh` の settings.local.json 修復経路も、JSON 変換＝regex 適用をこの `.py` に委譲するため、正規表現の定義は `.py` 1 箇所のみに存在する（session-start.sh のインライン複製を解消）。素朴な substring `rite/hooks/` 一致は `favorite/hooks/` 等を over-match するため使わない。

### 4.5.0 Resolve Hook Script Directory

Run the following bash command to detect the hook scripts directory. This command assumes CWD is the project root (Claude Code's Bash tool resets CWD to the project root on each invocation):

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
- If `NOT_FOUND:NO_JQ` → display warning and **skip the rest of Phase 4.5**（jq のインストール案内は Phase 1.0 の依存検査で既出のため、ここでは繰り返さない — AC-3。NO_JQ 経路に入る時点で jq は必ず欠落しており Phase 1.0 が既に OS 別案内を表示済み）:
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

2. **Clean up stale rite hooks from `settings.local.json`**: Read `.claude/settings.local.json` and remove all hook entries whose command is a **rite hook command** (per the 判定基準 above; the helper below is a `.sh` wrapper that enforces this via the `RITE_HOOK_RE` defined in `settings-local-rite-hook-cleanup.py`). Non-rite hooks — including look-alikes such as `favorite/hooks/` — must be preserved. If the file does not exist or has no rite hooks, skip this step silently.

   ```bash
   # settings.local.json から rite hook エントリを削除 (python3 guard・atomic write・JSON 変換は helper に委譲)
   bash "{hooks_dir}/scripts/settings-local-rite-hook-cleanup.sh" ".claude/settings.local.json"
   ```

   > **Helper contract**: `settings-local-rite-hook-cleanup.sh` は **rite hook を実際に除去したときのみ** `CLEANED` を返し、それ以外の安全側ケース (python3 不在・file 不在・対象 hook 不在・不正 JSON・mktemp/mv 失敗を含む) ではすべて `NO_RITE_HOOKS` を返す。ただし **mv 失敗** だけは「変換は成功したが swap-in できず stale な rite hook が残る」ケースであり真の silent skip ではないため、`NO_RITE_HOOKS` (+ exit 0 非ブロッキング) を保ったまま stderr に `[rite] WARNING: ... mv failed` を emit する。`*.py` を `*.sh` wrapper 経由で呼ぶ先例 `issue-comment-wm-update.py` / `issue-comment-wm-sync.sh` に準拠。

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

**⚠️ 重要: 4.5.1.1 と 4.5.1.2 は両方とも必ず実行すること。4.5.1.1 で全パスが正常でも 4.5.1.2 は必ず実行する。** 4.5.1.1 は既存フックのパス検証のみを行い、フックイベント自体の欠落は検出しない。4.5.1.2 が必須フックの存在チェックを担当する。

#### 4.5.1.1 Validate Existing Hook Paths

If the file already contains hooks, check each hook command for rite hook patterns:

1. Scan all `.hooks.{EventName}[*].hooks[*].command` values across PreCompact, PostCompact, SessionStart, SessionEnd, PreToolUse, and PostToolUse events
2. Identify **rite hook commands** (per the 判定基準 above — `rite` as a full path segment above the hooks dir; this covers both `plugins/rite/hooks/` relative paths and any previous absolute paths, while excluding look-alikes such as `favorite/hooks/`)
3. For each matching command, construct the expected full command string `bash {hooks_dir}/{script_name}` (where `{hooks_dir}` is the absolute path resolved in Phase 4.5.0 and `{script_name}` is the filename like `pre-tool-bash-guard.sh`). Compare the existing command string with the expected one
4. If the existing command does NOT match the expected command, mark it as **needs update**

**Note**: Phase 4.5.0 resolves `{hooks_dir}` as an absolute path (via `cd ... && pwd`). If existing hooks use relative paths (e.g., `bash plugins/rite/hooks/pre-tool-bash-guard.sh`), they will not match the absolute path and will be correctly marked for update. This is intentional — converting relative paths to absolute paths is one of the goals of this validation.

**Display when outdated paths are detected** (where `{event}` is the hook event name such as PreCompact/PostCompact/SessionStart/SessionEnd/PreToolUse, and `{current_cmd}` is the existing command string):
```
⚠️ Outdated rite hook paths detected:
| Hook Event | Current Command | Expected Command |
|------------|----------------|-----------------|
| {event}    | {current_cmd}  | bash {hooks_dir}/{script_name} |

→ Paths will be updated in Phase 4.5.2.
```

#### 4.5.1.2 Check Required Hook Presence

**⚠️ このサブフェーズは 4.5.1.1 の結果に関わらず必ず実行する。** 4.5.1.1 が「全パス正常」と判定しても、フックイベント自体が欠落している可能性がある（例: SessionEnd, PreToolUse が未登録）。

After validating existing hook paths in 4.5.1.1, verify that **all** required rite hooks are registered. This check prevents the scenario where some hooks (e.g., PreCompact, SessionStart) are correctly configured but others (e.g., SessionEnd, PostCompact) are missing entirely.

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

**Note**: If no required hooks are missing, no output is displayed from this sub-phase. The decision is deferred to the combined Decision logic below.

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
- **rite hooks (path update)**: If existing hooks are **rite hook commands** (per the 判定基準 above) but use an outdated path (detected in Phase 4.5.1.1), **replace** those hook entries with the updated `{hooks_dir}` path. This ensures re-running `/rite:setup` always corrects stale paths.
- **Missing rite hooks**: If any of the required rite hooks (PreCompact, PostCompact, SessionStart, SessionEnd, PreToolUse, PostToolUse) are not present, add them. PostToolUse has two matchers (`Bash` and `Edit|Write|MultiEdit`) — both entries must coexist.
- **Obsolete hooks**: If `post-compact-guard.sh` (PreToolUse) または `context-pressure.sh` (PostToolUse) exists, **remove** it. `post-compact-guard.sh` は `post-compact.sh` に置き換え済み。`context-pressure.sh` は廃止済み。
- **Matcher rules**: `post-tool-wm-sync.sh` and `pre-tool-bash-guard.sh` use `"matcher": "Bash"` to fire only on Bash tool calls. `scripts/bang-backtick-edit-hook.sh` uses `"matcher": "Edit|Write|MultiEdit"` to fire only on file-edit tool calls. All other hooks use `"matcher": ""`.
- **Permission for WM_SOURCE**: Add `"Bash(WM_SOURCE:*)"` to `.permissions.allow` if not already present. This allows the LLM to execute work memory update commands without prompting (defense-in-depth alongside the PostToolUse hook).

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

# .rite/ 配下のディレクトリエントリは実効判定でゲートする: 既に `.rite/` 広域ルール等で
# 実効的に ignore されている場合は書かない（親ルールに包含される到達不能な行を作らない）。
# 未カバーのときのみ追記する（gitignore-health-check.sh の probe と同じ check-ignore 方式）。
# `.rite/review-results/` は非実測指摘の `description` / `suggestion` 全文を持つ。マージ後も
# `/rite:cleanup` が `archive/` へ退避して残す設計 (記録コメントはポインタしか載せないため) なので、
# ignore されていないと脆弱性の詳細が `git add -A` で公開リポジトリへ恒久 commit されうる。
for dir_entry in ".rite/sessions/" ".rite/worktrees/" ".rite/review-results/"; do
  if ! git check-ignore -q "${dir_entry}.rite-lint-probe" 2>/dev/null; then
    echo "$dir_entry" >> .gitignore
  fi
done
```

Display: `✅ Work memory directory initialized (.rite-work-memory/)`

---

## Phase 4.7: Wiki Initialization

Auto-initialize the Experience Wiki so the user does not need to run `/rite:wiki-init` manually. Executed after Phase 4.6 (new install) and after the Phase 4.1.3 Apply step (`--upgrade` path).

> **Non-blocking contract**: Phase 4.7 failure (including Skill invocation failure) MUST NOT abort `/rite:setup`. On failure, display a warning and continue to Phase 5. The flow always reports Wiki status via the completion report (Phase 5).

> **Status enum** (consumed by Phase 5 — identifier-compatible values, no whitespace/parens):
>
> | Status value | Meaning |
> |--------------|---------|
> | `initialized` | Newly initialized in this `/rite:setup` invocation |
> | `already_initialized` | Pre-existing Wiki detected and skipped |
> | `skipped_disabled` | `wiki.enabled: false` detected |
> | `failed` | Post-check after Skill invocation found Wiki still uninitialized |

**Retain `wiki_status` as LLM conversational state (NOT a shell variable)**. Claude Code's Bash tool invocations are independent subshells — shell variables do NOT persist across tool calls. Each status set point below instructs the LLM to **remember the value directly in conversation context** and carry it forward to Phase 5. Do NOT attempt `echo $wiki_status` in a subsequent Bash call.

The enum values are identifier-compatible (snake_case, no whitespace or parentheses) so that Phase 5 / Step 7b can branch on `wiki_status` with an explicit if/else and select the matching literal directly. Do not construct the message dynamically from `wiki_status`.

### 4.7.1 Wiki Enabled Check

Read `wiki.enabled` from `rite-config.yml`. Wiki is **opt-out**: missing section / missing key / unparseable value → treat as `true`. This mirrors `skills/wiki-init/SKILL.md` ステップ 1.1 logic, including the typo-detection WARNING path.

> **sed range robustness note**: The `sed -n '/^wiki:/,/^[a-zA-Z]/p'` pattern terminates at the next line starting with any ASCII letter — which matches the next top-level YAML key. This relies on `rite-config.yml` following the standard shape produced by `/rite:setup` (wiki section followed by another top-level key or EOF). In pathological user-customized configs where the wiki section is the last top-level block and is followed only by comment lines, sed reads to EOF, which is still correct. The known limitation: if a user inserts comment lines **inside** the wiki section that start with a letter (e.g., `auto_query: true # note:`), the trailing `# note:` does not affect sed (it's part of the same line). Therefore this pattern is safe for configs conforming to the template shape. Drift in non-standard configs is tracked as a known limitation, not a blocker for the wiki section drift handling.

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

> **Rationale**: Claude Code's Skill tool does not surface a return value, so failure detection is done via post-check (4.7.4). Do NOT re-implement Wiki initialization logic here — always delegate to the Skill.

### 4.7.4 Post-check: Confirm Initialization

After the Skill returns, re-run **only the detection portion** of 4.7.2 (the `if [ "$branch_strategy" = "separate_branch" ]; then ... fi` block) to confirm the Wiki was actually created. The `branch_strategy` / `wiki_branch` values from 4.7.2 are already known to the LLM and should be embedded as literals rather than re-parsing `rite-config.yml` — this avoids any drift if the Skill modified the config.

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

`multi_session.enabled: true`（Phase 4.1 で決定済み。新規生成・back-add いずれの経路でも既定 ON）**かつ** Claude 自身の Bash tool 定義（sandbox セクション）が filesystem write 制限を伴う sandbox で動作していることを示している場合のみ、以下を実行する。いずれか一方でも該当しない場合（`multi_session.enabled: false`、または sandbox 無効／write 制限なし）は本節を完全に silent skip する（案内・warning 共に一切出さない — AC-3）。

判定は Claude 自身の実行コンテキスト（system prompt に記述された sandbox の write 許可リスト）を読んで行う。bash コマンドでは検出できない（sandbox の有無はセッションの起動設定であり、ファイルから読み取れる状態ではないため）。

該当する場合、まず main checkout root の絶対パスを取得する。`git rev-parse --show-toplevel` は現在の worktree の toplevel を返すため、setup がセッション worktree cwd から実行された場合（例: EnterWorktree 後の `/rite:setup --upgrade` 手動実行）に worktree パスを誤って返す（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh) が同じ理由でこのパターンを避けている）。代わりに `state-path-resolve.sh` で main checkout root を解決する:

```bash
bash {plugin_root}/hooks/state-path-resolve.sh
```

その値を `{repo_root}` として、`.claude/settings.local.json`（コミットされる `.claude/settings.json` は書き換えない）の `sandbox.filesystem.allowWrite` へ idempotent に自動追記する。書込先はユーザーローカル設定として扱う意図のファイルだが、**リポジトリの `.gitignore` に明示エントリがなければコミット済み扱いになる**（開発者個人のグローバル gitignore に依存した除外は他の contributor 環境では効かない）ため、まず対象リポジトリの `.gitignore` に `.claude/settings.local.json` を保証してから書き込む（Phase 4.6 の gitignore 追記パターンと同形式）。方針転換の背景・(a)/(b)/(c) 比較検討は [git-worktree-patterns.md の Decision Log](../../references/git-worktree-patterns.md#sandbox-write-allowlist-設定の自動化decision-log) を参照（複製しない）:

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

**sandbox + multi_session 環境では、上記スクリプトが `added`/`already_present` を返さず初回から marker `failed` になるのが既定経路である**（例外ケースではない）。`jq ... > "$settings_file.tmp"` リダイレクトが単独で「読み込み専用ファイルシステムです」等のエラーを起こし、bash 全体としては正常終了（exit 0）したまま `else` 節に落ちて marker が直接 `failed` になる（bash ツール呼び出し自体はエラーにならない）。そのため **「コマンド自体が失敗したかどうか」を再試行の判定条件にしない** — marker が `failed` であれば理由を問わず、当該 bash ブロック全体を一度だけ `dangerouslyDisableSandbox: true` で再実行してよい（ユーザー確認は不要 — sandbox に拒否された main checkout 書き込みだけを再試行する既存ポリシーと同じ扱い。ブロック全体の再実行は `grep -qF` / `unique` により冪等なので、gitignore 追記側だけ再実行するより安全）。再実行後も `failed`（JSON 破損等、sandbox 起因でない失敗）の場合のみ、下記の手動案内メッセージにフォールバックする。

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

`origin` remote が SSH host alias 経由（例: `git@github.com-work:owner/repo.git`）で、かつ Claude 自身の Bash tool 定義（sandbox セクション）がネットワーク制限を伴う sandbox で動作していることを示している場合のみ、以下を表示する。いずれか一方でも該当しない場合（HTTPS remote / sandbox 無効）は本節を完全に silent skip する（案内・warning 共に一切出さない）。`multi_session` の有無には依存しない（Phase 4.8 と異なり、本問題は SSH alias remote + sandbox の組合せのみで発生するため独立した gate とする）。

SSH host alias remote かどうかは bash で判定できる（git config の読み取りであり検出可能。Phase 4.8 の sandbox 判定とは性質が異なる）:

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

一方 sandbox の有効判定は Phase 4.8 と同じ理由（bash コマンドでは検出できない — sandbox の有無はセッションの起動設定であり、ファイルから読み取れる状態ではないため）により、Claude 自身の実行コンテキスト（system prompt に記述された sandbox のネットワーク許可リスト）を読んで行う。settings ファイルの `sandbox.enabled` を `jq` で読む経路は使わない（Phase 4.8 の判定方針と統一）。

`SSH_ALIAS_REMOTE=yes` **かつ** sandbox 有効の両方が真のときのみ、以下を表示する（原因の因果連鎖や恒久対処の詳細本文は複製せず、要約 + [git-worktree-patterns.md](../../references/git-worktree-patterns.md#ssh-host-alias-経由の-git-pushfetch-が-sandbox-のネットワーク許可リストでブロックされる) への 1 行ポインタに留める）。以下のテンプレートをそのまま出力し、要約・言い換え（「〜旨を案内」等の間接話法を含む）をしないこと:

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

**→ Proceed to Phase 5 (new-install) — this Phase is only reached via the new-install exit points in Phase 4.7 (§4.7.1/4.7.2/4.7.4) followed by Phase 4.8; `--upgrade` invokes this Phase directly after Phase 4.8 from Step 7b and then exits without a Phase 5 report.**

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
