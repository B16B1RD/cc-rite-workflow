---
name: skill-suggest
description: |
  rite workflow のスキル提案ヘルパー: 現在のコンテキストを分析し適用可能な rite スキルを提案する。
  ユーザーが明示的に /rite:skill-suggest で起動する。auto-activate しない。
  起動: /rite:skill-suggest
argument-hint: ""
---

# /rite:skill-suggest

現在のコンテキスト（Issue、変更ファイル、作業状態）を分析し、適用可能なスキルを提案する。次の Phase を順に実行する。

## Phase 1: Context Collection

### 1.1 Identify Current Branch and Issue

```bash
# 現在のブランチ名を取得
git branch --show-current

# ブランチ名から Issue 番号を抽出（パターン: **/issue-{number}-*）
# 例: feat/issue-278-skill-suggest → 278
```

> `{owner_repo}` は [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute する。

If an Issue number can be extracted from the branch name, retrieve Issue information:

```bash
gh issue view {issue_number} -R {owner_repo} --json number,title,body,labels
```

### 1.2 Collect Changed Files

```bash
# ステージ済み・未ステージの変更ファイル
git status --porcelain

# 最近のコミット（直近 5 件）の変更ファイル
git log --oneline -5 --name-only
```

### 1.3 Working Directory Structure

Collect information to determine the project type:

```bash
# プロジェクト設定ファイルの存在確認
ls -la package.json pyproject.toml Cargo.toml go.mod pom.xml build.gradle 2>/dev/null
```

### 1.4 Read rite-config.yml

Use the Read tool to read `rite-config.yml` and check the following:

- `language`: Language setting (used to determine output language)

---

## Phase 2: Retrieve Available Skills List

### 2.1 Search for Skill Files

Use the Glob tool to search for skill files:

```
Glob: plugins/**/SKILL.md
Glob: plugins/**/*.skill.md
```

rationale: references/rationale.md#glob-not-find

### 2.2 Collect Information for Each Skill

Extract the following from each discovered skill file:

| Field | Source | Extraction Method |
|-------|--------|-------------------|
| Skill name | Directory or file name | Extract the `{name}` part from path `skills/{name}/SKILL.md` |
| Description | Beginning of file | The paragraph text immediately after the first `#` heading |
| Keywords | `## Auto-Activation Keywords` section | Collect list items (lines starting with `-`) as an array |
| Applicability conditions | `## Context` section | Get the description text within the section (including condition statements like "When activated") |

**Extraction example (for rite-workflow/SKILL.md):**

```
スキル名: rite-workflow
説明: "This skill provides context for rite workflow operations."
キーワード: ["Issue", "PR", "Pull Request", "workflow", "rite", "branch", "commit", ...]
適用条件: "When activated, this skill provides: Workflow Awareness, Command Guidance, ..."
```

---

## Phase 3: Skill Matching

Phase 1 のコンテキストと Phase 2 のスキル情報を突き合わせ、**現在の作業に関連する rite スキルを関連度順に選ぶ**。数値スコアや重み付け表は使わない。
rationale: references/rationale.md#no-numeric-score

**判断の観点**（ヒントであり網羅ではない）:

- Issue の内容・ラベルとスキルの目的が噛み合うか（キーワードの表面一致ではなく、作業の種類とスキルの守備範囲で判断する）
- 変更ファイルの種類・場所がスキルの対象領域に入るか（reviewer 系は `skills/reviewers/SKILL.md` の Available Reviewers 表の `Activation` 列が対象領域の SoT）
- 現在のワークフロー状態（着手前 / 実装中 / レビュー待ち / merge 後 等）でそのスキルを使う局面か

**出力の分類**（Phase 4 の表示契約）: 関連度の高い順に【強く推奨】/【推奨】。薄いスキルは含めない。各提案に適用理由（`{reason}`）を必ず添える。

---

## Phase 4: Display Suggestions

### 4.1 Check Language Setting

Determine the output language according to the `language` setting read in Phase 1.4:

| Setting | Behavior |
|---------|----------|
| `auto` | Detect the user's input language and display in the same language |
| `ja` | Display messages in Japanese |
| `en` | Display messages in English |

### 4.2 When Recommended Skills Exist

> **罫線の表示幅**: box の右罫線 `│` を揃えるには、全角（East Asian Width `W`/`F`）文字を 2 桁として内側幅を上罫線の `─` 本数に一致させる（`A` Ambiguous は 1 桁）。詳細は [`../../references/box-display-width.md`](../../references/box-display-width.md)。

```
┌─────────────────────────────────────────────────────────────┐
│  スキル提案                                                 │
└─────────────────────────────────────────────────────────────┘

現在のコンテキスト:
  Issue: #{number} {title}
  ブランチ: {branch_name}
  変更ファイル: {changed_files_count} 件

───────────────────────────────────────────────────────────────

【強く推奨】

  📌 {skill_name}
     {skill_description}

     適用理由:
     - {reason_1}
     - {reason_2}

     適用方法: このスキルは自動的に適用されます

【推奨】

  📎 {skill_name}
     {skill_description}

     適用理由:
     - {reason_1}

───────────────────────────────────────────────────────────────

【参考情報】
- 上記スキルは現在のコンテキストに基づいて提案されています
- スキルは skills/ ディレクトリの SKILL.md で定義されています
```

### 4.3 When No Recommended Skills Exist

```
┌─────────────────────────────────────────────────────────────┐
│  スキル提案                                                 │
└─────────────────────────────────────────────────────────────┘

現在のコンテキスト:
  Issue: #{number} {title}
  ブランチ: {branch_name}
  変更ファイル: {changed_files_count} 件

───────────────────────────────────────────────────────────────

現在のコンテキストに特に推奨されるスキルはありません。

利用可能なスキル一覧:
- {skill_name}: {skill_description}
- {skill_name}: {skill_description}

スキルは作業内容に応じて自動的に適用されます。
```

### 4.4 When Context Information Is Missing or Incomplete

When the Issue number cannot be determined (no `issue-{number}` pattern in branch name) or there are no changed files (empty git diff):

```
┌─────────────────────────────────────────────────────────────┐
│  スキル提案                                                 │
└─────────────────────────────────────────────────────────────┘

コンテキスト情報が不足しています:

{missing_info_list}

【対処方法】
- Issue を紐づけたブランチで作業してください
- /rite:open {number} で作業を開始すると、ブランチと Issue が自動的に紐づきます

利用可能なスキル一覧:
- {skill_name}: {skill_description}
```

---

## Phase 5: Optional Features

### 5.1 Verbose Mode (`--verbose`)

When `--verbose` or `-v` is specified as an argument, display the matching rationale for each suggested skill:

```
【マッチング詳細】

{skill_name}: 【強く推奨】
  - Issue 内容: {Issue の作業種別とスキルの目的がどう噛み合うか}
  - 変更ファイル: {スキルの対象領域との重なり}
  - ワークフロー状態: {現在の局面との適合}
```

### 5.2 Filter Mode (`--filter {category}`)

Display only skills in a specific category:

```bash
/rite:skill-suggest --filter review    # レビュー関連のスキルのみ
/rite:skill-suggest --filter workflow  # ワークフロー関連のスキルのみ
```

**Available categories:**

| Category | Description | Target Skills |
|----------|-------------|---------------|
| `workflow` | Workflow-related | rite-workflow |
| `review` | Review-related | reviewers/* |

**Dynamic category retrieval:**

Categories are dynamically retrieved from the directory structure of `{plugin_root}/skills/` (resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version)):
- `skills/{category}/SKILL.md` -> category name is `{category}`
- `skills/reviewers/*.md` -> included in category `review` (現状は coordination `SKILL.md` のみ。個別 reviewer 定義は `agents/*-reviewer.md` に移動済み)

**Note**: When a skill is not assigned to a category or a non-existent category is specified:

```
警告: カテゴリ '{category}' に一致するスキルが見つかりません

利用可能なカテゴリ:
- workflow
- review

すべてのスキルを表示するには --filter オプションを省略してください。
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Outside a Git Repository | See error output for details |
| When No Skill Files Are Found | See error output for details |

## Usage Examples

```
/rite:skill-suggest                    # 現在のコンテキストに基づいてスキルを提案
/rite:skill-suggest --verbose          # 詳細なマッチング情報を表示
/rite:skill-suggest -v                 # --verbose の短縮形
/rite:skill-suggest --filter review    # レビュー関連スキルのみ表示
```
