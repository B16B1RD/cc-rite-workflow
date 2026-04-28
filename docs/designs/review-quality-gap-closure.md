# /rite:pr:review の品質ギャップ解消（verified-review parity）

> **位置づけ**: `docs/designs/reviewer-quality-improvement.md`（PR #285 発、agent 定義の自己完結化）の**後続改善**。本設計書は PR #350 のドッグフーディングで発見された追加課題に対応する。

> **⚠️ スナップショット注記 (#387)**: 本設計書は Phase 0 調査時点（Phase A/B/C 適用前）のコードベースを前提に記述されており、「### 真の Root Cause（調査で判明）」セクションを含む本文中のコード引用・ファイル名:行番号参照（例: `plugins/rite/commands/pr/review.md:1192-1195`、`_reviewer-base.md` の `L22 ## Confidence Scoring` / `L42 ## Input`、`review.md:1237` の `subagent_type: general-purpose` 等）はすべて当時のスナップショットです。Phase A/B/C 適用後の現行コードとは行番号・構造がズレており、たとえば `_reviewer-base.md` の見出しは Phase C の `#6 Documentation i18n parity` / `#7 Pattern portability` 追加により約 9 行シフト済みで、`review.md` の reviewer 呼び出しも named subagent (`rite:{reviewer_type}-reviewer`) に移行済みです。現行仕様は `plugins/rite/commands/pr/review.md` および `plugins/rite/agents/_reviewer-base.md` 本体を直接参照してください。

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

cc-rite-workflow の `/rite:pr:review` の指摘網羅性を、外部ツール `/verified-review`（pr-review-toolkit ベース）と同等まで引き上げる。具体的には、既存の Part A 抽出仕様バグの修正、`subagent_type` を `general-purpose` から named subagent へ切り替え、reviewer のプロンプト内容改善、tools drift の整備、定量検証まで一気通貫で実施する。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

### 発生した事象

Issue #349 / PR #350「doc-heavy-review-mode」の実装中、以下の現象が発生した：

- cc-rite-workflow 内製の `/rite:pr:review` を使ったドッグフーディング review-fix ループは **3 サイクル・累計 20 件** で「マージ可」判定に収束
- 直後に `/verified-review`（坂口さん個人の user command）を試すと、8 サイクル・**累計 172 件** の新規指摘が噴出
- 平均すると `/verified-review` ≈ 21 件/サイクル、`/rite:pr:review` ≈ 7 件/サイクルの差。**約 3 倍のギャップ**（初版で誤認した「5-6 倍」は累計 vs 累計の混同で誇張）

### 真の Root Cause（調査で判明）

#### RC1: Part A 抽出バグ（CRITICAL / 既存構造バグ）

`plugins/rite/commands/pr/review.md:1192-1195` の Part A 抽出仕様:

> Extract the `## Reviewer Mindset` and `## Confidence Scoring` sections (everything between these headings and the next `##` heading or `## Input` section)

一方 `plugins/rite/agents/_reviewer-base.md` の見出し構造:

```
L3   ## Reviewer Mindset
L12  ## Cross-File Impact Check    ← ここが構造上ドロップする
L22  ## Confidence Scoring
L42  ## Input
```

**仕様通り抽出すると `## Cross-File Impact Check`（L12-21）セクションが完全にドロップする**。`code-quality-reviewer.md` Step 6 などは「_reviewer-base.md の Cross-File Impact Check procedure に従え」と指示だけしているが、実際のチェック内容（#1 deleted/renamed exports, #2 changed config keys, #3 changed interface contracts, #4 i18n key consistency, #5 keyword list consistency）が reviewer に渡されていない。**i18n key consistency などが一度も機能していなかった**。

#### RC2: named subagent 未使用

`review.md:1237` で reviewer は `subagent_type: general-purpose` で呼ばれている。これにより：

1. agent ファイルの YAML frontmatter（`model:`, `tools:`）は **完全に無視される**
2. agent body は `{agent_identity}` プレースホルダとして **user prompt 内に注入**されている（review.md:1306, 1340）
3. 全 reviewer は親セッションと同じモデルで動いており、モデル差は存在しない

一方、`/verified-review` が呼ぶ pr-review-toolkit の各エージェントは **named subagent** として呼ばれるため、agent body が **system prompt として注入**される。user prompt 内の役割指示と system prompt の役割指示では、Claude モデルに対する拘束力が根本的に異なる。

### ゴール

**`/rite:pr:review` を初回実行で `/verified-review` と同等の指摘網羅性にする**。具体的な定量目標は:

- カバレッジ率（`/verified-review` で見つかった指摘のうち `/rite:pr:review` でも見つかった割合）: **70% 以上**
- False positive rate: **20% 以下**
- PR #350 で見落とされた 6 カテゴリ（flow control, i18n parity, pattern portability, dead code, stderr 混入, semantic collision）のうち **最低 4 カテゴリ** で最低 1 件ずつ検出

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

1. **FR1: Part A 抽出バグ修正**: `_reviewer-base.md` の全セクション（`## Input` 直前まで）が reviewer に届くように抽出仕様を修正し、Cross-File Impact Check の内容が実際に reviewer の検出プロセスで利用されるようにする
2. **FR2: named subagent 切り替え**: `subagent_type: general-purpose` → `subagent_type: "{scoped_name}"`（実機確認で確定した形式）に変更し、agent body を system prompt として注入する
3. **FR3: tools drift 整備**: skill ファイルが要求するツール（Bash, WebFetch, WebSearch）と agent frontmatter の `tools:` を一致させる。または frontmatter から `tools:` を削除して inherit 化
4. **FR4: Cross-File Impact Check 拡張**: 既存の #1-#5 に加え、#6 Documentation i18n parity（README.md ↔ README.ja.md などのペア整合性）と #7 Pattern portability（regex の locale 依存、識別子の予約文字衝突）を追加
5. **FR5: tech-writer-reviewer Activation 拡張**: 現状の `docs/**`, `*.md` に加え、コード内のコメント・docstring 変更も対象にする（pr-review-toolkit の comment-analyzer 相当機能を内製化）
6. **FR6: verification mode post-condition check**: Phase 5.1.1 で reviewer が `### 修正検証結果` テーブルを欠落した場合の retry/fail ロジックを追加
7. **FR7: Migration Guide 作成**: Phase B は breaking change。opus 推奨、Claude Code version 要件、revert 手順を含むマイグレーションガイドを用意
8. **FR8: 定量検証**: PR #350 Cycle 1 親 commit を含む複数の対照 PR で、各 Phase 完了後の指摘数・カテゴリ分布・false positive rate を自動測定

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

- **NFR1: 配布ユーザー互換性**: rite plugin は他のユーザーにも配布される前提。Phase B 実施による sonnet 環境ユーザーへの影響、Claude Code version 差分を評価し、Migration Guide で明示する
- **NFR2: rollback 容易性**: 各 Phase は独立 PR として実装し、部分 revert 可能な atomicity を保つ。特に Phase B は scope が大きいため rollback シナリオを事前定義する
- **NFR3: PR #350 特殊性への過剰適応回避**: PR #350 は doc-heavy PR で activate する reviewer が偏っている。対照 PR として TypeScript コード中心、Bash/hook script 中心、mixed の 3 件を追加検証対象に含め、他 PR タイプでも改善が出ることを確認する
- **NFR4: 測定の継続性**: Phase D の自動測定スクリプトを hook として組み込み、今後のレビュー品質の回帰を検出可能にする

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

### D1: pr-review-toolkit を依存として統合するのではなく、エッセンスを内製化する

当初の統合案（Phase 4.7 として pr-review-toolkit を並列呼び出し）は**撤回**。理由:
- rite plugin の自己完結性を維持
- ユーザーへの追加依存を発生させない
- pr-review-toolkit のアップデートに追従する運用負担を避ける

代わりに、pr-review-toolkit の各 agent（code-reviewer, silent-failure-hunter, comment-analyzer, pr-test-analyzer, type-design-analyzer）のプロンプト設計を参考にしつつ、cc-rite-workflow スタイル（`_reviewer-base.md` 準拠、WHAT+WHY+FIX テーブル）で書き下ろす。

### D2: comment-accuracy-reviewer の新設は撤回

当初案の新規 reviewer 追加は over-engineering と判定。`tech-writer-reviewer` の Activation pattern を拡張してコード内コメント・docstring も対象にする方が低コスト。

### D3: tools フィールドは inherit（frontmatter から削除）を推奨

Phase B で tools 制限が実効化する副作用を避けるため、Phase A で全 13 reviewer の `tools:` フィールドを frontmatter から削除して親セッションから inherit する。現状の `general-purpose` 経由での挙動をそのまま保全できる。skill ファイル要求に合わせて個別指定する案は drift が再発するため回避。

### D4: model frontmatter は inherit（frontmatter から削除）

現状 `sonnet` 固定の 4 reviewer（code-quality, error-handling, performance, type-design）と、`opus` 固定の 9 reviewer の drift を解消。general-purpose 経由では実効効果ないが、Phase B で named subagent 化した瞬間に opus ユーザーで sonnet 固定が悪影響になるため先行 cleanup。

### D5: verification mode の出力フォーマット処理方針

Phase B で agent body を system prompt 化する際、verification mode 固有のフォーマット指示（`### 修正検証結果` テーブル等）の扱いは Phase 0 の結果次第で 2 案から選択:

- **案 A**: agent body の `## Output Format` セクションに verification mode の条件分岐を追加し、完全 named subagent 化
- **案 B**: verification mode 時のみ `subagent_type` を `general-purpose` に force（full mode のみ named 化）

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

本改善は複数の疎結合な改善を段階的に適用する。主要コンポーネント:

| コンポーネント | 責務 | 改善対象 Phase |
|----------------|------|----------------|
| `plugins/rite/commands/pr/review.md` | Generator-Critic フロー全体の orchestrator | A, B |
| `plugins/rite/agents/_reviewer-base.md` | 全 reviewer 共通原則（Mindset, Cross-File Impact Check, Confidence Scoring） | A, C |
| `plugins/rite/agents/*-reviewer.md`（13 ファイル） | 各 specialist reviewer の Identity, Detection Process, Confidence Calibration | A, B, C |
| `plugins/rite/skills/reviewers/*.md`（14 ファイル） | 各 reviewer の詳細 checklist と skill profile | C |
| `plugins/rite/hooks/` | レビュー実行の計測 hook（新規） | Phase 0, D |
| `docs/investigations/` | Phase 0 のベースライン調査結果 | Phase 0 |

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

**現状** (Phase A 適用前):

```
/rite:pr:review 実行
  ↓
Phase 4.3 reviewer selection
  ↓
Phase 4.3.1 Task tool invocation
  - subagent_type: general-purpose  ← これが問題
  - prompt: Phase 4.5 template (inside user prompt)
     ├─ {agent_identity} ← agent body の一部が user prompt に入る
     ├─ {skill_profile}
     ├─ {checklist}
     └─ {diff_content}
  ↓
reviewer (general-purpose agent が specialist のフリをする)
  → Cross-File Impact Check #1-#5 が届いていない ← Part A 抽出バグ
  → tools 制限も無効（general-purpose は全 tool 使える）
```

**Phase B 適用後**:

```
/rite:pr:review 実行
  ↓
Phase 4.3 reviewer selection
  ↓
Phase 4.3.1 Task tool invocation
  - subagent_type: "{scoped_name}"  ← Phase 0 で確定
  - prompt: Phase 4.5 template (agent_identity プレースホルダ削除)
  ↓
named subagent (agent body が system prompt として自動注入)
  → Cross-File Impact Check 全内容が reviewer に届く（Part A バグ修正済み）
  → tools は frontmatter から削除（inherit）
  → 役割定義の拘束力が pr-review-toolkit 同等
```

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

#### Phase 0（事前検証）
- `docs/investigations/review-quality-gap-baseline.md`（新規）
- `plugins/rite/commands/pr/review.md`（一時的な debug output、Phase A で戻す）
- 自動測定スクリプト: 場所未定（`scripts/` or `plugins/rite/scripts/`）

#### Phase A（既存バグ修正 + drift 整備）
- `plugins/rite/commands/pr/review.md`（Part A 抽出仕様の修正 line 1192-1195、Phase 5.1.1 post-condition 追加）
- `plugins/rite/agents/*-reviewer.md`（全 13 ファイルの frontmatter から `tools:` と `model:` を削除）

#### Phase B（named subagent 切り替え）
- `plugins/rite/commands/pr/review.md`（Phase 4.3.1, 4.4, 4.5, 4.5.1）
- `plugins/rite/agents/*-reviewer.md`（verification mode 用 conditional section を必要に応じて body に追記）
- `README.md`, `README.ja.md`（breaking change 告知）
- `CHANGELOG.md`, `CHANGELOG.ja.md`（新エントリ追加）
- `docs/migration-guides/review-named-subagent.md`（新規、Migration Guide）

#### Phase C（コンテンツ改善）
- `plugins/rite/skills/reviewers/tech-writer.md`（Activation 拡張、comment accuracy セクション追加）
- `plugins/rite/agents/_reviewer-base.md`（Cross-File Impact Check #6, #7 追加）
- `plugins/rite/agents/code-quality-reviewer.md`（Core Principle 6 追加、責務境界明示）
- `plugins/rite/agents/error-handling-reviewer.md`（stderr 混入パターンを Step 6 に具体例追加）

#### Phase D（検証）
- `docs/investigations/review-quality-gap-results.md`（新規、検証結果レポート）
- 対照 PR での測定結果（コメント or repo 内ドキュメント）

#### Phase C2（分散伝播漏れ検出 lint）— 本セッションで追加

**背景**: PR #350 fix loop で 20 cycle / 70+ 件の fix を経てもなお 27 件の新規指摘が検出され、原因の多くが「同一修正パターンの一部 Phase 伝播漏れ」という構造的問題だった。L-5 / L-7 / L-8 修正の部分適用、H-1〜H-4 の成功経路限定など、本セッションの verified-review #350 で実測確定した 7 件のブロッカー修正 (C1 / C3+H1 / H2 / H3 / H5 / H6) 全てがこのパターンに該当する。

**仮説**: LLM agent の読解力には上限があり、類似パターンが複数 Phase に散らばる状況で一部を見て全体を判断する誤りを起こす。本セッションで Explore agent すら C1/C3/H1-H3 を「既修済み」と誤判定した事実が実証している。この上限は Issue #355 の RC1 (Part A 抽出バグ) / RC2 (named subagent 未使用) を解決しても残る (RC1/RC2 は `/rite:pr:review` のフレーム問題、分散伝播漏れは fix ループの構造問題)。

**アプローチ**: 静的 lint で機械的に検出する。agent-based review の上限を静的解析で補完する。

- **Pattern-1 retained flag coverage**: `exit 1` 直前に `[CONTEXT] *_FAILED=1` emit が欠落しているエラーハンドラを検出 (本セッション H1/H2/H3 で実証)
- **Pattern-2 reason table drift**: Markdown の reason テーブルに列挙された識別子と、同一ファイル内の `echo "[CONTEXT] *_FAILED=1; reason=..."` の emit 箇所を突き合わせて drift 検出 (本セッション C2 で 12 件登録 vs 28 件実 emit 実測)
- **Pattern-3 if-wrap drift**: `cat <<'EOF' > "$tmpfile"` が 「if ! cmd; then」 で wrap されていない箇所を検出 (本セッション C3 で Phase 2.4 が Phase 4.2/4.3.4 から drift していた事例を実証)
- **Pattern-4 anchor drift**: Markdown ファイルの `#anchor` 参照が同一/他ファイルの見出しに解決できるか確認する内部リンクチェッカー (本セッション H6 の `#cross-reference` → `#drift-detection-invariants` 事例)
- **Pattern-5 evaluation-order table 列挙 drift**: reason 表とは別に、評価順テーブルの括弧内に reason を列挙している箇所を検出。括弧内列挙と実 emit の突き合わせで drift 検出 (本セッション C2 副次発見、fix.md Phase 8.1 評価順 行 2 の 7 件固定列挙 vs 実 28 件 emit)

**Sub-Issue**: 詳細は Issue #361 (#355 の子 Issue) を参照。このカテゴリは Issue #355 の RC1 / RC2 と直交する問題であり、両者は独立して解決する必要がある。

**配置**:
- `plugins/rite/hooks/scripts/distributed-fix-drift-check.sh`（新規）
- `rite-config.yml` の `commands.lint` に統合するか CI のみで動かすかは Phase 0 (#356) の結果で決定

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

#### エッジケース

- **EC1**: `subagent_type` が scoped name 解決失敗したとき、Claude Code が silently general-purpose にフォールバックする可能性がある。Phase 0 で実機確認し、fallback 時の挙動を Phase 4.4 retry classification に追加する
- **EC2**: verification mode で 2 つのテンプレート（Phase 4.5 + 4.5.1）を統合出力させる現状仕様が、agent body の system prompt 化で断片化するリスク。Phase 5.1.1 の post-condition check で検出する
- **EC3**: Cross-File Impact Check の新項目（#6 Documentation i18n parity, #7 Pattern portability）は false positive リスクがある。Confidence 80 gate で吸収できるが、対照 PR で false positive 率を確認する
- **EC4**: tech-writer の Activation 拡張で、コード PR でも tech-writer が呼ばれるようになる。他 reviewer との重複が増えるため、Critic Phase の cross-validation dedup ロジックを確認する

#### セキュリティ

- **SEC1**: Phase B の tools inherit 化により、reviewer は引き続き Bash を含む全 tool へのアクセスを持つ。READ-ONLY ルール（agent prompt 内の制約）で Edit/Write を禁止している現状を維持する
- **SEC2**: Migration Guide で opus 推奨を明示する際、Anthropic 課金に関する明示的な注記を含める

#### パフォーマンス

- **PERF1**: Phase C で tech-writer の Activation pattern が広がると、多くの PR で tech-writer が呼ばれるようになる。`review.md` Phase 4 の並列実行上限（現在 ~13 reviewer）への影響を確認
- **PERF2**: verification mode の post-condition check（Phase 5.1.1）で retry が増えると API コストが増加。retry 上限を 1 回に制限する

#### 互換性

- **COMPAT1**: Phase B は breaking change。既存の rite plugin ユーザーは Claude Code の Task tool 仕様バージョン要件を満たす必要がある。Migration Guide で version pinning を明示
- **COMPAT2**: `rite-config.yml` のスキーマ変更は原則避ける。必要な場合は schema_version を上げる

<!-- Section ID: SPEC-META-OBSERVATION -->
## Meta-Observation: /verified-review 自体の品質上限（本セッション PR #350 再検証で追加）

本設計ドキュメント作成の 1 週間後 (2026-04-08)、PR #350 に対して `/verified-review` を再実行した際、**verified-review 自体の指摘にも LLM 由来の偽陽性が含まれる** ことが実測された:

- 本セッションの Explore agent は PR #350 の C1 (`$output_pattern` 未定義) / C3 (Phase 2.4 cat HEREDOC 未 wrap) / H1-H3 (mktemp 失敗時 retained flag 欠落) を「既修済み」と誤判定した
- 自分で `grep 'output_pattern=' fix.md` / `Read` で直接確認すると未修確定だった
- これは `/verified-review` (pr-review-toolkit) が general-purpose subagent を使う設計と直交する、**LLM の読解力限界そのもの**

### 含意

1. **Issue #355 の定量目標「カバレッジ率 70%」の分母 (baseline_V) の信頼性監査が必要**: Phase D の AC に signal rate 監査を追加 (baseline_V から FP を除外した baseline_V' で coverage_rate を判定)
2. **/rite:pr:review が /verified-review と同等になっても、上限は /verified-review の signal rate で決まる**: Issue #355 の achievable ceiling は最大でも /verified-review の signal rate × 100%
3. **上限を超えるには静的 lint (Phase C2) が必要**: agent-based review の読解力限界を補完するのは機械的な突き合わせしかない

### Phase D への反映

この観察は Phase 0 の症例研究 (項目 6) で定量化され、Phase D の signal rate 監査 AC で検証される。OOS7 (Issue #355 の scope 外事項) とは別の次元の問題として扱う。具体的な measurement は以下:

- **baseline_V の signal rate** = (実コードと突き合わせて true positive と判定された指摘数) / (verified-review が報告した全指摘数)
- **signal rate < 90% の場合**: baseline_V から FP を除外した baseline_V' を新たな分母とし、coverage_rate = (rite:pr:review での検出) / baseline_V' で判定する
- **signal rate < 70% の場合**: Issue #355 の定量目標そのものを再設計する decision point を発火させる (meta-objective の信頼性破綻)

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

以下は本 Issue のスコープに含めない（別 Issue として検討）:

- **OOS1**: pr-review-toolkit を rite plugin の依存として統合する案（撤回済み）
- **OOS2**: comment-accuracy-reviewer の新規追加（tech-writer 拡張で代替）
- **OOS3**: code-quality-reviewer への広範な Cross-Domain Catch-All 責務追加（責務重複リスクで縮小）
- **OOS4**: 13 reviewer の分割粒度の見直し（別 Issue: reviewer 再編成）
- **OOS5**: verification mode 以外のレビューサイクル最適化（別 Issue: review-fix loop 効率化）
- **OOS6**: fact-check.md の外部仕様検証の強化（既に機能しているため対象外）
- **OOS7**: PR #350 自体の追加修正（Issue #349 のスコープで完結扱い）
  - **補足 (本セッション 2026-04-08 で追加)**: ただし PR #350 の `/verified-review` 再実行で検出された以下 **7 件のマージブロッカー**は Issue #349 の scope 内として最終修正する (commit `d36f80f` で対応済み): C1 (output_pattern 未定義) / C3+H1 (Phase 2.4 cat HEREDOC wrap + mktemp retained flag) / H2 (Phase 4.2 report retained flag) / H3 (Phase 4.3.4 Issue 作成 retained flag) / H5 (pr_body_tmp_empty_or_missing issue_number suffix) / H6 (tech-writer anchor drift)。**非ブロッカー defer**: C2 (reason table 16 件 drift, runtime 非影響) は本設計ドキュメントの Phase A (#357) に吸収、H4 (Broad Retrieval gh api exit code) は Issue #354 で deferred 宣言済み。

## 関連資料

- プランファイル: `~/.claude/plans/lively-percolating-pnueli.md`（本 Issue 作成時の詳細設計メモ）
- PR #350: Issue #349 doc-heavy-review-mode（本改善のきっかけとなった PR）
- `docs/designs/reviewer-quality-improvement.md`（PR #285 発の前段改善）
- `~/.claude/commands/verified-review.md`（比較対象の user command）
- `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/pr-review-toolkit/agents/*.md`（参考にする外部 agent 群）
