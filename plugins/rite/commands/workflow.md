---
description: rite ワークフロー全体のガイドを表示
context: fork
---

# /rite:workflow

rite ワークフロー全体のガイドを表示

---

When this command is executed, run the following phases in order.

## Phase 1: Check Current State

### 1.1 Check Initialization Status

Check whether `rite-config.yml` exists in the project root:

```bash
ls rite-config.yml 2>/dev/null || ls .claude/rite:config.yml 2>/dev/null
```

**If it does not exist:**

```
{i18n:workflow_not_initialized}

{i18n:workflow_run_init}
```

Stop here and do not execute any subsequent phases.

### 1.2 Check Current Branch and Work Status

```bash
git branch --show-current
```

Detect the active Issue from the branch name:
- Pattern: `{type}/issue-{number}-{slug}`
- Example: `feat/issue-123-add-feature` → Issue #123

If there is an active Issue, reflect it in the "Next Steps" later.

---

## Phase 2: Display Workflow Overview

Display the following diagram:

```
📜 rite workflow

┌─────────────────────────────────────────────────────────────┐
│                     ワークフロー全体図                        │
└─────────────────────────────────────────────────────────────┘

  /rite:issue:list (Issue 確認)
        │
        ▼
  /rite:issue:create (新規 Issue 作成)
        │                              Status: Todo
        ▼
  /rite:issue:start <番号> (ブランチ作成)
        │                              Status: In Progress
        ▼
  ┌─────────────────────┐
  │     実装作業        │
  │  └─ /rite:issue:update │ (作業メモリ更新)
  └─────────────────────┘
        │
        ▼
  /rite:lint (品質チェック)
        │
        ▼
  /rite:pr:create (ドラフト PR 作成)
        │
        ▼
  /rite:pr:review (セルフレビュー)
        │
        ▼
  ┌───指摘あり？──┐
  │               │
  YES             NO
  │               │
  ▼               │
  /rite:pr:fix     │
  (指摘対応)      │
  │               │
  └─→ /rite:pr:review  │
     (再レビュー)    │
     └─→ (ループ)    │
                     ▼
              /rite:pr:ready (レビュー待ちに変更)
                     │                              Status: In Review
                     ▼
              PR マージ → Issue 自動クローズ       Status: Done

┌─────────────────────────────────────────────────────────────┐
│  Status 遷移: Todo → In Progress → In Review → Done        │
└─────────────────────────────────────────────────────────────┘
```

---

## Phase 3: Display Command List

Display the following list:

```
┌─────────────────────────────────────────────────────────────┐
│                     コマンド一覧                             │
└─────────────────────────────────────────────────────────────┘

【セットアップ】
  /rite:init            初回セットアップウィザード
  /rite:workflow        このガイドを表示

【Issue 管理】
  /rite:issue:list      Issue 一覧を表示
  /rite:issue:create    新規 Issue を作成
  /rite:issue:start     Issue の作業を開始（ブランチ作成）
  /rite:issue:update    作業メモリを更新
  /rite:issue:close     Issue の完了状態を確認

【PR 管理】
  /rite:pr:create       ドラフト PR を作成
  /rite:pr:ready        Ready for review に変更
  /rite:pr:review       マルチレビュアーレビュー

【ユーティリティ】
  /rite:lint            品質チェックを実行
  /rite:template:reset  テンプレートを再生成
  /rite:resume          中断した作業を再開

💡 Tips: Context limit reached で中断した場合は /clear → /rite:resume で再開できます
```

---

## Phase 4: Suggest Next Steps

Based on the state confirmed in Phase 1, suggest the next action.

### 4.1 If There Is an Active Issue

```
┌─────────────────────────────────────────────────────────────┐
│                     現在の作業状況                           │
└─────────────────────────────────────────────────────────────┘

  現在のブランチ: {branch-name}
  作業中の Issue: #{issue-number}

  【次のステップ】
  1. 実装を続ける
  2. /rite:issue:update で作業メモリを更新
  3. 完了したら /rite:lint で品質チェック
  4. /rite:pr:create でドラフト PR を作成
```

Retrieve and display the Issue details:

```bash
gh issue view {issue-number} --json title,body,state
```

### 4.2 If There Is No Active Issue

```
┌─────────────────────────────────────────────────────────────┐
│                     クイックスタート                         │
└─────────────────────────────────────────────────────────────┘

  【新しいタスクを始める】
  1. /rite:issue:list で既存 Issue を確認
  2. /rite:issue:create <説明> で新規 Issue を作成
     または
     /rite:issue:start <番号> で既存 Issue の作業を開始

  【例】
  - /rite:issue:create ログイン機能を追加
  - /rite:issue:start 42
```

---

## Phase 5: Display Additional Information (Optional)

Display additional information depending on the project state.

### 5.1 Number of Open Issues

```bash
gh issue list --state open --json number --jq 'length'
```

### 5.2 Number of Open PRs

```bash
gh pr list --state open --json number --jq 'length'
```

Display the results:

```
┌─────────────────────────────────────────────────────────────┐
│                     プロジェクト状況                         │
└─────────────────────────────────────────────────────────────┘

  オープン Issue: {count} 件
  オープン PR: {count} 件
```
## Language Support

During the initialization check in Phase 1.1, read the `language` field from `rite-config.yml` using the Read tool, and determine the output language for Phase 2 onward.

| Setting | Behavior |
|---------|----------|
| `auto` | Detect the user's input language and display in the same language |
| `ja` | Display messages in Japanese |
| `en` | Display messages in English |

**Language detection priority** (when set to `auto`):
1. The language the user used when executing the command
2. Default: Japanese

**Dynamic language switching implementation:**

The workflow diagram and command list in Phase 2 should switch output according to the determined language. The following table shows representative examples — all user-facing text in the templates should be switched similarly:

| Element | Japanese (`ja`) | English (`en`) |
|---------|-----------------|----------------|
| Header | `ワークフロー全体図` | `Workflow Overview` |
| Status display | `Status: Todo` | `Status: Todo` (common) |
| Section heading | `【セットアップ】` | `【Setup】` |
| Action guidance | `次のステップ:` | `Next Steps:` |
| Tips | `💡 Tips: Context limit reached で中断した場合は /clear → /rite:resume で再開できます` | `💡 Tips: If interrupted by context limit, run /clear → /rite:resume to resume` |

**Note**: Status values (Todo, In Progress, etc.) use the GitHub Projects setting values as-is, so they are common regardless of the language setting.
