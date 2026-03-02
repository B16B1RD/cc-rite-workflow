# 変更履歴

Rite Workflow の主要な変更を記録します。

フォーマットは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
[Semantic Versioning](https://semver.org/lang/ja/spec/v2.0.0.html) に従います。

## [0.1.1] - 2026-03-03

### 修正

- 大規模課題の単一 Issue 作成時に Implementation Contract フォーマットが適用されない問題を修正 (#2)
- `/rite:issue:create` サブスキル復帰後の中断問題を修正 (#6)
- `/rite:issue:start` 実行中の中断問題を修正 (#7)
- 作業メモリ更新時の安全パターン追加と破壊防止対策 (#8)

## [0.1.0] - 2026-03-01

### 追加

- Rite Workflow 初回リリース（Zen Workflow からリブランド）
- Claude Code 用 Issue ドリブン開発ワークフロー
- マルチレビュアー PR レビューシステム（討論フェーズ付き）
- スプリント計画・チーム実行
- GitHub Projects 連携
- フックベースのセッション管理（stop-guard、pre-compact、セッションライフサイクル）
- 多言語対応（日本語、英語）
- TDD Light モード
- git worktree による並列実装サポート
