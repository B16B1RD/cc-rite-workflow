# 変更履歴

Rite Workflow の主要な変更を記録します。

フォーマットは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
[Semantic Versioning](https://semver.org/lang/ja/spec/v2.0.0.html) に従います。

<!--
Phase 番号取扱方針: エントリは機能名レベルで変更を記述し、`review.md` /
`fix.md` / `start.md` 等の内部 `Phase X.Y.Z` 識別子には依存しません。Phase
番号はリファクタで採番し直される可能性があるため、CHANGELOG のエントリは
それらの変更に対して安定でなければなりません。位置情報が必要な場合は
内部 Phase 番号ではなくファイル名 (例: `review.md`) を参照してください。
背景は Issue #352、慣行は Keep a Changelog 1.1.0 "Guiding Principles" 参照。
-->

## [Unreleased]

### 変更

- **レビュー修正サイクル 根本見直し (Fail-Fast Response + 別 Issue 化ユーザー確認必須化 + 設定層)** — **BREAKING CHANGE** (#502 ロールアウトの最終層。#507 原則ドキュメント層・#508/#504 reviewer 出口層・#509 Fact-Check 拡張層に続く 4 PR 目)。`fix` 応答層と設定層を先行 3 層に接続し、review-fix サイクルの根本見直しを完成させる。
  - `plugins/rite/commands/pr/fix.md` Phase 2 冒頭に **Fail-Fast Response Principle** 節を追加。修正方針決定前に 4 項目チェックリスト (throw/raise 伝播 / 既存エラー境界 / null チェックが隠蔽でないか / テスト側修正が正しくないか) を通過させる。fallback 採用時は commit message に選択理由を明示させ、無思考な防御コード追加を Phase 5 re-review で再検出する運用へ変更。
  - `plugins/rite/commands/pr/fix.md` Phase 4.3.3 から **E2E `AskUserQuestion` スキップを撤廃**。別 Issue 化は呼び出し元 (E2E `/rite:issue:start` ループ / standalone) を問わず常にユーザー確認必須。オプションは `本 PR 内で再試行 / 別 Issue 化 / 取り下げ` の 3 択に統合され、いずれも `findings == 0` に収束するため review-fix ループの終了条件は維持される。
  - `plugins/rite/commands/pr/fix.md` および `plugins/rite/commands/issue/start.md` から `"severity_gating"` convergence strategy を **廃止**。本 PR 起因 findings は severity 問わず本 PR 内で対応する方針（本 PR 完結原則）に統一。`rite-config.yml` の `fix.severity_gating.enabled` は後方互換のためキー自体は残置しているが `false` 固定扱い。非収束時は fix.md Phase 4.3.3 の `AskUserQuestion` ルートに統合。非収束対応は `"batched"` / `"scope_lock"` strategy を使用してください。
  - `plugins/rite/templates/config/rite-config.yml` に新規キー追加: `review.observed_likelihood_gate` (enabled / security_exception / hypothetical_exception_reviewers / minimum), `review.fail_fast_first` (enabled / allow_skill_exceptions / wiki_query_required), `review.separate_issue_creation` (require_user_confirmation / report_pre_existing_issues), `fix.fail_fast_response`, `fix.severity_gating.enabled: false` (deprecated shim)。全キー opt-out 可能で、default が新挙動。
  - `plugins/rite/i18n/{ja,en}/pr.yml` に新規 UI 文言 4 キー追加 (`review_fail_fast_first_warning`, `review_observed_likelihood_demotion_notice`, `review_separate_issue_user_confirmation_question`, `fix_fail_fast_response_checklist_prompt`)。ja/en parity 維持。
  - **移行ガイド**: 既存ユーザーで `fix.severity_gating.enabled: true` を設定していた場合、本キーは silent に `false` 固定扱いとなります。非収束時は fix.md Phase 4.3.3 の `本 PR 内で再試行 / 別 Issue 化 / 取り下げ` `AskUserQuestion` で解決されます。severity 別の自動 defer が必要だった場合は `"batched"` または `"scope_lock"` strategy を採用してください。Fail-Fast First 原則の推奨強制を opt-out するには `review.fail_fast_first.enabled: false` を設定します。別 Issue 化のユーザー確認を opt-out するには `review.separate_issue_creation.require_user_confirmation: false` を設定できますが、本 PR 完結原則の escape hatch 防止機構を無効化するため**非推奨**です。(#506)

- **`/rite:pr:review` の reviewer 呼び出しを named subagent 化** — **BREAKING CHANGE**。`plugins/rite/commands/pr/review.md` で reviewer を `subagent_type: general-purpose` から `subagent_type: "rite:{reviewer_type}-reviewer"` (スコープ付き named subagent) に切り替え。named subagent 呼び出しでは各 reviewer の agent file body (`plugins/rite/agents/{reviewer_type}-reviewer.md`) が sub-agent の **system prompt** として自動注入され、YAML frontmatter (`model`, `tools`) が runtime に反映される。これにより reviewer の役割定義が system prompt レベルで強制され (user prompt 注入では agent body の優先度が低く希釈される問題を解消)、reviewer ごとの model pin (9 reviewer が `model: opus` 固定) が実効化される。13 reviewer の `reviewer_type` → `subagent_type` 対応表を `review.md` に追加。Issue #356 で `rite:` プレフィックスが必須であることを実機検証済み (bare 形式 `{reviewer_type}-reviewer` は `Agent type not found` エラーで解決失敗)。**ユーザー影響**: これまで sonnet で reviews を実行していたユーザーは 9 reviewer が強制 opus upgrade となりコスト増加する (個別 agent frontmatter から `model: opus` 行を削除することで opt-out 可能)。詳細な migration guide、opus 推奨の背景、3 つの rollback シナリオ (全 reviewer 解決失敗 / tech-writer Bash 権限喪失 / verification mode 出力形式破綻) は [`docs/migration-guides/review-named-subagent.md`](docs/migration-guides/review-named-subagent.md) を参照 (#358)
- **`{agent_identity}` プレースホルダを `{shared_reviewer_principles}` にリネーム** — **BREAKING CHANGE** (rite plugin 開発者向け、`review.md` テンプレート編集時に影響)。`review.md` は `_reviewer-base.md` から共通原則 (Reviewer Mindset / Cross-File Impact Check / Confidence Scoring) のみを抽出するよう変更。Part B (agent-specific identity) の抽出ロジックは削除 (named subagent の system prompt が agent 固有の discipline を直接配信するため不要)。これは **hybrid approach** で、agent body → system prompt (named subagent 経由)、共通原則 → user prompt (`{shared_reviewer_principles}` 経由) の 2 経路に分離する。代替案 (13 agent file に共通原則を inline) は `_reviewer-base.md` を単一ソースとして維持するため却下。レビューテンプレートの `## あなたのアイデンティティと検出プロセス` セクションは `## 共通レビュー原則` にリネームしてスコープを反映。#357 の Part A bug fix (Cross-File Impact Check の reviewer 到達) を維持する (#358)
- **Retry classification に `subagent resolution failure` 行を追加** (`review.md`) — Task ツールが scoped subagent 名を解決できない場合 (例: `Agent type 'rite:code-quality-reviewer' not found. Available agents: ...`) の新規 retry classification エントリ。Retry: **No**。Action: 即 fail、使用した scoped 名とエラーメッセージを表示する。named subagent 化による品質改善効果を損なうため、`general-purpose` への silent fallback は禁止。全 reviewer がこのエラーになる場合は orchestrator が `AskUserQuestion` で対応を確認 (retry / `general-purpose` への一時 rollback / レビュー中止)。判定パターン: Task ツール応答に `Agent type '{scoped_name}' not found` が含まれる (#358)

### 追加

- **workflow incident 自動 Issue 登録機構** — `/rite:issue:start` が実行中に発生する workflow blocker (Skill ロード失敗 / hook 異常終了 / 手動 fallback 採用) を自動検出し、Issue として登録することで silent loss を防止する機構を追加。新規 `plugins/rite/hooks/workflow-incident-emit.sh` が sentinel パターン (`[CONTEXT] WORKFLOW_INCIDENT=1; type=...; details=...; iteration_id=...`) を skill 内部 failure path および orchestrator fallback prompt から emit。`start.md` の新規 workflow incident 検出ロジックが context grep で sentinel を検出し、`AskUserQuestion` で確認した上で既存の `create-issue-with-projects.sh` を `Status: Todo / Priority: High / Complexity: S / source: workflow_incident` で呼び出す。同 session 内の同 type incident は重複排除。登録失敗は non-blocking。新規 `workflow_incident:` 設定セクションでデフォルト有効 (`enabled: false` で opt-out)。`plugins/rite/hooks/tests/workflow-incident-emit.test.sh` に 11 件の単体テストを追加。#366 の AC-1 ~ AC-10 を全て実装 (Skill ロード失敗 / hook 異常終了 / 手動 fallback 検出、重複制御、default-on、opt-out、recommendation flow 非干渉、non-blocking エラーハンドリング)。PR #363 cycle 1 で発覚した meta-incident (Skill loader bug #365 が Edit ツール手動 fallback で silent に bypass された問題) が直接の動機 (#366)
- **tech-writer Critical Checklist 具体化** — 文書-実装整合性 5 項目を追加: `Implementation Coverage`, `Enumeration Completeness`, `UX Flow Accuracy`, `Order-Emphasis Consistency`, `Screenshot Presence`。各項目に Grep/Read/Glob での検証手段を併記し、内部のドキュメント中心 PR 事例 (private repository, organization name redacted) を出典とする Prohibited vs Required Findings テーブルにサンプル行 3 件を追加 (#349)
- **internal-consistency.md reference 新設** — `fact-check.md` (外部仕様) と対の内部事実検証プロトコル。5 項目の Verification Protocol、Confidence 80+ ゲート、severity マッピング、および `tech-writer.md` / `review.md` / 関連 agent ファイルを参照する Cross-Reference セクションを定義 (#349)
- **Doc-Heavy PR Detection** — `review.md` でドキュメント中心 PR を自動判定 (判定式: `(doc_lines / total_diff_lines >= 0.6)` または `(doc_files_count / total_files_count >= 0.7 かつ total_diff_lines < 2000)`)。rite plugin 自身の `commands/`, `skills/`, `agents/` 配下の `.md` **および `plugins/rite/i18n/**` 配下の `.md` / `.mdx` 翻訳ドキュメント**は除外 (prompt-engineer 専管 / dogfooding artifact。`plugins/rite/i18n/` 配下の `.yml` / `.json` / `.po` など非 Markdown の翻訳リソースはそもそも `doc_file_patterns` の分子候補に含まれないため除外処理は no-op)。`rite-config.yml` に optional schema `review.doc_heavy.*` (キー: `enabled`, `lines_ratio_threshold`, `count_ratio_threshold`, `max_diff_lines_for_count`) を追加 (#349)
- **Doc-Heavy Reviewer Override** — `{doc_heavy_pr == true}` のとき tech-writer を recommended → mandatory に昇格、code-quality を co-reviewer 追加。追加経路は以下の 3 つで構成され、最終状態は常に ≥2 reviewers が保たれる:
  - **Normal path**: diff 内に fenced code block (` ```bash ` / ` ```yaml ` / ` ```python ` 等) が検出された場合に追加。純粋散文 PR ではこの経路は発火しない
  - **Fail-safe path**: diff スキャン自体が失敗した場合 (`git diff` IO エラー / grep IO エラー等)、fenced block 検出有無に関係なく追加 (検出シグナル不在時の検証強度維持)
  - **Fallback path**: fenced block が検出されず Doc-Heavy override で追加されなかった場合、sole-reviewer guard が後段で fallback として追加する

  tech-writer に `{doc_heavy_pr=true}` フラグを伝達し、`internal-consistency.md` の 5 カテゴリ verification protocol (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) を mandatory 化、各 finding に `Evidence:` 行を必須化、`review.md` の Doc-Heavy post-condition check で検証 (#349)
- **`/rite:pr:fix` に PR URL / comment URL 直渡しサポート** — `/rite:pr:fix` が PR 番号に加え PR URL / コメント URL 引数を受け付け、`/verified-review` など外部レビューツールのコメントから直接 findings をパースして fix ループに投入可能に。受理可能な URL 形式は trailing path (`/files`)、query string (`?tab=files`)、fragment (`#diff-...`) を含み、すべて引数 ingest 時に正規化される。対象コメントには最低 4 カラム (optional 5 列目 confidence) の markdown テーブルが必要。詳細な引数仕様・ヘッダー検出キーワード・severity 別名マッピングは `plugins/rite/commands/pr/fix.md` の引数パース関連セクションを参照 (#349)
- **`[fix:pushed-wm-stale]` 出力パターン** — `/rite:pr:fix` が work memory 更新で soft failure を検出した場合に新規出力する。発火条件は `commands/pr/fix.md` の reason 表と 1:1 対応しており、以下に自然言語表現と `reason` ラベルの mapping を示す。完全な一覧は reason 表参照:
  - `current_body` 空 → `current_body_empty`
  - `issue_number` 抽出失敗 → `issue_number_not_found`
  - PATCH 4xx/5xx → `patch_failed`
  - `pr_body` grep IO エラー → `pr_body_grep_io_error` (stderr tempfile mktemp 失敗は `mktemp_failed_pr_body_grep_err`)
  - branch grep IO エラー → `branch_grep_io_error` (同上 `mktemp_failed_branch_grep_err`)
  - `gh api comments` 取得失敗 → `gh_api_comments_fetch_failed` (同上 `mktemp_failed_gh_api_err`)
  - Python script 異常終了 (汎用) → `python_unexpected_exit_$py_exit`
  - `git diff` 失敗 (Python sentinel 検出) → `python_sentinel_detected` (`GIT_DIFF_FAILED_SENTINEL` マッチ時の `sys.exit(2)` に予約された専用ラベル)
  - work memory body 破損検出 → `wm_body_empty_or_too_short` / `wm_header_missing` / `wm_body_too_small`
  - mktemp 失敗 → `mktemp_failed_*` 系統 (`mktemp_failed_pr_body_tmp`, `mktemp_failed_body_tmp`, `mktemp_failed_tmpfile`, `mktemp_failed_files_tmp`, `mktemp_failed_history_tmp`, `mktemp_failed_diff_stderr_tmp`, 他)

  `git diff` 失敗経路も `WM_UPDATE_FAILED=1; reason=python_sentinel_detected` (Python `sys.exit(2)` + bash `exit 1`) を経由する。bash `exit 1` は bash invocation のみを kill するが、retained `WM_UPDATE_FAILED=1` flag は conversation context に残り、soft-failure 評価ロジックが評価順テーブル行 2 でこの flag を検出して `[fix:pushed-wm-stale]` を emit する (`[fix:error]` **ではない**)。hard fail-fast 設計は PATCH の silent 拒否を保証するが、caller 側へのシグナルは `[fix:pushed-wm-stale]` が正しい (詳細は `commands/pr/fix.md` の評価順テーブルと reason 表を参照)。caller (`/rite:issue:start` review-fix loop) は `[fix:pushed-wm-stale]` を **silent に `[fix:pushed]` 扱いしてはならず**、必ず `AskUserQuestion` で警告を提示してユーザーに「stale work memory のまま継続するか、手動修復のため中断するか」を選択させる義務を負う。詳細な caller セマンティクスは `commands/pr/fix.md` を参照 (#349)

### 修正

- **`review.md` の Part A 抽出バグ修正** — `_reviewer-base.md` の Part A 抽出が `## Cross-File Impact Check`（`## Reviewer Mindset` と `## Confidence Scoring` の間にあるセクション）を完全にドロップしていた不具合を修正。抽出範囲を「document 先頭 ~ `## Input` heading (exclusive)」に変更し、5 つの必須 cross-file consistency check（削除/リネーム済み export、変更された config key、変更された interface contract、i18n key consistency、keyword list consistency）が **初めて** reviewer agent に届くようになった (#357)
- **reviewer agent の tools/model frontmatter drift cleanup** — 全 13 reviewer agent (`api`, `code-quality`, `database`, `dependencies`, `devops`, `error-handling`, `frontend`, `performance`, `prompt-engineer`, `security`, `tech-writer`, `test`, `type-design`) から `tools:` frontmatter を削除、4 reviewer (`code-quality`, `error-handling`, `performance`, `type-design`) から `model: sonnet` を削除。現状は `subagent_type: general-purpose` 経由のため runtime で ignore されているが、named subagent 化した瞬間に副作用 (tech-writer が Bash を失い Doc-Heavy PR Mode 全 blocking 化 / 4 reviewer が opus ユーザーに対して sonnet 固定で品質劣化) を引き起こすリスクがあったため、先行 cleanup で副作用ゼロに保つ。残り 9 reviewer は `model: opus` を明示 pin として意図的に維持 (opus が runtime 上の実効 model だったため、pin を削除すると session default に regress して sonnet になる可能性を避けるため)。あわせて `docs/SPEC.md` / `docs/SPEC.ja.md` の Agent File Format セクションで `tools` を `Yes` (required) から `No (inherit)` に変更し、Current Agents 表の 4 reviewer を `inherit` に更新した (#357)
- **Verification-mode post-condition check 追加** — `review.md` に post-condition check (Verification Mode Findings Collection ロジックの子セクション) を追加し、verification mode 時に各 reviewer が `### 修正検証結果` テーブルを出力しているかを検証する。欠落時は reviewer 呼び出し Task tool 経由で per-reviewer retry を 1 回まで実行 (strict verification テンプレート再送)、retry 後も欠落の場合は `verification_post_condition: error` を set、overall assessment を `修正必要` (escalation chain の昇格ラベルと統一。`要修正` は reviewer 個別評価用 label で overall 昇格には使用しない) に昇格し、該当 reviewer の指摘を全件 blocking 扱い。classification vocabulary は `passed` / `warning` / `error` (`doc_heavy_post_condition` と統一)。Retained flags `verification_post_condition` / `verification_post_condition_retry_count` (per-reviewer dict) を retained flags list に登録し、verification mode template に表示する。reviewer が検証出力を silent skip して `finding_count == 0` 誤判定で silent pass する経路を閉塞する (#357)
- **`commands/pr/fix.md` reason 表 drift 修正** — work memory 更新パスで実際に emit される 28 件の `WM_UPDATE_FAILED` reason を全て reason 表に登録 (従来は 12 件のみ登録、16 件未登録で drift)。評価順テーブル行 2 の括弧内固定列挙を撤廃し「reason 表のいずれか」に置換、二重 drift を解消。DoD 検証 (手動実行): `comm -3 <(grep -oE 'WM_UPDATE_FAILED=1; reason=[a-z_][a-z_0-9]*' plugins/rite/commands/pr/fix.md | sed 's/.*reason=//' | sort -u) <(awk '/^\*\*`reason` フィールド/{in_table=1;next} in_table && /^\*\*/{in_table=0} in_table && /^\| `[a-z_]/{match($0, /`[a-z_][a-z_0-9]*[^`]*`/); print substr($0, RSTART+1, RLENGTH-2)}' plugins/rite/commands/pr/fix.md | sed 's/\$.*//' | sort -u)` の出力が空 (emit 集合 28 件と reason 表 28 件が完全一致)。awk パターンは `**\`reason\` フィールド` セクションに範囲を絞っており、`fix.md` 内の他テーブルからの false positive を防ぐ (#357, PR #350 C2 吸収)

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
- レビュー品質改善 — Confidence Calibration 降順修正、E2E auto-create フロー改善、recommendation flow Source C 整合性修正、コメント精度改善 (#313, #315, #317, #337)

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
- 初期フェーズのサブスキルに Defense-in-Depth flow-state 更新を追加

### 変更

- `loop_count`/`max_iterations`/`loop-limit` パラメータを廃止 (#210)
- `flow-state-update.sh` から `--loop` パラメータを完全削除 (#211)
- `hooks/hooks.json` ネイティブ方式を追加し二重実行ガードを設置 (#194)
- レビューテンプレートに品質3ルールを追加 (#209)
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

- `start.md` のチェックリスト確認に自動チェック処理を追加 (#170)
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
- `fix.md` work memory 更新の trap に `$pr_body_tmp` を追加 (#94)
- review/fix ループ中に進捗サマリー・変更ファイルが更新されるよう修正 (#90)

### 変更

- 進捗サマリー正規表現を堅牢化 (#92)
- `lint.md` の不正確な参照修正と `start.md` の具体例追加 (#87)
- `resume.md` カウンター復元スニペットを正式サブセクションに構造化 (#88)
- `review.md` のセッション情報更新の defense-in-depth 意図を明文化 (#93)

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
- `/rite:issue:start` の完了レポートが実行されない問題を修正 (#17)
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
[0.3.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.5...v0.3.0
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
