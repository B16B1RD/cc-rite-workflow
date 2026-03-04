# 変更履歴

Rite Workflow の主要な変更を記録します。

フォーマットは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
[Semantic Versioning](https://semver.org/lang/ja/spec/v2.0.0.html) に従います。

## [0.1.2] - 2026-03-04

### 修正

- `work-memory-init` 検証スクリプトの else 成功ブランチ欠落を修正 (#48)
- 作業メモリコメントが API エラーレスポンスで上書きされる問題を修正 (#47)
- rite workflow 実行中の不要な hooks 未登録メッセージを修正 (#46)
- `stop-guard.sh` の trap に EXIT シグナルを追加 (#39, #41)
- `stop-guard.sh` の compact_state 停止ブロック失敗を修正 (#22)
- `session-start.sh` の jq エラーハンドリング問題を修正 (#18, #20)
- `/rite:issue:start` の完了レポート（Phase 5.6）が実行されない問題を修正 (#17)
- 親 Issue の Projects ステータスが Todo から In Progress に更新されない問題を修正 (#15)
- `/rite:issue:start` 実行時の Bash コマンドエラーを修正 (#13)
- find クリーンアップパターンを mktemp サフィックス長非依存に修正 (#44)
- `ready.md` に出力パターンと Defense-in-Depth を追加 (#32)
- 作業メモリ更新の安全パターンを全コマンドに統一適用 (#50)
- stop-guard と post-compact-guard の競合デッドロックを修正 (#30)
- `/clear → /rite:resume` 案内メッセージの重複表示を修正 (#27)

### 変更

- `stop-guard.sh` の grep -A20 固定値を awk セクション抽出に改善 (#35)
- `pre-compact.sh` の echo|jq パイプを here-string に統一 (#34)
- `stop-guard.sh` のサブシェル最適化 (#24)
- PID ベース一時ファイル名を mktemp + フォールバックに統一 (#38)

### 削除

- v0.1.0 変更履歴からリブランド表記を削除 (#52)

## [0.1.1] - 2026-03-03

### 修正

- 大規模課題の単一 Issue 作成時に Implementation Contract フォーマットが適用されない問題を修正 (#2)
- `/rite:issue:create` サブスキル復帰後の中断問題を修正 (#6)
- `/rite:issue:start` 実行中の中断問題を修正 (#7)
- 作業メモリ更新時の安全パターン追加と破壊防止対策 (#8)

## [0.1.0] - 2026-03-01

### 追加

- Rite Workflow 初回リリース
- Claude Code 用 Issue ドリブン開発ワークフロー
- マルチレビュアー PR レビューシステム（討論フェーズ付き）
- スプリント計画・チーム実行
- GitHub Projects 連携
- フックベースのセッション管理（stop-guard、pre-compact、セッションライフサイクル）
- 多言語対応（日本語、英語）
- TDD Light モード
- git worktree による並列実装サポート

[0.1.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
