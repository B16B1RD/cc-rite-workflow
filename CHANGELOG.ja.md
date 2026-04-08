# 変更履歴

Rite Workflow の主要な変更を記録します。

フォーマットは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
[Semantic Versioning](https://semver.org/lang/ja/spec/v2.0.0.html) に従います。

## [Unreleased]

### 追加

- **tech-writer Critical Checklist 具体化** — 文書-実装整合性 5 項目を追加: `Implementation Coverage`, `Enumeration Completeness`, `UX Flow Accuracy`, `Order-Emphasis Consistency`, `Screenshot Presence`。各項目に Grep/Read/Glob での検証手段を併記し、内部のドキュメント中心 PR 事例 (private repository, organization name redacted) を出典とする Prohibited vs Required Findings テーブルにサンプル行 3 件を追加 (#349)
- **internal-consistency.md reference 新設** — `fact-check.md` (外部仕様) と対の内部事実検証プロトコル。5 項目の Verification Protocol、Confidence 80+ ゲート、severity マッピング、および `tech-writer.md` / `review.md` / 関連 agent ファイルを参照する Cross-Reference セクションを定義 (#349)
- **Doc-Heavy PR Detection (Phase 1.2.7)** — ドキュメント中心 PR を自動判定 (判定式: `(doc_lines / total_diff_lines >= 0.6)` または `(doc_files_count / total_files_count >= 0.7 かつ total_diff_lines < 2000)`)。rite plugin 自身の `commands/`, `skills/`, `agents/` 配下の `.md` **および `plugins/rite/i18n/**` 翻訳ファイル**は除外 (prompt-engineer 専管 / dogfooding artifact)。`rite-config.yml` に optional schema `review.doc_heavy.*` (キー: `enabled`, `lines_ratio_threshold`, `count_ratio_threshold`, `max_diff_lines_for_count`) を追加 (#349)
- **Doc-Heavy Reviewer Override (Phase 2.2.1)** — `{doc_heavy_pr == true}` のとき tech-writer を recommended → mandatory に昇格、**diff 内に fenced code block (` ```bash ` / ` ```yaml ` / ` ```python ` 等) が検出された場合に** code-quality を co-reviewer 追加 (Phase 2.2.1 経由では純粋散文 PR では追加されないが、**diff スキャン自体が失敗した場合は fail-safe で追加され、検出が無かった場合は Phase 2.3 sole reviewer guard が後段で fallback として code-quality を追加する**ため、最終状態は常に ≥2 reviewers が保たれる)。tech-writer に `{doc_heavy_pr=true}` フラグを伝達し、`internal-consistency.md` の 5 カテゴリ verification protocol (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) を mandatory 化、各 finding に `Evidence:` 行を必須化、`review.md` の Phase 5.1.3 Doc-Heavy post-condition check で検証 (#349)
- **`/rite:pr:fix` に PR URL / comment URL 直渡しサポート** — `/rite:pr:fix` が PR 番号に加え PR URL / コメント URL 引数を受け付け、`/verified-review` など外部レビューツールのコメントから直接 findings をパースして fix ループに投入可能に。受理可能な URL 形式は trailing path (`/files`)、query string (`?tab=files`)、fragment (`#diff-...`) を含み、すべて Phase 1.0 で正規化される。対象コメントには最低 4 カラム (optional 5 列目 confidence) の markdown テーブルが必要。詳細な引数仕様・ヘッダー検出キーワード・severity 別名マッピングは `plugins/rite/commands/pr/fix.md` Phase 1.0 / Phase 1.2 best-effort parse セクションを参照 (#349)
- **`[fix:pushed-wm-stale]` 出力パターン** — `/rite:pr:fix` が Phase 4.5 work memory 更新で soft failure (`current_body` 空 / `issue_number` 抽出失敗 / PATCH 4xx/5xx) を検出した場合に新規出力する。`git diff` 失敗は別経路で hard fail-fast (`exit 1`) として扱われ、`[fix:pushed-wm-stale]` ではなく `[fix:error]` として surface する。caller (`/rite:issue:start` review-fix loop) は `[fix:pushed-wm-stale]` を **silent に `[fix:pushed]` 扱いしてはならず**、必ず `AskUserQuestion` で警告を提示してユーザーに「stale work memory のまま継続するか、手動修復のため中断するか」を選択させる義務を負う。詳細な caller セマンティクスは `commands/pr/fix.md` Phase 8.1 を参照 (#349)

## [0.3.10] - 2026-04-04

### 変更

- review-fix ループ根本修正 — bash エラーハンドリング検出 + 既存 CRITICAL 可視化 + first-pass ルール改善 (#325)
- sole reviewer guard + Step 6 sub-checks 拡張 — 単一レビュアーの盲点を解消 (#333)
- レビュアー共同選定拡張 — .md コードブロック検出時に code-quality reviewer を追加 (#330)
- prompt-engineer-reviewer の検出スコープ拡張 — Content Accuracy + List Consistency + Design Logic Review (#327)
- Step 7 に Stale Cross-References 検出ステップカバレッジを追加 (#336)
- verification mode デフォルト無効化 + context-pressure フェーズ条件分岐 (#322)
- i18n Sprint キーセクション統合 + en/ja other.yml 重複セクション正規化 (#318, #320)
- フックスクリプトの jq 呼び出し構文を `echo | jq` に統一 (#341)

### 修正

- フックスクリプトの jq 抽出堅牢性改善 — CWD フォールバック追加、pre-tool-bash-guard フォールバック追加、context-pressure.sh の silent abort 防止 (#334, #338, #342)
- レビュー品質改善 — Confidence Calibration 降順修正、E2E auto-create フロー改善、Phase 7 Source C 整合性修正、コメント精度改善 (#313, #315, #317, #337)

## [0.3.9] - 2026-04-03

### 追加

- レビュアー基盤強化 — `{agent_identity}` 抽出、`_reviewer-base.md` 共通原則、主要 agent 4種（security, code-quality, prompt-engineer, tech-writer）+ confidence_threshold 設定 (#292)
- レビュアー拡充 — 残り agent 7種再構築 + 新規 reviewer 2種（error-handling, type-design）追加 (#293)
- `schema_version` 導入 + `rite-config.yml` の自動アップグレード仕組み (#285)

### 修正

- deprecated な `commit.style` コード例を全ドキュメント・プロジェクトタイプテンプレートから削除 (#300, #302, #304, #305, #306)
- ドキュメント内の config 例を `schema_version: 2` 形式に更新 (#303)
- verification mode re-review でサブエージェント起動を必須化 (#299)
- 推奨事項の「別 Issue 推奨」アイテムを自動 Issue 化する仕組みを追加 (#297)
- `flow-state-update.sh` patch モードで `error_count` を 0 にリセットし、stale サーキットブレーカーを防止 (#295)

## [0.3.8] - 2026-04-01

### 追加

- ファクトチェック Phase — PR レビューで外部仕様の主張を公式ドキュメントで検証し誤情報を防止 (#275)
- context7 MCP ツールによる検証オプション — ファクトチェックの検証手段として追加（`review.fact_check.use_context7`、デフォルト: オフ）(#278)

### 修正

- `.rite-initialized-version` と `.rite-settings-hooks-cleaned` を `.gitignore` に追加 (#274)

## [0.3.7] - 2026-04-01

### 変更

- レビュアー findings に WHY + EXAMPLE 構造を導入し、修正ガイダンスの精度を向上 (#268)

## [0.3.6] - 2026-03-27

### 追加

- Sprint Contract — 実装ステップごとの検証基準追加 (#260)
- Evaluator キャリブレーション — Few-shot 例集と懐疑的トーン追加 (#261)
- Post-Step Quality Gate — 実装後セルフチェック追加 (#262)
- コンテキストリセット戦略強化 (#263)

## [0.3.5] - 2026-03-27

### 追加

- `/rite:investigate` スキル — Grep→Read→クロスチェックの3段階プロセスによる体系的なコード調査 (#249)
- `investigation-protocol.md` リファレンス — 全ワークフローフェーズで利用可能な簡易コード調査プロトコル (#249)
- `rite-config.yml` に `investigate.codex_review.enabled` オプション追加（Codex クロスチェックのオプション化） (#249)

### 修正

- `settings.local.json` のレガシー hook を `hooks.json` ネイティブ管理に移行 (#247)

## [0.3.4] - 2026-03-20

### 変更

- Plugin path resolution をバージョン非依存方式に統一 — `session-start.sh` が `.rite-plugin-root` に解決済みパスを書き出し、コマンドファイルは `cat` で読むだけに (#241)

## [0.3.3] - 2026-03-19

### 修正

- マーケットプレイス環境で `/clear` 実行時に SessionStart hook エラーが発生する問題を修正 (#235)

## [0.3.2] - 2026-03-17

### 修正

- `/rite:init` が `settings.json` の既存 hooks を検出し競合を防止するように修正 (#229)

### 変更

- `rite-config.yml` から未使用設定を削除し欠落設定を追加

### ドキュメント

- リリーススキルに AskUserQuestion 強制・ブランチ削除手順を追加

## [0.3.1] - 2026-03-17

### 修正

- verification mode 時にフルレビューが実施されない問題を修正 (#223)
- `{session_id}` プレースホルダーを削除し auto-read に一本化 (#221)
- `create.md` サブスキル返却後の中断防止ロジック強化 (#205)
- Issue コメントの作業メモリバックアップ同期を修正 (#204)
- `.rite-session-id` 不在時の bash リダイレクションエラーを修正
- `session-start.sh` が startup/clear 時に他セッションの active 状態をリセットしない問題を修正 (#206)
- review-fix ループの段階的緩和ロジックを削除し全指摘必須修正に統一 (#202)
- e2e フローでレビュアー確認・Ready 確認をスキップ不可に (#198)
- flow-state deactivation で patch 方式を使用 (#195)
- レビューテンプレート出力例の blocking/non-blocking 残存表記を修正
- パス解決不整合を修正し `--if-exists` パターンに統一
- Phase 1-3 サブスキルに Defense-in-Depth flow-state 更新を追加

### 変更

- `loop_count`/`max_iterations`/`loop-limit` パラメータを廃止 (#210)
- `flow-state-update.sh` から `--loop` パラメータを完全削除 (#211)
- `hooks/hooks.json` ネイティブ方式を追加し二重実行ガードを設置 (#194)
- Phase 4.5 レビューテンプレートに品質3ルールを追加 (#209)
- `session-start.sh` の trap 廃止とデバッグログ改善

### ドキュメント

- review-fix ループのドキュメント更新 (#212)

## [0.3.0] - 2026-03-16

### 追加

- Session ownership システムによるマルチセッション競合防止 (#174, #175, #176, #177, #178, #179)
  - Session ownership ヘルパー関数と flow-state 上書き保護 (#175)
  - `session-start.sh` に session ownership 対応を追加 (#176)
  - `session-end.sh` と `stop-guard.sh` に session ownership 対応を追加 (#177)
  - `wm-sync`、`pre-compact`、`context-pressure` フックに session ownership 対応を追加 (#178)
  - 全コマンドファイルに `--session {session_id}` パラメータを追加 + `resume.md` の所有権移転 (#179)

### 修正

- Phase 5.2.1 チェックリスト確認に自動チェック処理を追加 (#170)
- ブランチ存在チェックで exit code ではなく出力文字列で判定するよう修正 (#172)
- Issue create 完了時の出力順序を改善し次のステップを末尾に移動 (#168)
- PostToolUse hook で Issue コメント作業メモリを phase 変化時に自動同期 (#167)
- `review.md` に READ-ONLY 制約を追加し review-fix ループを正常化 (#165)
- review → fix ループの分岐指示を命令形条件分岐に書き換え (#163)
- `session-end.sh` の other session exit パスに診断ログを追加
- フックからデバッグ出力の痕跡を除去 (#174)

### 変更

- Issue コメント作業メモリ更新ロジックをスクリプト化し確定的実行にする (#161)

### ドキュメント

- `gh-cli-commands.md` に `git branch --list` の DO NOT 警告を追加 (#181)

## [0.2.5] - 2026-03-16

### 追加

- Contextual Commits 統合: コミット body に構造化アクションラインを埋め込み、意思決定を永続化 (#144)
  - 設定とリファレンスドキュメント（`commit.contextual` 設定） (#145, #150)
  - `implement.md` のコミットフローにアクションライン生成を追加 (#146, #151)
  - `pr/fix.md` のレビュー修正コミットにアクションライン生成を追加 (#147, #152)
  - `/rite:issue:recall` コマンドを新設（コンテキストコミット履歴の検索） (#148, #153)
  - `team-execute.md` の並列コミットにアクションライン生成を追加 (#149, #156)

### 修正

- `recall.md` のエッジケース対応: base branch フォールバック、grep メタ文字対策、max-count 一貫性 (#154, #155)
- リリーススキルに GitHub Projects 連携とステータス遷移を追加

## [0.2.4] - 2026-03-14

### 修正

- 作業メモリコメントの実装計画ステップ状態をコミット時に一括更新 (#138)
- create-decompose.md に Defense-in-Depth パターンを適用 (#127)
- テスト内の旧状態名 blocked を recovering に統一
- develop ブランチ自動削除時の復旧手順を追加

### 変更

- Defense-in-Depth パターンの順序明確化と冗長性解消 (#126)
- PostCompact フック導入による auto-compact 復帰の自動化 (#133)

### 改善

- create サブスキルのプロンプト品質改善 (#128)

## [0.2.3] - 2026-03-13

### 修正

- create ワークフローのサブスキル返却後の自動継続を強化 (#125)

## [0.2.2] - 2026-03-12

### 追加

- マーケットプレイス版フックパスのバージョンアップ時自動更新 (#117)

### 修正

- 親 Issue の Projects Status 自動更新が実行されない問題を修正 (#115)

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

[0.3.10]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.4...v0.3.5
[0.3.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.5...v0.3.0
[0.3.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.1...v0.3.2
[0.2.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
