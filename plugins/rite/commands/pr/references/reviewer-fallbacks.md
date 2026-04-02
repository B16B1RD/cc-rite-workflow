# Reviewer Fallback Profiles

Built-in minimal profiles for when skill files (`skills/reviewers/*.md`) cannot be loaded.

**Relationship between fallback and official skill files:**

| Item | Description |
|------|------|
| Official definition | Each skill file (`skills/reviewers/*.md`) is the source of truth |
| Fallback | Minimal profile for when skill file loading fails |
| Sync policy | Fallbacks are intentionally simplified. Full sync with official skills is not required |
| Update timing | Only add a fallback when adding a new reviewer. No changes to existing content needed |

**Note**: Fallbacks are minimal emergency configurations and do not need to reproduce all features of the official skill files.

**Warning output requirement**: When a fallback profile is used instead of the official skill file, the reviewer MUST output the following warning at the beginning of its review. Note: `{plugin_root}` is resolved by the caller (`review.md` Phase 4) via [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script) before this template is used.

```
⚠️ フォールバックプロファイルを使用中: {reviewer_type} のスキルファイル読み込みに失敗しました。
最小限のチェックリストで実行しています。完全なレビューには skill file の修復が必要です。

原因の確認:
- {plugin_root}/skills/reviewers/{reviewer_type}.md が存在するか確認
- ファイルの読み取り権限を確認
- プラグインの再インストールを検討: /rite:init
```

This ensures that the degradation is visible to the user and the root cause is not hidden.

## Security Expert
```
重点チェック: 入力検証、認証・認可、機密情報、OWASP Top 10、SQLインジェクション、XSS、CSRF
評価基準: 重大（脆弱性存在）/ 警告（潜在リスク）/ 可（問題なし）
```

## DevOps Expert
```
重点チェック: CI/CD影響、Docker構成、環境変数・シークレット、ビルド・デプロイ影響
評価基準: 重大（デプロイ影響）/ 警告（改善余地）/ 可（問題なし）
```

## Prompt Engineer
```
重点チェック: プロンプト明確さ、指示曖昧さ、フェーズ整合性、エラーハンドリング、実行可能性
評価基準: 重大（実行不能）/ 警告（曖昧指示）/ 可（問題なし）
```

## Technical Writer
```
重点チェック: 文書正確性、文章明確さ、コード例動作、リンク切れ、対象読者適切さ
評価基準: 重大（誤情報）/ 警告（改善余地）/ 可（問題なし）
```

## Test Expert
```
重点チェック: カバレッジ妥当性、エッジケース、Flaky test、可読性、モック・スタブ適切性
評価基準: 重大（テスト不足・信頼性問題）/ 警告（カバレッジ改善）/ 可（問題なし）
```

## API Design Expert
```
重点チェック: RESTful原則、エラーレスポンス一貫性、APIバージョニング、認証・認可設計
評価基準: 重大（重大設計問題）/ 警告（改善余地）/ 可（問題なし）
```

## Frontend Expert
```
重点チェック: コンポーネント設計、アクセシビリティ（WCAG）、パフォーマンス、レスポンシブ
評価基準: 重大（UX重大影響）/ 警告（改善余地）/ 可（問題なし）
```

## Database Expert
```
重点チェック: スキーマ設計、クエリパフォーマンス（N+1）、インデックス、マイグレーション安全性
評価基準: 重大（データ損失・パフォーマンス問題）/ 警告（最適化余地）/ 可（問題なし）
```

## Dependencies Expert
```
重点チェック: 新規依存妥当性、セキュリティ脆弱性（CVE）、ライセンス互換性、バージョン互換性
評価基準: 重大（セキュリティ・ライセンス問題）/ 警告（改善余地）/ 可（問題なし）
```

## Code Quality Expert
```
重点チェック: コード重複、命名規則、エラー処理、構造・複雑度、デッドコード
評価基準: 重大（保守性に重大影響）/ 警告（品質改善余地）/ 可（問題なし）
```

## Performance Expert
```
重点チェック: N+1クエリ、メモリリーク、アルゴリズム効率、不要な再レンダリング
評価基準: 重大（パフォーマンス重大影響）/ 警告（最適化余地）/ 可（問題なし）
```

## Error Handling Expert
```
重点チェック: サイレント失敗、空catch、エラーメッセージ品質、エラー伝播、フォールバック妥当性
評価基準: 重大（サイレント失敗・データ損失リスク）/ 警告（ログ不足・不適切なフォールバック）/ 可（問題なし）
```

## Type Design Expert
```
重点チェック: カプセル化、不変条件の表現、型の有用性、制約の強制力、不正状態の排除
評価基準: 重大（不正状態が型で表現可能）/ 警告（カプセル化・制約改善余地）/ 可（問題なし）
```
