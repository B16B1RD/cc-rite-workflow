# テスト仕様書: Issue #358 スキル構造改善の検証

## 概要

Issue #358「rite workflow スキル構造の改善（PDFガイド準拠）」の実装後検証テスト。

## 対象機能

- スキルトリガーフレーズの認識
- Progressive Disclosure（references/の活用）
- 既存機能の回帰テスト

## テストケース

### TC-001: rite-workflow スキルトリガーテスト

#### 目的
`plugins/rite/skills/rite-workflow/SKILL.md` のトリガーフレーズが正しく定義されているか確認

#### 検証項目

| トリガーフレーズ | 言語 | 期待動作 |
|----------------|------|---------|
| start issue | 英語 | rite-workflow スキルがアクティブ化 |
| create PR | 英語 | rite-workflow スキルがアクティブ化 |
| next steps | 英語 | rite-workflow スキルがアクティブ化 |
| workflow | 英語 | rite-workflow スキルがアクティブ化 |
| rite | 英語 | rite-workflow スキルがアクティブ化 |
| branch naming | 英語 | rite-workflow スキルがアクティブ化 |
| commit format | 英語 | rite-workflow スキルがアクティブ化 |
| Issue作業 | 日本語 | rite-workflow スキルがアクティブ化 |
| ブランチ | 日本語 | rite-workflow スキルがアクティブ化 |
| コミット規約 | 日本語 | rite-workflow スキルがアクティブ化 |
| PR作成 | 日本語 | rite-workflow スキルがアクティブ化 |
| 作業開始 | 日本語 | rite-workflow スキルがアクティブ化 |
| ワークフロー | 日本語 | rite-workflow スキルがアクティブ化 |
| 次のステップ | 日本語 | rite-workflow スキルがアクティブ化 |
| ブランチ命名 | 日本語 | rite-workflow スキルがアクティブ化 |

#### 結果
- [x] PASS: description フィールドに全トリガーフレーズが含まれていることを確認

### TC-002: reviewers スキルトリガーテスト

#### 目的
`plugins/rite/skills/reviewers/SKILL.md` のトリガーフレーズが正しく定義されているか確認

#### 検証項目

| トリガーフレーズ | 言語 | 期待動作 |
|----------------|------|---------|
| code review | 英語 | reviewers スキルがアクティブ化 |
| PR feedback | 英語 | reviewers スキルがアクティブ化 |
| security check | 英語 | reviewers スキルがアクティブ化 |
| review my changes | 英語 | reviewers スキルがアクティブ化 |
| レビューして | 日本語 | reviewers スキルがアクティブ化 |
| PRレビュー | 日本語 | reviewers スキルがアクティブ化 |
| コードチェック | 日本語 | reviewers スキルがアクティブ化 |
| セキュリティ確認 | 日本語 | reviewers スキルがアクティブ化 |
| 変更を確認 | 日本語 | reviewers スキルがアクティブ化 |
| コードレビュー | 日本語 | reviewers スキルがアクティブ化 |

#### 結果
- [x] PASS: description フィールドに全トリガーフレーズが含まれていることを確認

### TC-003: Progressive Disclosure テスト - rite-workflow

#### 目的
`plugins/rite/skills/rite-workflow/references/` 配下のファイルが適切に参照されるか確認

#### 検証項目

| ファイル | SKILL.md での参照 | 参照形式 |
|---------|------------------|---------|
| `references/session-detection.md` | あり | `[references/session-detection.md](./references/session-detection.md)` |
| `references/phase-mapping.md` | あり | `[references/phase-mapping.md](./references/phase-mapping.md)` |
| `references/work-memory-format.md` | あり | `[references/work-memory-format.md](./references/work-memory-format.md)` |

#### 結果
- [x] PASS: 全ファイルが SKILL.md から正しく参照されていることを確認

### TC-004: Progressive Disclosure テスト - reviewers

#### 目的
`plugins/rite/skills/reviewers/references/` 配下のファイルが適切に参照されるか確認

#### 検証項目

| ファイル | SKILL.md での参照 | 参照形式 |
|---------|------------------|---------|
| `references/cross-validation.md` | あり | `[references/cross-validation.md](./references/cross-validation.md)` |
| `references/context-management.md` | あり | `[references/context-management.md](./references/context-management.md)` |
| `references/output-format.md` | あり | `[references/output-format.md](./references/output-format.md)` |

#### 結果
- [x] PASS: 全ファイルが SKILL.md から正しく参照されていることを確認

### TC-005: 既存コマンド回帰テスト - /rite:issue:start

#### 目的
既存コマンドが変更後も正常に動作することを確認

#### 検証手順
1. `/rite:issue:start 361` を実行
2. ブランチ作成、Projects Status 更新、作業メモリ初期化が正常に動作することを確認

#### 期待される動作
- ブランチ名が `{type}/issue-{number}-{slug}` パターンで生成される
- GitHub Projects の Status が "In Progress" に更新される
- Issue に作業メモリコメントが追加される

#### 結果
- [x] PASS: Issue #361 の作業開始で正常動作を確認

### TC-006: 既存コマンド回帰テスト - /rite:issue:list

#### 目的
既存コマンドが変更後も正常に動作することを確認

#### 検証手順
1. `/rite:issue:list` を実行
2. オープンな Issue の一覧が表示されることを確認

#### 結果
- [x] PASS: Issue 一覧が正常に表示されることを確認

## テスト実行記録

| 日時 | 実行者 | 結果 | 備考 |
|------|--------|------|------|
| 2026-02-01 | Claude | PASS | 全テストケース合格 |

## 変更履歴

| 日付 | バージョン | 変更内容 |
|------|-----------|---------|
| 2026-02-01 | 1.0 | 初版作成 |
