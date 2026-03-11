# 変更履歴

Rite Workflow の主要な変更を記録します。

フォーマットは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
[Semantic Versioning](https://semver.org/lang/ja/spec/v2.0.0.html) に従います。

## [0.2.1] - 2026-03-12

### 追加

- e2e フローのコンテキストウィンドウオーバーフロー防止機構 (#80)
- エージェント委譲プロンプトに Skill ツール書式を追加 (#83)
- エージェント委譲の AGENT_RESULT フォールバック処理を追加 (#84)

### 修正

- サブスキル遷移で Claude 停止を防ぐプロンプト強化 (#79)
- 作業メモリの進捗サマリー・変更ファイル更新ロジックを具体化 (#75)
- create ワークフローのサブスキル遷移指示を強化 (#76)
- ハードコードされた bash フックパスを `{plugin_root}` に置換しマーケットプレイス互換に (#73)
- `resume.md` のカウンター復元の実行タイミング・実行主体を明示 (#85)
- `context-pressure.sh` の python3 起動最適化と COUNTER_VAL バリデーション追加 (#86)
- PR コマンドの Issue 作成時に GitHub Projects 登録を確実にする (#100)
- 進捗サマリー・変更ファイル更新セクションをチェックリスト更新から独立化 (#104)
- `flow-state-update.sh` の patch モードで `--active` フラグをサポート (#109)
- `flow-state-update.sh` の patch モードで jq フィルター前に `--` セパレータを追加 (#109)
- `fix.md` Phase 4.5.2 の trap に `$pr_body_tmp` を追加 (#94)
- review/fix ループ中に進捗サマリー・変更ファイルが更新されるよう修正 (#90)

### 変更

- 進捗サマリー正規表現を堅牢化 (#92)
- `lint.md` の不正確な参照修正と `start.md` の具体例追加 (#87)
- `resume.md` カウンター復元スニペットを正式サブセクションに構造化 (#88)
- `review.md` Phase 6.2 セッション情報更新の defense-in-depth 意図を明文化 (#93)

## [0.2.0] - 2026-03-05

### 追加

- セッション開始時のプラグインバージョンチェック機能 (#68)

### 変更

- SPEC およびコマンドドキュメント内の Zen/禅 表記を rite に置換 (#67)

## [0.1.3] - 2026-03-05

### 変更

- 確定的処理をシェルスクリプト（`flow-state-update.sh`、`issue-body-safe-update.sh`）にオフロードし、8ファイル・24箇所の jq + atomic write パターンを1行コールに置換
- `start.md` から完了報告セクションを `completion-report.md` に分離
- `review.md` から評価ルールを `references/assessment-rules.md` に分離
- `cleanup.md` からアーカイブ処理を `references/archive-procedures.md` に分離
- SKILL.md の description を能動的スタイルに最適化し、テーブルをポインタ+概要に圧縮
- 7つの主要コマンドの MUST/CRITICAL 箇所に Why-driven の理由文を追加
- 7つの主要コマンドに Input/Output Contract セクションを追加

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

[0.2.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
