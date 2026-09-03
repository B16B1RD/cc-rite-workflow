---
name: pr-create
description: |
  rite workflow の draft PR 作成 sub-skill: コミット済みブランチから draft PR を作成し、関連 Issue と
  連携する。/rite:open・/rite:ready から programmatic に呼ばれる（ユーザーは直接起動しない）。
  汎用の「PR を作成」ヘルパーではなく、その語では auto-activate しない。
argument-hint: "[title]"
user-invocable: false
---

# /rite:pr-create

## Contract
**Input**: Branch with commits, Issue number (from branch name or flow state)
**Output**: `[pr:created:{number}]` | `[pr-create-failed]`

ドラフト PR を作成し、関連 Issue と連携する

> 生成する PR description / commit message は [Simplification Charter](../../skills/rite-workflow/references/simplification-charter.md) に従う（過去 PR / cycle 番号の本文引用を避け、経緯は git log に任せる）。

## E2E Output Minimization

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Phase 3 (PR Creation) | Full output | `[pr:created:{number}]` + PR URL only |
| Phase 4 (Completion) | Full report | **Skip** (pattern already output) |

判定は下記 Caller Context 表。

## Caller Context and End-to-End Flow

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing bash hook commands in this file.

| Caller | Subsequent Action |
|-----------|---------------|
| End-to-end flow (via any orchestrator's Skill tool invocation, e.g. `/rite:open` ステップ 6) | **Output pattern and return control to caller** |
| Standalone execution | Display "next steps" guidance |

| Condition | Determination |
|------|---------|
| Invoked via `Skill` tool from any orchestrator within the same session (caller-name agnostic — e.g. `/rite:open`) | Within end-to-end flow |
| All other cases (user directly typed `/rite:pr-create`) | Standalone execution |

E2E では `[pr:created:{number}]` / `[pr-create-failed]` を出して **caller に制御を返す**。次アクションは caller が決める。

---

## Arguments

| Argument | Description |
|------|------|
| `[title]` | PR title (auto-generated if omitted) |

---

## Phase 0: Load Work Memory (During End-to-End Flow)

### 0.1 Determine End-to-End Flow Status

| Condition | Determination | Action |
|------|---------|------|
| Conversation history contains rich context from an orchestrator's end-to-end flow (e.g. `/rite:open` invocation marker) | Within end-to-end flow | Work memory loading optional (information available in context) |
| `/rite:pr-create` was executed standalone | Standalone execution | Issue can be identified from branch name |

### 0.2 Load Work Memory

ブランチ名から Issue 番号を取り、ローカル work memory（SoT）を読む:

```bash
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
```

Read `.rite/work-memory/issue-{issue_number}.md`（SoT）。不在なら `.rite-work-memory/issue-{issue_number}.md`。欠落 / 破損時は Issue comment API:

```bash
# SSH host alias 対応: git-remote.sh 優先 + gh repo view fallback
# (canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}

gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body'
```

### 0.3 Information to Retrieve

| Field | Extraction Pattern | Purpose |
|-----------|-------------|------|
| Issue number | `issue-(\d+)` from branch name | Generate `Closes #XX` in PR body |
| Branch name | `- **ブランチ**: (.+)` | Verify base during PR creation |
| Phase | `- **フェーズ**: (.+)` | Confirm flow position |
| lint results | `### 品質チェック履歴` section | Reflect in PR body |

Issue 番号が取れなければ Phase 1.4。

---

## Phase 1: Verify Current State

### 1.0 Bang-Backtick Adjacency Pre-Check (Pre-PR Gate)

> **DRIFT-CHECK ANCHOR (MUST)**: `skills/pr-create/SKILL.md` §1.0 と `skills/ready/SKILL.md` §1.0 の bash は同期する。片方の変更は必ず他方へ複製する。
>
> lint Phase 3.5 は warning（`[lint:success]` は保つ）。本ゲートは同じパターンが残っていれば **PR mutation を止める**。
> rationale: references/rationale.md#bang-backtick-gate

`{plugin_root}` は [inline one-liner](../../references/plugin-path-resolution.md#inline-one-liner-for-command-files) で解決して実行する:

```bash
plugin_root=$(cat .rite/plugin-root 2>/dev/null || cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/bang-backtick-check.sh" ]; then
  echo "[CONTEXT] BANG_BACKTICK_CHECK_INVOCATION_FAILED=1; reason=script_missing; resolved_root=${plugin_root:-<empty>}" >&2
  echo "ERROR: bang-backtick-check.sh not found. Cannot proceed with PR submission gate." >&2
  exit 1
fi

bang_output=$(bash "$plugin_root/hooks/scripts/bang-backtick-check.sh" --all --skip-if-no-target 2>&1)
bang_rc=$?
case "$bang_rc" in
  0)
    # A clean scan and a not-applicable skip both mean "proceed". The skip happens
    # in a consumer repo (rite used as a marketplace plugin only — no plugins/rite/
    # in this working tree, hence --skip-if-no-target above). Surface a one-line
    # informational note for the skip case so the gate pass is not silent.
    if printf '%s' "$bang_output" | grep -q '\[bang-backtick\] not applicable'; then
      echo "ℹ️ Bang-backtick gate: 本リポジトリは plugins/rite/ を self-host していないため N/A（clean skip）。" >&2
    fi
    ;;
  1)
    echo "❌ Bang-backtick adjacency detected — PR submission blocked:" >&2
    printf '%s\n' "$bang_output" >&2
    echo "ACTION: Apply Style A (full-width 「!」) or Style B (expand 'if ! cmd; then') — see plugins/rite/hooks/scripts/bang-backtick-check.sh header for the judgment flow." >&2
    exit 1
    ;;
  *)
    echo "[CONTEXT] BANG_BACKTICK_CHECK_INVOCATION_FAILED=1; reason=invocation_error; rc=$bang_rc" >&2
    echo "ERROR: bang-backtick-check.sh invocation error (rc=$bang_rc):" >&2
    printf '%s\n' "$bang_output" >&2
    exit 1
    ;;
esac
```

> exit 1 のとき結果パターンは出ない。orchestrator は missing-result-pattern として扱う（**NOT** `[pr-create-failed]`）。default は stderr `WARNING` + **1 回だけ再実行**。再失敗なら停止し `/rite:recover` を案内する。AskUserQuestion は出さない。`BANG_BACKTICK_CHECK_INVOCATION_FAILED=1` は script 不在 / rc=2 のみ（rc=1 の検出はフラグなし）。
> rationale: references/rationale.md#bang-backtick-gate

### 1.1 Retrieve Base Branch

Read `rite-config.yml` at the project root using the Read tool, and get the `branch.base` value:

```
Read: rite-config.yml
```

1. `rite-config.yml` に `branch.base` があればその値を `{base_branch}` にする
2. ファイル不在 / キー不在 / `null` / 空文字 / `branch` 節不在 → `main`

### 1.2 Branch Verification

Verify the diff between the current branch and `{base_branch}`:

```bash
git branch --show-current
```

**If on the base branch:**

```
エラー: 現在 {branch} ブランチにいます

PR を作成するには作業ブランチに切り替えてください。
`/rite:open` で作業を開始できます。
```

Terminate processing.

### 1.3 Verify Changes

```bash
bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh
git diff --stat origin/{base_branch}...HEAD
git log --oneline origin/{base_branch}...HEAD
```

**Fallback:** Try diff in order: `origin/{base_branch}` -> `{base_branch}` (try next on error). If both fail, display an error:

```
エラー: 変更の差分を取得できません

ベースブランチ '{base_branch}' が見つかりません。

対処:
1. rite-config.yml で branch.base の設定を確認
2. git fetch origin でリモート情報を更新
3. 手動で差分を確認: git diff <base_branch>...HEAD
```

処理を中止する。`HEAD` 差分へ倒さない。
rationale: references/rationale.md#no-head-diff-fallback

**If no commits exist:**

```
警告: まだコミットがありません

変更をコミットしてから PR を作成してください。
```

Terminate processing.

### 1.4 Extract Issue Number

Extract the related Issue number from the branch name:

```
パターン: {type}/issue-{number}-{slug}
例: feat/issue-{number}-pr-create → 対応する Issue
```

If extraction fails, confirm with `AskUserQuestion`:

```
ブランチ名から Issue 番号を特定できません

現在のブランチ: {branch}

オプション:
- Issue 番号を手動で指定
- Issue なしで PR を作成
- キャンセル
```

### 1.5 Retrieve Issue Information

> 以降の実行スニペットの `-R {owner_repo}` は、[Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）をリテラル置換する（SSH host alias 環境対応。同節の Propagation 小節参照）。

```bash
gh issue view {issue_number} -R {owner_repo} --json number,title,body,state,labels
```

**If the Issue is closed:**

```
警告: Issue #{number} は既にクローズされています

PR を作成しますか？
オプション:
- はい、作成する
- キャンセル
```

### 1.6 Retrieve Work Memory

Retrieve work memory from Issue comments:

```bash
gh api repos/{owner}/{repo}/issues/{issue_number}/comments --jq '.[] | select(.body | contains("rite 作業メモリ"))'
```

見つかれば進捗・変更ファイル・決定事項を抽出する。

---

## Phase 2: Quality Checks (Optional)

### 2.1 Verify Auto-Detected Commands

`rite-config.yml` から build/lint コマンドを取る:

```yaml
commands:
  build: null  # 自動検出
  lint: null   # 自動検出
```

自動検出: `package.json` の `scripts` → `Makefile` の target → 言語既定。

### 2.2 Confirm Quality Check Execution

`AskUserQuestion`:

```
PR 作成前に品質チェックを実行しますか？

検出されたコマンド:
- lint: {lint_command}
- build: {build_command}

オプション:
- すべて実行（推奨）
- lint のみ
- スキップ
```

### 2.3 Execute Checks

```bash
# lint 実行例
npm run lint
```

**If errors are found:**

```
品質チェックでエラーが検出されました

{error_output}

オプション:
- エラーを無視して PR 作成
- 修正してから再実行
- キャンセル
```

### 2.4 Verify Issue Body Checklist

Issue 本文にチェックリストがあれば未完了を警告する。

#### 2.4.1 Extract Checklist

Phase 1.5 の本文から抽出:

```bash
# Issue 本文を取得（既に Phase 1.5 で取得済みの場合は再利用）
gh issue view {issue_number} -R {owner_repo} --json body --jq '.body'
```

**Extraction pattern:**

```
パターン: /^- \[[ xX]\] (.+)$/gm
```

**Exclusion pattern:**

親子管理の Issue 参照 Tasklist は除外:

```
パターン: /^- \[[ xX]\] #\d+/gm
```

#### 2.4.2 Detect Incomplete Check Items

未完了は `- [ ]`。全完了（`- [x]`）またはチェックリスト無しなら Phase 2.5。未完了があれば:

```
警告: Issue 本文に未完了のチェック項目があります

未完了項目:
- [ ] {item_1}
- [ ] {item_2}
- [ ] {item_3}

オプション:
- 未完了のまま PR 作成（推奨）: PR 本文に未完了項目を記載します
- チェック項目を完了してから再実行: 作業を中断し、未完了項目を完了させます
- キャンセル
```

**Subsequent processing for each option:**

| Option | Subsequent Processing |
|--------|----------|
| **未完了のまま PR 作成（推奨）** | Proceed to Phase 2.5. Record incomplete items in the "Incomplete Issue Check Items" section of the PR body |
| **チェック項目を完了してから再実行** | Display guidance to complete incomplete items and re-run `/rite:pr-create`, then terminate |
| **キャンセル** | Terminate processing |

#### 2.4.3 Record Incomplete Items in PR Body

「未完了のまま PR 作成」なら PR 本文へ:

```markdown
## 未完了の Issue チェック項目

以下のチェック項目が Issue 本文で未完了です:

- [ ] {item_1}
- [ ] {item_2}
- [ ] {item_3}

これらの項目は後続の作業で対応予定です。
```

#### 2.4.4 If No Checklist Exists

チェックリストが無ければ Phase 2.5。

### 2.5 Verify Unresolved Issues (issue_accountability)

> **Reference**: [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md) - `issue_accountability`

#### 2.5.1 Verification Targets

| Source | What to Verify |
|--------|----------|
| Work memory | Unresolved items in the "要確認事項" section |
| Conversation history | Warnings/errors detected by lint/test |
| Review results in conversation history | Findings judged as "out of scope" or "not applicable" (including self-review results)[^1] |

[^1]: 同一セッションに self-review が無い（standalone 起動など）ならこの source は skip。

#### 2.5.2 Verify Work Memory

Phase 0.2 / 1.6 で取得済みなら再利用。未取得のときだけ:

```bash
# 作業メモリから要確認事項を抽出（Phase 0.2 または Phase 1.6 で未取得の場合のみ実行）
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ")) | .body'
```

`### 要確認事項` の `- [ ]` を検出する。bash の `grep -A` 等は使わない。
rationale: references/rationale.md#no-bash-grep-wm

未チェックがあれば警告。

#### 2.5.3 Detection from Conversation History

会話 context から検出: 「対象外」/「該当せず」/「既存問題」、未解決の lint/test 警告、新規 TODO/FIXME（`git diff origin/{base_branch}...HEAD | grep -E "^\+.*(TODO:|FIXME:|XXX:)"`）。解決済み: 修正（Edit/Write）、Issue 作成（`gh issue create`）、説明/返信のいずれかがあれば解決。

#### 2.5.4 Processing When Unresolved Issues Exist

`AskUserQuestion`:

```
警告: 未対応の問題・指摘があります

以下の項目が未対応です（Phase 2.5.3 で検出した未対応問題リストから表示）:
| # | 内容 | 情報源 |
|---|------|--------|
| 1 | {problem_summary} | {detection_source} |
| 2 | {problem_summary} | {detection_source} |

「対象外」「既存の問題」は対応しない理由になりません。
発見した問題には必ず対応が必要です。

オプション:
- 別 Issue を作成して PR 作成を続行（推奨）: 未対応項目を Issue として登録し、PR を作成します
- 問題を今すぐ修正する: PR 作成を中断し、問題を修正します
- PR 作成を中止する: 問題を確認してから再実行します
```

`{problem_summary}` / `{detection_source}` は 2.5.5 と同じ。

| Option | Subsequent Processing |
|--------|----------|
| **別 Issue を作成して PR 作成を続行（推奨）** | 2.5.5 Auto-create Issues -> Proceed to Phase 3 |
| **問題を今すぐ修正する** | Display guidance to fix unresolved issues and re-run `/rite:pr-create`, then terminate processing |
| **PR 作成を中止する** | Terminate processing |

5 件以上は一括を推奨（閾値は固定）。
rationale: references/rationale.md#issue-accountability-never-skip

```
警告: 未対応の問題・指摘が {count} 件あります（5件以上）

一括処理を推奨します:

オプション:
- すべて別 Issue として一括作成（推奨）: {count} 件の Issue を自動作成します
- 個別に対応を選択: 各問題について対応方法を選択します
- PR 作成を中止する: 問題を確認してから再実行します
```

| Option | Subsequent Processing |
|--------|----------|
| **すべて別 Issue として一括作成** | Auto-create Issues for all problems -> Proceed to Phase 3 |
| **個別に対応を選択** | Present Phase 2.5.4 options for each problem **one by one** (select resolution method for each, proceed to Phase 3 after all are completed) |
| **PR 作成を中止する** | Terminate processing |

#### 2.5.5 Auto-Create Issues

「別 Issue を作成して続行」なら未対応ごとに 1 Issue。

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

heredoc の `{placeholder}` はスクリプト生成前に実値へ置換（シェル変数ではない）。ブロック全体を **単一 Bash 呼び出し**で実行する。Priority 既定 → Medium。Complexity: XS = 1 行/1 箇所、S = 1–2 ファイルの複数行。

プレースホルダーはスクリプト生成前に置換する:

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `{owner}` |
| `{iteration_mode}` | `rite-config.yml` → `iteration.enabled` が `true` かつ `iteration.auto_assign` が `true` なら `"auto"`、それ以外は `"none"` | `"none"` |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) | `/home/user/.claude/plugins/rite` |

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
**Type**: fix
**Complexity**: S

## 概要

{problem_summary}

## 問題の詳細

{problem_details}

## 発生元

- 元 Issue: #{original_issue_number}
- 検出日時: {timestamp}
- 検出方法: {detection_method}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi

# args_json を入れ子 $() から分離して構築する (深い入れ子 quoting の malform 源を削減。
# 単一 JSON 引数契約は不変)
args_json=$(jq -n \
  --arg title "fix: {problem_summary}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg complexity "S" \
  --arg iter_mode "{iteration_mode}" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "pr_create", non_blocking_projects: true }
  }') || { echo "ERROR: args_json の jq 構築に失敗しました" >&2; exit 1; }

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$args_json")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
created_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
created_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**⚠️ Projects 登録失敗時の警告表示（必須）**: スクリプト実行後、`project_registration` の値を必ず確認し、`"partial"` または `"failed"` の場合は以下を表示すること:

```
⚠️ Projects 登録が完全に完了しませんでした（status: {project_registration}）
手動登録: gh project item-add {project_number} --owner {owner} --url {created_issue_url}
```

**Error handling:**

| Error Case | Response |
|------------|----------|
| Script returns `issue_url: ""` | Display warning with error details. If remaining candidates exist, continue creating others |
| `project_registration: "partial"` or `"failed"` | Display warnings from result. Issue creation itself succeeded |

`tech-debt` ラベルは存在するときだけ。作成失敗は retry/skip/abort（最大 2 回）。作成後、PR 本文の「関連 Issue」へ追記。複数時は作成順に `_1`, `_2`, ...。

```markdown
## 関連 Issue

Closes #{original_issue_number}

### 検出された問題（別 Issue として追跡）

- #{created_issue_1}: {problem_summary_1}
- #{created_issue_2}: {problem_summary_2}
```

#### 2.5.6 If No Issues Found

```
未対応の問題は検出されませんでした。Phase 3 へ進みます。
```

Phase 3 へ。

#### 2.5.7 Behavior During End-to-End Flow

| Situation | Behavior |
|------|------|
| No unresolved issues | Auto-proceed to Phase 3 |
| Unresolved issues (fewer than 5) | Proceed to Phase 3 after individual confirmation |
| Unresolved issues (5 or more) | Proceed to Phase 3 after batch confirmation |

E2E でも未対応問題の検証は **skip しない**。
rationale: references/rationale.md#issue-accountability-never-skip

---

## Phase 3: Create PR

### 3.1 Generate PR Title

Conventional Commits。言語は `rite-config.yml` の `language`:

| Setting | Behavior |
|--------|------|
| `auto` | Detect user's input language and generate in the same language |
| `ja` | Generate title in Japanese |
| `en` | Generate title in English |

Issue タイトルが設定言語と違うときは翻訳する。type はブランチ名、scope / description は Issue タイトル。

> **⚠️ CRITICAL**: PR title の `description` は `language` 設定に従う。例の言語をコピーしない。

```
Pattern: {type}({scope}): {description}
Example (English): feat(pr): implement /rite:pr-create command
Example (Japanese): feat(pr): /rite:pr-create コマンドを実装
```

**type mapping:**
| Branch prefix | PR type |
|----------------|---------|
| feat/ | feat |
| fix/ | fix |
| docs/ | docs |
| refactor/ | refactor |
| chore/ | chore |
| style/ | style |
| test/ | test |

### 3.2 Generate PR Body

Template file: `templates/pr/generic.md`

本文言語は **Phase 3.1 と同じ**。

| Element | Subject to Language Unification |
|------|---------------|
| Section headings | `## Summary` / `## 概要`, etc. |
| Boilerplate text | Description for `Closes #XX`, etc. |
| Checklist items | `- [ ] Tests added` / `- [ ] テスト追加`, etc. |

含める: 概要、関連 Issue（`Closes #{number}`）、変更（work memory または git diff）、チェックリスト、Implementation Notes（§3.2.2、該当時）。

#### 3.2.1 Context Optimization During End-to-End Flow

OR: E2E 実行中 / 変更ファイル 20 以上 / ツール呼び出し 30 超。確認なしで適用。変更は上位 3 ファイルの一覧と要約、work memory は進捗要約、チェックリストは必須項目のみ、Implementation Notes は §3.2.2 の cap。
rationale: references/rationale.md#impl-notes-for-reviewers

#### 3.2.2 Implementation Notes Summary (Plan Deviation / Decision Log)

1. **Work memory Plan Deviation Log**（`### 計画逸脱ログ` — [Work Memory Format](../../skills/rite-workflow/references/work-memory-format.md#plan-deviation-log-section)）。ローカル SoT、無ければ Issue comment。`_計画逸脱はありません_` / 節不在は 0 件（error にしない）。
2. **Issue body Section 9 Decision Log**（`## 9. Decision Log` — [Issue Template Structure](../../templates/issue/template-structure.md)）。context の本文。`D-xx:` 無しは 0 件。

各項目 1 行: `{種別}: {1 行要約} — {理由}`。`種別` は Phase 3.1 の言語（`en`: Deviation / Decision、`ja`: 逸脱 / 判断）。1 文。ポインタであり全文転記ではない。

**Zero-item rule (MUST)**: 両ソース 0 件なら節ごと省略（見出し含む）。空見出し・空リストは出さない。

見出し: `## Implementation Notes`（en）/ `## 実装中の判断・計画逸脱`（ja）。位置は `## Changes` と `## Checklist` の間（`templates/pr/generic.md`）。

E2E 最適化時は上位 3 件（逸脱 → 判断、ソース順）、省略数を注記（`(他 N 件省略)` / `(N more omitted)`）。
rationale: references/rationale.md#impl-notes-for-reviewers

### 3.3 Push to Remote

```bash
git push origin {branch_name}
```

> `-u` は付けない。3.4 の `gh pr create` は `--head` でブランチを指定する。
> rationale: references/rationale.md#push-no-upstream

### 3.4 Create Draft PR

> **3 段プロトコル**: (A) workdir を `mktemp -d` で確保 → (B) **Write tool** で title / body を raw ファイル化（heredoc を使わない）→ (C) bash は変数 / `--body-file` 経由で `gh pr create` を実行。title を bash ブロックにインライン展開しない。
> rationale: references/rationale.md#three-stage-protocol

**(A) workdir 確保**

```bash
pr_workdir=$(mktemp -d -t rite-pr-create-XXXXXX)
echo "[CONTEXT] PR_CREATE_WORKDIR=$pr_workdir"
```

**(B) title / body の生成（Write tool）**

直前の `[CONTEXT] PR_CREATE_WORKDIR=` から `{PR_CREATE_WORKDIR}` を読み取り、以下を **Write tool** で書く（heredoc を使わない）:

1. `{PR_CREATE_WORKDIR}/pr_title.txt` ← Phase 3.1 で生成した PR title の raw 内容（1 行）
2. `{PR_CREATE_WORKDIR}/pr_body.md` ← Phase 3.2 で生成した PR body の raw 内容

**(C) gh pr create（単一 bash block）**

> `{PR_CREATE_WORKDIR}` は (A) の CONTEXT marker から literal 置換し、冒頭で `pr_workdir` に束縛する。以降は `$pr_workdir` のみ。title は変数経由（bash に inline しない）。cleanup は **signal-specific trap**（空 body / 空 title / `gh` 失敗 / SIGINT/TERM/HUP）。空 title / 空 body は対称にガードする。[bash-trap-patterns.md](../../references/bash-trap-patterns.md#signal-specific-trap-template)
> rationale: references/rationale.md#three-stage-protocol

```bash
pr_workdir="{PR_CREATE_WORKDIR}"
_rite_create_phase34_cleanup() {
  [ -n "${pr_workdir:-}" ] && [ -d "$pr_workdir" ] && rm -rf "$pr_workdir"
  return 0
}
trap 'rc=$?; _rite_create_phase34_cleanup; exit $rc' EXIT
trap '_rite_create_phase34_cleanup; exit 130' INT
trap '_rite_create_phase34_cleanup; exit 143' TERM
trap '_rite_create_phase34_cleanup; exit 129' HUP

pr_title=$(cat "$pr_workdir/pr_title.txt")
if [ -z "$pr_title" ]; then
  echo "ERROR: PR title is empty (pr_title.txt missing or empty — (B) Write step 漏れの可能性)" >&2
  exit 1
fi
if [ ! -s "$pr_workdir/pr_body.md" ]; then
  echo "ERROR: PR body is empty" >&2
  exit 1
fi

gh pr create -R {owner_repo} --draft --base "{base_branch}" --head "{branch_name}" --title "$pr_title" --body-file "$pr_workdir/pr_body.md"
```

### 3.5 Update Work Memory Phase

ローカル SoT を更新し、Issue comment へ backup sync。3.5 は `phase=pr` の即時遷移、4.1.2 が詳細を足す。
rationale: references/rationale.md#wm-two-step

**Step 1: Update local work memory**

[Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands)

```bash
WM_SOURCE="create" \
  WM_PHASE="pr" \
  WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="rite:pr-review を実行" \
  WM_BODY_TEXT="PR #{pr_number} created." \
  WM_ISSUE_NUMBER="{issue_number}" \
  WM_PR_NUMBER="{pr_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

**Step 2: Sync to Issue comment (backup)**

```bash
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-phase \
  --phase "pr" --phase-detail "PR作成完了" \
  2>/dev/null || true
```

---

## Phase 4: Post-Processing

### 4.1 Auto-Update Work Memory

> **Warning**: Work memory is published as Issue comments. In public repositories, it is viewable by third parties. Do not record confidential information (credentials, personal information, internal URLs, etc.) in work memory.

#### 4.1.1 Collect Update Information

```bash
# 変更ファイルの取得
git diff --name-status origin/{base_branch}...HEAD

# コミット履歴の取得
git log --oneline origin/{base_branch}...HEAD
```

#### 4.1.2 Retrieve and Update Work Memory Comment

(A) 進捗と変更ファイル、(B) PR 固有節の追記。どちらも `issue-comment-wm-sync.sh`。

```bash
# Part (A): 進捗サマリー + 変更ファイル更新
files_tmp=$(mktemp)
trap 'rm -f "$files_tmp"' EXIT
printf '%s' "{changed_files_md}" > "$files_tmp"

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-progress \
  --impl-status "✅ 完了" --test-status "{test_status}" --doc-status "{doc_status}" \
  --changed-files-file "$files_tmp" \
  2>/dev/null || true

rm -f "$files_tmp"

# Part (A'): 次のステップ置換
next_tmp=$(mktemp)
trap 'rm -f "$next_tmp"' EXIT
printf '%s' "- **コマンド**: /rite:pr-review #{pr_number}
- **状態**: 待機中
- **備考**: PR 作成完了、レビュー準備完了" > "$next_tmp"

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform replace-section \
  --section "次のステップ" --content-file "$next_tmp" \
  2>/dev/null || true

rm -f "$next_tmp"

# Part (B): 関連 PR + コミット履歴追記
pr_info_tmp=$(mktemp)
trap 'rm -f "$pr_info_tmp"' EXIT
cat > "$pr_info_tmp" << 'PR_EOF'
### 関連 PR
- **番号**: #{pr_number}
- **タイトル**: {pr_title}
- **URL**: {pr_url}
- **作成日時**: {timestamp}

### コミット履歴
{commit_log}
PR_EOF

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-section \
  --section "レビュー対応履歴" --content-file "$pr_info_tmp" \
  2>/dev/null || true

rm -f "$pr_info_tmp"
```

**Note for Claude**: `{changed_files_md}` はバッククォートを含むためファイル経由で渡す。heredoc 内の `{placeholder}` は Claude が実際の値で置換すること。

#### 4.1.3 Update Content Reference

4.1.2 の更新内容:

| Section | Update |
|---------|--------|
| `進捗サマリー` table | `実装` → `✅ 完了`（v2）/ `- [x] 実装`（v1 fallback） |
| `変更ファイル` section | Replace entire content with `{changed_files_md}` |
| `次のステップ` section | Set to `/rite:pr-review #{pr_number}` |
| `最終更新` timestamp | Replace with current timestamp |

`{pr_number}` は実番号。placeholder のまま残さない。

`changed_files_md` は `git diff --name-status origin/{base_branch}...HEAD` から:

```markdown
- `path/to/file1.ts` - 変更
- `path/to/file2.ts` - 追加
```

`A` → 追加, `M` → 変更, `D` → 削除, `R` → 名前変更。work memory comment が無ければ警告して skip。

### 4.2 Completion Report

```
ドラフト PR #{pr_number} を作成しました

タイトル: {title}
URL: {pr_url}

関連 Issue: #{issue_number}

次のステップ:
1. PR の内容を確認
2. `/rite:pr-review` でセルフレビュー
3. `/rite:ready` で Ready for review に変更
```

---

## Error Handling

| Error | Resolution |
|--------|------|
| Push failure | Check network -> `gh auth status` -> `git pull --rebase origin {branch_name}` -> retry once; on second failure stop and `/rite:recover` |
| PR creation failure | Check existing PRs with `gh pr list -R {owner_repo}` -> verify permissions -> retry once; on second failure stop and `/rite:recover` |
| Issue not found | Choose: create without Issue / specify different Issue / cancel |
## Language Support

Follow `language` in `rite-config.yml` (`auto`: detect input language, `ja`: Japanese, `en`: English). Title and body are unified in the same language. Priority for `auto` mode: user input language -> Issue body language -> Japanese.

---

## Phase 5: End-to-End Flow Continuation (Output Pattern)

> **This phase is only executed within the end-to-end flow. For standalone execution, skip Phase 5 entirely, display the Phase 4.2 completion report (including "next steps" guidance), and terminate.**

### 5.1 Output Pattern (Return Control to Caller)

| State | Output Pattern |
|-------|---------------|
| PR creation succeeded | `[pr:created:{pr_number}]` |
| PR creation failed | `[pr-create-failed]` |

`rite:pr-review` を Skill で **呼ばない**。caller（orchestrator）に制御を返す。

> **Missing-sentinel recovery contract**: Phase 3.4 が sentinel 無しで無言終了したら、caller は `[pr:created:{N}]` / `[pr-create-failed]` を観測できず **missing-sentinel** として扱う。再開は caller の `/rite:recover`（`skills/open/SKILL.md` ステップ 0 phase=pr / ステップ 6）。
> rationale: references/rationale.md#missing-sentinel-recovery

**Example output:**
```
PR #{pr_number} をドラフトとして作成しました。

[pr:created:123]
```

### 5.2 Behavior During Standalone Execution

standalone は Phase 5 を skip し、Phase 4.2 の完了報告を出して終了する。
