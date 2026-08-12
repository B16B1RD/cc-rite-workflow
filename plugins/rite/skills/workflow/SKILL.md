---
name: workflow
description: |
  rite ワークフロー全体のガイド (/rite:workflow) を表示する。現在の状態 (初期化状況・
  ブランチ・作業中 Issue) を検出し、ワークフロー全体図・コマンド一覧・次のステップを案内する。
  ユーザーが明示的に /rite:workflow で起動する。auto-activate しない。
  起動: /rite:workflow
argument-hint: ""
---

# /rite:workflow

rite ワークフロー全体のガイドを表示

---

When this command is executed, run the following phases in order.

## Phase 1: Check Current State

### 1.1 Check Initialization Status

Check whether `rite-config.yml` exists in the project root:

```bash
ls rite-config.yml 2>/dev/null || ls .claude/rite-config.yml 2>/dev/null
```

**If it does not exist:**

```
rite workflow が初期化されていません

まず /rite:setup を実行してセットアップを完了してください
```

Stop here and do not execute any subsequent phases.

### 1.2 Check Current Branch and Work Status

```bash
git branch --show-current
```

Detect the active Issue from the branch name:
- Pattern: `{type}/issue-{number}-{slug}`
- Example: `feat/issue-123-add-feature` → issue number `123`

If there is an active Issue, reflect it in the "Next Steps" later.

---

## Phase 2: Display Workflow Overview

> **罫線の表示幅**: box の右罫線 `│` を揃えるには、全角（East Asian Width `W`/`F`）文字を 2 桁として内側幅を上罫線の `─` 本数に一致させる（`A` Ambiguous は 1 桁、フロー図など 2 列 ASCII アートは対象外）。詳細は [`../../references/box-display-width.md`](../../references/box-display-width.md)。

Display the following diagram:

```
📜 rite workflow

┌─────────────────────────────────────────────────────────────┐
│                     ワークフロー全体図                      │
└─────────────────────────────────────────────────────────────┘

  /rite:unknowns <テーマ> (構想フェーズ・任意の前段)
        │  盲点洗い出し・ブレスト・プロトタイプ・インタビュー
        │  → 探索サマリ出力
        ▼
  /rite:issue-list (Issue 確認)
        │
        ▼
  /rite:issue-create (新規 Issue 作成)
        │                              Status: Todo
        ▼
  /rite:open <番号> (実装 → draft PR)
        │                              Status: In Progress
        │  内部: ブランチ作成 → 実装計画 → 実装
        │        → /rite:lint → draft PR 作成
        │  （作業メモリ更新は /rite:issue-update）
        ▼
  /rite:iterate <pr> (レビュー/修正ループ)
        │  内部: /rite:pr-review ⇄ /rite:fix を
        │        mergeable になるまで自律実行
        ▼
  /rite:ready <pr> (レビュー待ちに変更)
        │                              Status: In Review
        ▼
  /rite:merge <pr> (squash マージ)
        │
        ▼
  /rite:cleanup (後片付け)
        │  ブランチ削除・Issue クローズ・Wiki 統合
        ▼
  完了                                 Status: Done

┌─────────────────────────────────────────────────────────────┐
│  Status 遷移: Todo → In Progress → In Review → Done         │
└─────────────────────────────────────────────────────────────┘
```

---

## Phase 3: Display Command List

Display the following list:

```
┌─────────────────────────────────────────────────────────────┐
│                     コマンド一覧                            │
└─────────────────────────────────────────────────────────────┘

【セットアップ】
  /rite:setup           初回セットアップウィザード
  /rite:workflow        このガイドを表示

【構想（任意）】
  /rite:unknowns        実装前探索セッション（盲点洗い出し・ブレスト・プロトタイプ・インタビュー）

【Issue 管理】
  /rite:issue-list      Issue 一覧を表示
  /rite:issue-create    新規 Issue を作成
  /rite:open            Issue の作業を開始（実装 → draft PR）
  /rite:issue-update    作業メモリを更新
  /rite:issue-close     Issue の完了状態を確認

【PR 管理】
  /rite:iterate         レビュー/修正ループ（review ⇄ fix を自律実行）
  /rite:ready           Ready for review に変更
  /rite:merge           PR を squash マージ
  /rite:cleanup         マージ後クリーンアップ（ブランチ削除・Issue クローズ）
  /rite:pr-create       ドラフト PR を作成（Issue なしの単発 PR 用）

【ユーティリティ】
  /rite:lint            品質チェックを実行
  /rite:template-reset  テンプレートを再生成
  /rite:recover          中断した作業を再開

💡 Tips: Context limit reached で中断した場合は /clear → /rite:recover で再開できます
💡 Tips: 複数セッションで別 Issue を並行する場合、rite-config.yml の
         multi_session.enabled: true（デフォルト ON）により
         セッション別 worktree (.rite/worktrees/issue-{N}) に分離されます
```

---

## Phase 4: Suggest Next Steps

Based on the state confirmed in Phase 1, suggest the next action.

### 4.1 If There Is an Active Issue

```
┌─────────────────────────────────────────────────────────────┐
│                     現在の作業状況                          │
└─────────────────────────────────────────────────────────────┘

  現在のブランチ: {branch-name}
  作業中の Issue: #{issue-number}

  【次のステップ】
  1. 実装を続ける（/rite:open が lint → draft PR 作成まで実行します）
  2. /rite:issue-update で作業メモリを更新
  3. draft PR 作成後は /rite:iterate <pr> でレビュー/修正ループ
  4. /rite:ready <pr> → /rite:merge <pr> → /rite:cleanup で完了
```

> **multi-session 時の注意**: `multi_session.enabled: true` の場合、この作業は
> セッション worktree（`.rite/worktrees/issue-{N}`）内で進行しています。中断後は
> `/rite:recover` がその worktree へ自動で再入場します（消失していればブランチから
> 再構築）。main checkout のカレントブランチは base（`branch.base`）のままにしておく
> こと — rite は main checkout のブランチを切り替えません。詳細は
> `docs/designs/multi-session-worktree.md` 参照。

> `{owner_repo}` は [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute する。

Retrieve and display the Issue details:

```bash
gh issue view {issue-number} -R {owner_repo} --json title,body,state
```

### 4.2 If There Is No Active Issue

```
┌─────────────────────────────────────────────────────────────┐
│                     クイックスタート                        │
└─────────────────────────────────────────────────────────────┘

  【新しいタスクを始める】
  1. /rite:issue-list で既存 Issue を確認
  2. /rite:issue-create <説明> で新規 Issue を作成
     または
     /rite:open <番号> で既存 Issue の作業を開始

  【例】
  - /rite:issue-create ログイン機能を追加
  - /rite:open 42
```

---

## Phase 5: Display Additional Information (Optional)

Display additional information depending on the project state.

### 5.1 Number of Open Issues

```bash
gh issue list -R {owner_repo} --state open --json number --jq 'length'
```

### 5.2 Number of Open PRs

```bash
gh pr list -R {owner_repo} --state open --json number --jq 'length'
```

Display the results:

```
┌─────────────────────────────────────────────────────────────┐
│                     プロジェクト状況                        │
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
| Tips | `💡 Tips: Context limit reached で中断した場合は /clear → /rite:recover で再開できます` | `💡 Tips: If interrupted by context limit, run /clear → /rite:recover to resume` |

**Note**: Status values (Todo, In Progress, etc.) use the GitHub Projects setting values as-is, so they are common regardless of the language setting.
