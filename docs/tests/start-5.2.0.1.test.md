# テスト仕様書: start.md 5.2.0.1 範囲外警告の自動 Issue 化

## 概要

`plugins/rite/commands/issue/start.md` の Phase 5.2.0.1「範囲外の警告・エラーの自動 Issue 化」セクションに対するテスト仕様書。

## 対象機能

lint で検出された警告・エラーの中で、今回の変更範囲外のものを別 Issue として自動登録し、GitHub Projects に追加してフィールドを設定する機能。

---

## テストケース

### TC-001: GraphQL クエリの構造確認

**目的**: Project アイテム ID とフィールド情報を取得する GraphQL クエリが正しい構造であることを確認する。

**対象クエリ** (`start.md` 行 2527-2556):

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

**対象コマンド** (`start.md` 行 2567-2576):

```bash
# Status を "Todo" に設定
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {todo_option_id}

# Priority を "Medium" に設定（デフォルト）
gh project item-edit --project-id {project_id} --id {item_id} --field-id {priority_field_id} --single-select-option-id {medium_option_id}

# Complexity を "S" に設定（lint 警告修正は通常 S 規模）
gh project item-edit --project-id {project_id} --id {item_id} --field-id {complexity_field_id} --single-select-option-id {s_option_id}
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
| 8 | Complexity のデフォルト値 | "S" | - |

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

### TC-003: Issue 作成コマンドの整合性確認

**目的**: Issue 作成コマンドが正しいパラメータを使用していることを確認する。

**対象コマンド** (`start.md` 行 2480-2507):

```bash
gh issue create \
  --title "fix(lint): {file_name} の lint 警告を修正" \
  --body "..." \
  --label "lint"
```

**検証項目**:

| # | 検証項目 | 期待値 | 結果 |
|---|---------|--------|------|
| 1 | タイトル形式 | Conventional Commits 形式（`fix(lint): ...`） | - |
| 2 | 本文の必須セクション | `## 概要`, `## 検出された警告`, `## 発生元`, `## 対応` | - |
| 3 | ラベル付与条件 | lint ラベルが存在する場合のみ `--label "lint"` を付与 | - |
| 4 | 本文テンプレートのプレースホルダ | `{line_N}`, `{message_N}`, `{original_issue_number}`, `{timestamp}`, `{branch_name}` | - |

**本文テンプレートの検証**:

```markdown
## 概要

`/rite:issue:start` 実行中の lint で検出された範囲外の警告です。

## 検出された警告

| 行 | 内容 |
|----|------|
| {line_1} | {message_1} |
| {line_2} | {message_2} |

## 発生元

- 元 Issue: #{original_issue_number}
- 検出日時: {timestamp}
- ブランチ: {branch_name}

## 対応

- lint 警告を修正してください
```

---

### TC-004: エラーハンドリングの整合性確認

**目的**: エラーハンドリングのドキュメントが一貫していることを確認する。

**検証項目**:

| # | エラーケース | 期待される動作 | ドキュメント記載 | 結果 |
|---|-------------|--------------|-----------------|------|
| 1 | Issue 作成失敗 | 警告をログ出力し、PR の Known Issues に記載して続行 | `start.md` 行 2602-2621 | - |
| 2 | Project 追加失敗 | （記載なし - 暗黙的に続行と推測） | 要確認 | - |
| 3 | フィールド設定失敗 | 警告を表示して続行 | `start.md` 行 2586 | - |
| 4 | lint ラベル不存在 | ラベルなしで Issue を作成 | `start.md` 行 2509 | - |

**エラーハンドリングの一貫性チェック**:

```
Issue 作成
├─ 成功 → Projects への追加へ
└─ 失敗 → 警告ログ + PR Known Issues に記載 + ワークフロー継続

Projects への追加
├─ 成功 → フィールド設定へ
└─ 失敗 → （未定義 - 要確認）

フィールド設定
├─ 成功 → 完了メッセージ表示
└─ 失敗 → 警告表示 + ワークフロー継続
```

**改善提案**: Projects 追加失敗時の動作を明示的に記載することを検討。

---

### TC-005: フィールド設定値の整合性確認

**目的**: 設定されるフィールド値が `rite-config.yml` の設定と整合していることを確認する。

**検証項目**:

| フィールド | 設定値 | rite-config.yml のオプション | 整合性 |
|-----------|--------|---------------------------|--------|
| Status | Todo | `Todo`, `In Progress`, `In Review`, `Done` | - |
| Priority | Medium | `High`, `Medium`, `Low` | - |
| Complexity | S | `XS`, `S`, `M`, `L`, `XL` | - |

**注**: フィールド設定値は `start.md` 行 2578-2585 に記載。

---

## 改善提案

テストケース作成時に発見された仕様の課題:

### IP-001: Projects 追加失敗時のエラーハンドリング未定義

**発見元**: TC-004 エラーハンドリングの整合性確認

**問題**: `gh project item-add` コマンドが失敗した場合の動作が `start.md` に記載されていない。

**現状の記載**:
- Issue 作成失敗時: 警告ログ + PR Known Issues に記載 + ワークフロー継続（明示的に記載）
- フィールド設定失敗時: 警告表示 + ワークフロー継続（明示的に記載）
- **Projects 追加失敗時: 記載なし**

**提案**: 以下のエラーハンドリングを `start.md` の 5.2.0.1 セクションに追記:

```markdown
**Project 追加失敗時の処理:**

`gh project item-add` コマンドが失敗した場合は警告を表示してフィールド設定をスキップし、ワークフローを継続:

\```
警告: Issue #{issue_number} の Project 追加に失敗しました
エラー: {error_message}

フィールド設定をスキップします。
Issue は作成済みのため、手動で Project に追加してください。
元のワークフローを継続します。
\```
```

**優先度**: Low（ワークフローの継続には影響しない）

---

## 付録: 関連するドキュメント行番号

| セクション | 開始行 | 終了行 |
|-----------|--------|--------|
| 5.2.0.1 範囲外の警告・エラーの自動 Issue 化 | 2427 | 2622 |
| 判定方法 | 2431 | 2459 |
| Issue 自動作成フロー | 2460 | 2509 |
| Projects への追加とフィールド設定 | 2511 | 2600 |
| エラーハンドリング | 2602 | 2621 |

---

## テスト実行記録

| 日付 | テスター | 結果 | 備考 |
|------|---------|------|------|
| - | - | - | - |

---

## 変更履歴

| 日付 | 変更内容 |
|------|---------|
| 2026-01-29 | 初版作成（#260） |
