# テスト仕様書: cleanup.md 1.7.3.2.1 Projects への追加とフィールド設定

## 概要

`plugins/rite/commands/pr/cleanup.md` の Phase 1.7.3.2.1「Projects への追加とフィールド設定」セクションに対するテスト仕様書。

## 対象機能

`/rite:pr:cleanup` 実行時に、未完了タスクから作成した Issue を GitHub Projects に追加し、Status/Priority/Complexity フィールドを設定する機能。

---

## テストケース

### TC-001: GraphQL クエリの構造確認

**目的**: Project アイテム ID とフィールド情報を取得する GraphQL クエリが正しい構造であることを確認する。

**対象クエリ** (`cleanup.md` Phase 1.7.3.2.1):

```graphql
query($owner: String!, $projectNumber: Int!, $issueNumber: Int!) {
  user(login: $owner) {
    projectV2(number: $projectNumber) {
      id
      items(last: 20) {
        nodes {
          id
          content {
            ... on Issue {
              number
            }
          }
        }
      }
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
            }
          }
        }
      }
    }
  }
}
```

**検証項目**:

| # | 検証項目 | 期待値 | 結果 |
|---|---------|--------|------|
| 1 | クエリ変数の型 | `$owner: String!`, `$projectNumber: Int!`, `$issueNumber: Int!` | - |
| 2 | user/organization の切り替え | owner が個人の場合 `user`, Organization の場合 `organization` を使用 | - |
| 3 | items の取得数 | `last: 20` で最新 20 件を取得（追加直後の Issue を確実に含むため） | - |
| 4 | fields の取得数 | `first: 20` で最大 20 フィールドを取得 | - |
| 5 | SingleSelectField のフラグメント | `... on ProjectV2SingleSelectField` で Status/Priority/Complexity を取得可能 | - |

**手動検証手順**:

```bash
# 実際のリポジトリで検証（B16B1RD/cc-rite-workflow の場合）
gh api graphql -f query='
query($owner: String!, $projectNumber: Int!) {
  user(login: $owner) {
    projectV2(number: $projectNumber) {
      id
      items(last: 5) {
        nodes {
          id
          content {
            ... on Issue {
              number
            }
          }
        }
      }
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
            }
          }
        }
      }
    }
  }
}' -f owner="B16B1RD" -F projectNumber=2
```

**期待される出力構造**:

```json
{
  "data": {
    "user": {
      "projectV2": {
        "id": "PVT_...",
        "items": {
          "nodes": [
            {
              "id": "PVTI_...",
              "content": {
                "number": 123
              }
            }
          ]
        },
        "fields": {
          "nodes": [
            {
              "id": "PVTSSF_...",
              "name": "Status",
              "options": [
                { "id": "...", "name": "Todo" },
                { "id": "...", "name": "In Progress" }
              ]
            }
          ]
        }
      }
    }
  }
}
```

---

### TC-002: フィールド設定コマンドのパラメータ確認

**目的**: `gh project item-edit` コマンドのパラメータが正しいことを確認する。

**対象コマンド** (`cleanup.md` Phase 1.7.3.2.1):

```bash
# Status を "Todo" に設定
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {todo_option_id}

# Priority を "Medium" に設定（デフォルト）
gh project item-edit --project-id {project_id} --id {item_id} --field-id {priority_field_id} --single-select-option-id {medium_option_id}

# Complexity を設定（Phase 1.7.1 で判定した複雑度を使用）
gh project item-edit --project-id {project_id} --id {item_id} --field-id {complexity_field_id} --single-select-option-id {complexity_option_id}
```

**検証項目**:

| # | 検証項目 | 期待値 | 結果 |
|---|---------|--------|------|
| 1 | 必須パラメータ | `--project-id`, `--id`, `--field-id`, `--single-select-option-id` の 4 つ | - |
| 2 | project_id の形式 | `PVT_` プレフィックスで始まる ID | - |
| 3 | item_id の形式 | `PVTI_` プレフィックスで始まる ID | - |
| 4 | field_id の形式 | `PVTSSF_` プレフィックスで始まる ID（SingleSelectField の場合） | - |
| 5 | option_id の形式 | 8 文字の 16 進数文字列（例: `d24629fd`） | - |
| 6 | Status のデフォルト値 | "Todo" | - |
| 7 | Priority のデフォルト値 | "Medium" | - |
| 8 | Complexity の値 | Phase 1.7.1 で判定した複雑度（XS, S, M, L, XL） | - |

**手動検証手順**:

```bash
# 1. テスト用 Issue を作成
gh issue create --title "テスト Issue" --body "テスト" --repo B16B1RD/cc-rite-workflow

# 2. Project に追加
gh project item-add 2 --owner B16B1RD --url <issue_url>

# 3. フィールド設定を実行（ID は実際の値に置き換え）
gh project item-edit \
  --project-id PVT_kwHOAA1CPM4BLyhq \
  --id PVTI_... \
  --field-id PVTSSF_lAHOAA1CPM4BLyhqzg7Qiro \
  --single-select-option-id d24629fd

# 4. 設定が反映されたことを確認
gh project item-list 2 --owner B16B1RD --format json | jq '.items[] | select(.content.number == <issue_number>)'

# 5. テスト Issue をクローズ
gh issue close <issue_number> --repo B16B1RD/cc-rite-workflow
```

---

### TC-003: Project 追加コマンドの確認

**目的**: Issue を Project に追加するコマンドが正しいパラメータを使用していることを確認する。

**対象コマンド** (`cleanup.md` Phase 1.7.3.2.1):

```bash
gh project item-add {project_number} --owner {owner} --url {issue_url}
```

**検証項目**:

| # | 検証項目 | 期待値 | 結果 |
|---|---------|--------|------|
| 1 | project_number | rite-config.yml の `github.projects.project_number` から取得 | - |
| 2 | owner | rite-config.yml の `github.projects.owner` から取得 | - |
| 3 | issue_url | `gh issue create` の出力から取得 | - |

---

### TC-004: フィールド設定値の整合性確認（start.md との差異）

**目的**: `cleanup.md` と `start.md` の Phase 5.2.0.1 でのフィールド設定値の違いを確認する。

**検証項目**:

| フィールド | cleanup.md 1.7.3.2.1 | start.md 5.2.0.1 | 理由 |
|-----------|---------------------|------------------|------|
| Status | Todo | Todo | 新規作成のため（同じ） |
| Priority | Medium | Medium | デフォルト優先度（同じ） |
| **Complexity** | **Phase 1.7.1 で判定した値** | **S（固定）** | cleanup は残作業の複雑度を反映、start は lint 警告修正のため S 固定 |

**注**: Complexity の違いは意図的な設計。

- `start.md` 5.2.0.1: lint 警告修正は通常単一ファイルの修正なので S 固定
- `cleanup.md` 1.7.3.2.1: 未完了タスクの複雑度は Phase 1.7.1 で個別に判定

---

### TC-005: エラーハンドリングの確認

**目的**: エラー発生時の動作が適切に定義されていることを確認する。

**検証項目**:

| # | エラーケース | 期待される動作 | ドキュメント記載 | 結果 |
|---|-------------|--------------|-----------------|------|
| 1 | フィールド設定失敗 | 警告を表示して続行 | `cleanup.md` Phase 1.7.3.2.1 「注」 | - |
| 2 | Projects 未設定 | 1.7.3.2.1 全体をスキップ | `cleanup.md` Phase 1.7.3.2.1 「Projects 未設定の場合」 | - |

**エラーハンドリングの一貫性チェック**:

```
Issue 作成
├─ 成功 → Projects への追加へ
└─ 失敗 → エラーハンドリング（Phase 1.7.3.3 後の別処理）

Projects への追加
├─ 成功 → フィールド設定へ
└─ 失敗 → （暗黙的にフィールド設定をスキップ）

フィールド設定
├─ 成功 → 完了
└─ 失敗 → 警告表示 + 続行
```

---

### TC-006: rite-config.yml の前提条件確認

**目的**: Projects 機能が有効な場合の前提条件が満たされていることを確認する。

**検証項目**:

| # | 設定項目 | パス | 期待値 | 結果 |
|---|---------|------|--------|------|
| 1 | Projects 有効化 | `github.projects.enabled` | `true` | - |
| 2 | Project 番号 | `github.projects.project_number` | 正の整数 | - |
| 3 | オーナー | `github.projects.owner` | ユーザー名または組織名 | - |

**手動検証手順**:

```bash
# rite-config.yml の設定を確認
cat rite-config.yml | yq '.github.projects'
```

---

## 改善提案

テストケース作成時に発見された仕様の課題:

### IP-001: Projects 追加失敗時のエラーハンドリング未定義

**発見元**: TC-005 エラーハンドリングの確認

**問題**: `gh project item-add` コマンドが失敗した場合の動作が `cleanup.md` に明示的に記載されていない。

**現状の記載**:
- フィールド設定失敗時: 警告表示 + ワークフロー継続（明示的に記載）
- **Projects 追加失敗時: 記載なし**

**提案**: 以下のエラーハンドリングを `cleanup.md` の Phase 1.7.3.2.1 セクションに追記:

```markdown
**Project 追加失敗時の処理:**

`gh project item-add` コマンドが失敗した場合は警告を表示してフィールド設定をスキップし、ワークフローを継続:

\```
警告: Issue #{issue_number} の Project 追加に失敗しました
エラー: {error_message}

フィールド設定をスキップします。
Issue は作成済みのため、手動で Project に追加してください。
\```
```

**優先度**: Low（ワークフローの継続には影響しない）

**注**: `start.md` 5.2.0.1 にも同様の課題あり（IP-001 として既に報告済み: `start-5.2.0.1.test.md`）

---

## 付録: cleanup.md と start.md の対応関係

| cleanup.md | start.md | 説明 |
|------------|----------|------|
| Phase 1.7.3.2.1 Projects への追加とフィールド設定 | Phase 5.2.0.1 範囲外警告の自動 Issue 化 | Issue 作成後の Projects 登録処理 |

両者は類似の処理を行うが、以下の点で異なる:

1. **トリガー条件**: cleanup は未完了タスク、start は範囲外 lint 警告
2. **Complexity の決定方法**: cleanup は Phase 1.7.1 で判定、start は S 固定
3. **Issue 本文テンプレート**: 異なる（cleanup は残作業テンプレート、start は lint 警告テンプレート）

---

## テスト実行記録

| 日付 | テスター | 結果 | 備考 |
|------|---------|------|------|
| - | - | - | - |

---

## 変更履歴

| 日付 | 変更内容 |
|------|---------|
| 2026-01-30 | 初版作成（#303） |
