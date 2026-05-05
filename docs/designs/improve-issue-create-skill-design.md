# `/rite:issue:create` ワークフロー全面改善 — PDF Skill ガイド + Claude Code 公式仕様準拠

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

Anthropic 公式 Skill Building Guide (PDF 33 ページ) と Claude Code 公式仕様 (`https://code.claude.com/docs/en/skills.md` (取得日: 2026-04 時点) — "Custom commands have been merged into skills"、`description` は両者ともに auto-trigger 判定用) に準拠する形で、`/rite:issue:create` ワークフロー (orchestrator + 3 sub-skills + references + hooks tests + metrics) を段階的に改善する。

改善は P0-P4 の優先度別 phase として 13 改善ポイントに分解し、各 phase / 各 P を独立 Issue + 独立 PR として実施可能な構造とする。すべての改善は **rite empirical defense (4-site 対称化 / AC-3 grep 検証 phrase / Issue #444-#660 防御層実装) を保護対象として破壊しない** 制約のもとで行う。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

### 動機

PDF (33 ページ) と Claude Code 公式仕様確認の結果、`/rite:issue:create` 関連ファイル群 (`commands/issue/create*.md` 4 ファイル合計 2,902 行、`skills/rite-workflow/SKILL.md`) に以下の構造的ギャップが判明した:

1. **Auto-trigger 性能の低下** (P0): `commands/*.md` の `description` フィールドは `SKILL.md` と機能統合されており、両者ともに Claude が常に context に読み込む auto-trigger 判定用テキスト。現状 `commands/issue/create.md` の description は「新規 Issue を作成し、GitHub Projects に追加」と短文・トリガーフレーズなしで、PDF Bad example "missing triggers" / "too vague" に該当。`SKILL.md` の description にも「Issue 起票」「create issue」「起票」が欠落。
2. **本体ファイルの肥大化** (P1): `create.md` 単体で 835 行 (≒10,000+ words 級) は、PDF p.27 「Keep SKILL.md under 5,000 words」「Move detailed reference to separate files」に違反。`commands/pr/references/` のような subdirectory が `commands/issue/` には存在せず、防御層メタ情報・Pre-check list・DRIFT-CHECK ANCHOR が手順本体に混在。
3. **PDF 推奨セクション欠如** (P2): `## Examples` (PDF p.12 推奨) / `## Troubleshooting` (PDF p.25-27 推奨) セクションが存在しない。
4. **検証フレームワーク不整備** (P4): PDF p.16 推奨の 3 層テスト (Triggering / Functional / Performance) のうち、現状は hook tests で functional 部分のみ。Triggering 適合率測定 / Performance baseline / 4-site 対称化 drift detector が不在。
5. **UX 最適化余地** (P3): AskUserQuestion 過多 (9+ 箇所) / Phase 0.4 + 0.4.1 の連続質問。

### 目的

- PDF Skill 設計原則 (Description-first / Progressive Disclosure / Examples / Troubleshooting / 3 層テスト) を満たす
- rite empirical defense (4-site 対称化 / AC-3 grep 検証 / Issue #444-#660 防御層) を破壊しない
- 各 P を独立 PR / Issue として実施可能な段階的・可逆的構造を維持
- dogfooding 中の inconsistent state を avoid するため、Phase 単位での rollout / rollback 戦略を併せて整備

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

#### FR-1: P0 Auto-trigger 改善 (最優先、低コスト・高 ROI)

- **FR-1.1**: `plugins/rite/skills/rite-workflow/SKILL.md` の `description` フィールド末尾の "Activates on" リストに、Issue 起票系トリガーフレーズを追加する。具体的には `"create issue"`, `"new issue"`, `"起票"`, `"Issue を作成"`, `"タスクを登録"`, `"Issue 化"`, `"新規 Issue"`, `"start issue"`, `"create PR"` 等。
- **FR-1.2**: `plugins/rite/commands/issue/create.md` の `description` を PDF パターン `[What it does] + [When to use] + [Key capabilities]` で書き直し、front-load にトリガーフレーズを配置する。
- **FR-1.3**: `plugins/rite/commands/issue/create-interview.md` / `create-decompose.md` / `create-register.md` の 3 sub-skill description に negative trigger を明記する (`(Internal sub-skill — invoked by /rite:issue:create only. Do NOT invoke directly.)`)。

#### FR-2: P1 構造改革 (中優先、構造改善)

- **FR-2.1**: `plugins/rite/commands/issue/references/` ディレクトリを新設し、本体から以下の 8 ファイルを抽出する:
  - `sub-skill-handoff-contract.md` (4-site 対称化の正規定義)
  - `pre-check-routing.md` (sub-skill return 直後の routing dispatcher)
  - `edge-cases-create.md` (EDGE-2 / 3 / 4 / 5 の正規定義)
  - `complexity-gate.md` (XS/S/M/L/XL 判定基準と Heuristics Scoring)
  - `slug-generation.md` (slug 生成ルール SoT)
  - `regression-history.md` (Issue #444-#660 の防御層導入経緯)
  - `contract-section-mapping.md` (Implementation Contract Section 1-9 への interview 結果 mapping)
  - `bulk-create-pattern.md` (単一 Bash invocation での連結パターン)
- **FR-2.2**: `create.md` 冒頭に Happy Path Overview (≤30 行) を追加し、5 ステップのフロー図で全体像を即座に把握可能にする。
- **FR-2.3**: 強調マーカー (🚨=12 / ⚠️=6 / 🚫=2 / MUST=20) を **過剰削減ではなく適正化** する。AC-3 grep 検証対象 4 phrase (`anti-pattern` / `correct-pattern` / `same response turn` / `DO NOT stop`) は **本体に残す** ことが必須。
- **FR-2.4**: 抽出後の `create.md` 本体は ≤250 行を目標とする (設計着手時の baseline 835 行から約 30% へのスリム化)。

#### FR-3: P2 PDF 推奨セクション追加 (中優先、UX 改善)

- **FR-3.1**: `references/troubleshooting-create.md` を新設し、症状→原因→対処の表形式で 6 項目以上を整備する。対象: gh issue create blocked / Sub-issues API linkage 失敗 / sentinel 後 turn 終了 / Projects 未登録警告 / 重複作成 / sub-skill 誤 auto-trigger。
- **FR-3.2**: `create.md` 末尾に `## Examples` セクション (3-4 ケース、≤80 行) を追加する。User says → Actions → Result 形式で、単一機能追加 (M) / XL auto-decompose / Bug Fix (interview skip) / 重複検出 を網羅する。

#### FR-4: P3 UX 最適化 (低優先、影響限定)

- **FR-4.1**: `create.md` Phase 0.4 + `create-interview.md` Phase 0.4.1 の連続 AskUserQuestion を統合し、初期分類質問 (種別 + 規模感) を 1 つの AskUserQuestion 呼び出しで取得する。
- **FR-4.2**: Pre-check list (Item 0/1/2/3) を `references/pre-check-routing.md` に移動し、本体には 1 段落のサマリのみ残す (FR-2.1 の subitem)。

#### FR-5: P4 検証 / テスト (低優先、品質保証)

- **FR-5.1**: `plugins/rite/skills/rite-workflow/tests/issue-create-triggers.md` を新設し、Should trigger / Should NOT trigger の 7+7 クエリを記録する (Triggering test)。
- **FR-5.2**: `plugins/rite/scripts/measure-create-metrics.sh` を新設し、5 項目の rite 固有運用 metrics (Implicit-stop 発生率 / Sub-skill chain 完走率 / AskUserQuestion 平均回数 / 重複検出率 / Examples coverage) を測定可能にする。
- **FR-5.3**: 既存の `plugins/rite/hooks/tests/4-site-symmetry.test.sh` (Issue #771 で導入済み) を rite empirical defense の監視点として保護対象とする。同 test は `create.md` / `create-interview.md` の 2 site 横断で `--phase` / `--active` / `--next` / `--preserve-error-count` の引数 symmetry を grep 検証する。`stop-guard.sh` は Issue #674 で removal 済みのため対象外。`phase-transition-whitelist.sh` は sourced library で CLI 引数を取らないため対象外 (test 内の SCOPE adjustment コメント参照)。本 sub-issue では新設ではなく既存 test の保護を担当する。
- **FR-5.4**: `docs/measurements/issue-create-baseline.md` を新設し、P0-1 + P0-2 適用前/後の 3 ケース (M / XL / Bug Fix) の metrics 比較を記録する。

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

- **NFR-1 (互換性)**: rite empirical defense の **4-site 対称化** (canonical メタ契約 SoT は `plugins/rite/hooks/tests/4-site-symmetry.test.sh` の冒頭コメント — Issue #831 で旧 reference `plugins/rite/commands/issue/references/sub-skill-handoff-contract.md` を削除し test 自身に集約) の bash literal 同期を維持する。occurrence 集計は粒度別に 2 つの観点で扱う: (a) **test 監視 scope** (`4-site-symmetry.test.sh` が CLI 引数 symmetry を grep 検証する範囲) は `--phase` / `--active` / `--next` / `--preserve-error-count` の機能コード bash block で **2 ファイル × 各 2 occurrence = 4 occurrence**、(b) **caller 側を含む全体メタ契約** (機能コード + caller HTML inline literal を含む) は `sub-skill-handoff-contract.md` cycle 3 で確定の **3 site / 6 occurrence** (詳細は同 SoT を参照)。`--phase` / `--active` / `--next` / `--preserve-error-count` の引数 symmetry を破壊する変更は禁止。`stop-guard.sh` WORKFLOW_HINT は **Issue #674 で removal 済み** のため historical site として除外 (将来再導入時は site 追加検討)。「4-site 対称化」表記は historical な呼称 (旧 4 site 構成時代の固有名) として保持する。
- **NFR-2 (互換性)**: AC-3 grep 検証対象 4 phrase は `create.md` 本体に **必ず残す** (`grep -c` で各 1 以上を維持)。
- **NFR-3 (互換性)**: HTML-comment sentinel 形式 (`<!-- [interview:skipped] -->` / `<!-- [create:completed:N] -->`) を維持する。Issue #561 D-01 の bare bracket 形式 → HTML comment 形式への移行は完了済みであり、再リグレッションを起こさない。
- **NFR-4 (互換性)**: Phase ナンバリング契約 (Phase 0.1 / 0.4.1 / 0.6.2 等) は hook test や stop-guard との接続点であり、rename しない。FR-2.x は Phase 名ベースの rename を行わない (代替案 B 却下理由)。
- **NFR-5 (可逆性)**: 各 P (P0/P1/P2/P3/P4) は独立 PR として `develop` にマージ可能とし、回帰検出時は該当 PR を revert することで rollback できる構造を維持する。
- **NFR-6 (Progressive Disclosure)**: PDF p.5, p.13 「SKILL.md ≤5,000 words」原則に従い、`create.md` 本体 ≤250 行を目標とする。詳細は `references/` へ逃がす。
- **NFR-7 (検証可能性)**: 静的検証 (`wc -l` / `grep -c` / `bash 4-site-symmetry.test.sh`) と回帰テスト (既存 `plugins/rite/hooks/tests/` 全件 pass / `/rite:lint`) で改善効果を機械的に確認できる構造とする。

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

### 1. PDF 規範 vs rite empirical defense — 緊張関係の扱い

PDF が想定していない問題領域 (LLM が sub-skill return 直後に turn を勝手に閉じる問題 / 4-site 対称化 / Anti-pattern / Correct-pattern / DRIFT-CHECK ANCHOR の繰り返し記述) は **保護対象** とし、PDF p.27 「Keep SKILL.md under 5,000 words」と真っ向対立する場合は **rite 固有の防御層を優先** する。改善は「PDF 原則と矛盾せず、かつ rite の防御層を破壊しない範囲」で行う (本プラン §「PDF 規範 vs rite empirical defense」)。

### 2. PDF Pattern 適合性

`/rite:issue:create` は PDF Chapter 5 の **Pattern 1 (Sequential workflow orchestration) + Pattern 5 (Domain-specific intelligence)** のハイブリッドが core。改善は両 Pattern の Key techniques を強化する方向で行う (本プラン §「PDF Pattern への位置付け」)。

### 3. PDF Use Case Category 位置付け

rite は PDF p.8-9 の **Category 2: Workflow Automation** に該当 (本プラン §「PDF Use Case Category への位置付け」)。Step-by-step workflow with validation gates / Templates for common structures / Built-in review and improvement suggestions / Iterative refinement loops の 4 Key techniques を磨く方向で改善する。

### 4. Skill folder 化の見送り

PDF が言う SKILL.md フォルダ形式への変換は **対象外**。理由: rite は commands + Skill のハイブリッド構造で意図的設計、CLAUDE.md「ワークフローの方針は rite-config.yml、commands/、skills/ で表現」と矛盾するため (本プラン §「Out of Scope」)。

### 5. 段階的 phase 構造と Rollback 戦略

各 P を独立 Issue として起票し、CI / 手動テスト pass を確認してから次に進む。dogfooding 中の inconsistent state を避けるため、Phase 1 (P0 auto-trigger 改善、低リスク) → Phase 2 (P1 構造改革、要慎重) → Phase 3 (P2 PDF 推奨セクション追加) → Phase 4 (P3 UX 最適化) → Phase 5 (P4 検証強化) の順序で実施。Phase 2 (P1-3 大規模 refactor) 中は `/rite:issue:create` を **使わない** または `develop` ブランチで作業する運用とする (本プラン §「dogfooding 運用」)。

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

| コンポーネント | 責務 | 改修範囲 |
|---|---|---|
| **`skills/rite-workflow/SKILL.md`** | rite-workflow plugin のエントリポイント Skill。Auto-trigger 判定用 description を保持 | P0-1 (description にトリガーフレーズ追加) |
| **`commands/issue/create.md`** | Issue 作成 orchestrator。Phase 0.1 - 0.6 / Delegation Routing | P0-2 / P1-3 / P1-4 / P1-5 / P2-6 / P3-9 |
| **`commands/issue/create-interview.md`** | 適応的インタビュー sub-skill (Phase 0.4.1 + 0.5) | P0-2 / P1-3 / P3-8 |
| **`commands/issue/create-decompose.md`** | 仕様書生成 + 分解 + 一括作成 sub-skill (Phase 0.7 - 0.9) | P0-2 / P1-3 |
| **`commands/issue/create-register.md`** | 単一 Issue 確認・作成 sub-skill (Phase 1 - 4) | P0-2 / P1-3 |
| **`commands/issue/references/`** (新設、Issue #773 で逐次抽出中。本 PR 3/8 時点で 3 ファイル merged: `sub-skill-handoff-contract.md` / `pre-check-routing.md` / `edge-cases-create.md`) | 抽出された詳細リファレンス 8 + Troubleshooting 1 | FR-2.1 / FR-3.1 |
| **`skills/rite-workflow/tests/`** (新設) | Triggering test 配置場所 | FR-5.1 |
| **`hooks/tests/4-site-symmetry.test.sh`** (既存、Issue #771 で導入済み) | 4-site 対称化 grep test (保護対象) | FR-5.3 |
| **`scripts/measure-create-metrics.sh`** (新規) | rite 固有 metrics 測定 | FR-5.2 |
| **`docs/measurements/`** (新設) | Performance baseline 記録 | FR-5.4 |

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

```
ユーザー入力
  ↓
[skills/rite-workflow/SKILL.md] auto-trigger 判定 (P0-1 で精度向上)
  ↓
[commands/issue/create.md] Happy Path 冒頭 (P1-4) → Phase 0.1 - 0.6 → Delegation Routing
  ↓                                           ↓ (詳細は references/ 参照、P1-3 で抽出)
  ↓                                  references/sub-skill-handoff-contract.md
  ↓                                  references/pre-check-routing.md
  ↓                                  references/edge-cases-create.md
  ↓                                  references/complexity-gate.md
  ↓                                  references/slug-generation.md
  ↓                                  references/regression-history.md
  ↓                                  references/contract-section-mapping.md
  ↓                                  references/bulk-create-pattern.md
  ↓                                  references/troubleshooting-create.md (P2-7)
  ↓
[create-interview.md / create-decompose.md / create-register.md]
  ↓
Issue 作成完了 + [create:completed:{N}] sentinel emit
  ↓ (検証層、P4 で整備)
[hooks/tests/4-site-symmetry.test.sh] (FR-5.3)
[skills/rite-workflow/tests/issue-create-triggers.md] (FR-5.1)
[scripts/measure-create-metrics.sh] (FR-5.2)
[docs/measurements/issue-create-baseline.md] (FR-5.4)
```

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

#### 既存ファイル (修正)

下記「baseline 行数」は設計着手時 (Issue #768 起票時) のスナップショット。PR 進行に伴い実際の行数は変動する (例: PR 3/8 完了時点で `create.md`=757 / `create-interview.md`=534)。改修進捗の 1 次 source は **Issue #773 のチェックリスト** を参照すること。

| パス | baseline 行数 (設計着手時) | 改修内容 | 関連 Sub-Issue |
|---|---|---|---|
| `plugins/rite/skills/rite-workflow/SKILL.md` | 209 | description にトリガーフレーズ追加 | P0-1 |
| `plugins/rite/commands/issue/create.md` | 835 | description 書き直し / references 抽出 / Happy Path 追加 / 強調適正化 / Examples 追加 / Pre-check 簡素化 | P0-2 / P1-3 / P1-4 / P1-5 / P2-6 / P3-9 |
| `plugins/rite/commands/issue/create-interview.md` | 642 | description + negative trigger / DRIFT-CHECK ANCHOR 抽出 / Phase 0.4 + 0.4.1 統合 | P0-2 / P1-3 / P3-8 |
| `plugins/rite/commands/issue/create-decompose.md` | 778 | description + negative trigger / Phase 0.9.x bash パターン抽出 | P0-2 / P1-3 |
| `plugins/rite/commands/issue/create-register.md` | 647 | description + negative trigger / Implementation Contract mapping 抽出 | P0-2 / P1-3 |

#### 新規ファイル

| パス | 内容 | 関連 Sub-Issue |
|---|---|---|
| `plugins/rite/commands/issue/references/sub-skill-handoff-contract.md` | 4-site 対称化の正規定義 | P1-3 |
| `plugins/rite/commands/issue/references/pre-check-routing.md` | sub-skill return 直後の routing dispatcher | P1-3 / P3-9 |
| `plugins/rite/commands/issue/references/edge-cases-create.md` | EDGE-2 / 3 / 4 / 5 の正規定義 | P1-3 |
| `plugins/rite/commands/issue/references/complexity-gate.md` | XS/S/M/L/XL 判定 + Heuristics Scoring | P1-3 |
| `plugins/rite/commands/issue/references/slug-generation.md` | slug 生成ルール SoT | P1-3 |
| `plugins/rite/commands/issue/references/regression-history.md` | Issue #444-#660 防御層導入経緯 | P1-3 / P1-5 |
| `plugins/rite/commands/issue/references/contract-section-mapping.md` | Implementation Contract Section mapping | P1-3 |
| `plugins/rite/commands/issue/references/bulk-create-pattern.md` | 単一 Bash invocation 連結パターン | P1-3 |
| `plugins/rite/commands/issue/references/troubleshooting-create.md` | 症状→原因→対処の表 (6+ 項目) | P2-7 |
| `plugins/rite/skills/rite-workflow/tests/issue-create-triggers.md` | Should trigger / Should NOT trigger の 7+7 クエリ | P4-10 |
| `plugins/rite/scripts/measure-create-metrics.sh` | 5 項目 metrics 測定スクリプト | P4-11 |
| `docs/measurements/issue-create-baseline.md` | Performance baseline 記録 | P4-13 |

<!-- `hooks/tests/4-site-symmetry.test.sh` は Issue #771 で既に導入済み (FR-5.3 / SPEC-ARCH-COMPONENTS 参照)。本表は新規ファイル一覧のため除外する。 -->

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

#### エッジケース / リスク (本プラン §「Risks & Mitigations」と Rollback 戦略から抜粋)

1. **Auto-trigger over-trigger 副作用 (P0)**: description にトリガーフレーズ追加で Issue 起票無関係なクエリでも auto-fire するリスク。**Mitigation**: P4-10 trigger test で should-NOT-trigger ケース (例: 「今ある Issue 一覧見せて」 → /rite:issue:list、「PR を作って」 → /rite:pr:create) を整備し、偽陽性 0% を目標。
2. **AC-3 grep 検証 / 4-site 対称化破壊 (P1)**: P1-3 の references 抽出で `anti-pattern` / `correct-pattern` / `same response turn` / `DO NOT stop` 4 phrase を本体から削ると CI grep 検証が落ちる。**Mitigation**: NFR-2 で「本体に必ず残す」を明文化。**P4-12 (Issue #771 で導入済みの `4-site-symmetry.test.sh`)** を pre-merge gate として運用し、references 抽出 PR ごとに `bash plugins/rite/hooks/tests/4-site-symmetry.test.sh` の pass を確認する。
3. **内部リンク破壊 (P1-3)**: `./create.md#section` 参照が `./references/*.md#section` に変わる。**Mitigation**: refactor 中に `grep -r 'create.md#'` で全箇所書き換え対象を網羅。各 references PR で個別検証。
4. **dogfooding 中の inconsistent state (P1-3)**: 大規模 refactor 中に `/rite:issue:create` を実行すると create.md と references/ の整合不良で workflow が壊れる可能性。**Mitigation**: Phase 2 中は `/rite:issue:create` を使わない、または `develop` 以外の feature branch で作業。問題発生時は `main` から hotfix を切る運用。
5. **Examples coverage の代理指標としての偏り (P4-11)**: 「Examples coverage ≥70%」は数値最適化に偏ると質的改善が後回しになる。**Mitigation**: 数値 metrics と並行して、月次の質的レビュー (実 Issue を 5 件サンプリング) を併用。
6. **Sub-Issue 4 (P1-3) の単一 PR 巨大化リスク**: 8 references 抽出 + 4 ファイル refactor を 1 PR にすると review コストが過大。**Mitigation**: プラン §「Rollback 戦略」に従い、references ごとに個別 PR (例: `sub-skill-handoff-contract.md` だけで 1 PR、`pre-check-routing.md` で 1 PR) に分割。create-decompose で本 Sub-Issue を **さらに細分化を検討**。

#### セキュリティ

該当なし (workflow 内部の文書 / スクリプト改善のみで、外部 API / token / シークレット取扱に変更なし)。

#### パフォーマンス

- LLM context 占有量: `create.md` 835 → 250 行 (約 70% 削減) で、orchestrator 起動時の context overhead を低減。
- AskUserQuestion 回数: P3-8 で Phase 0.4 + 0.4.1 統合により M complexity ケースで -1 回。

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

- **Skill folder 化**: PDF が言う SKILL.md フォルダ形式への変換 (CLAUDE.md「ワークフローの方針は rite-config.yml、commands/、skills/ で表現」と矛盾)
- **API 経由でのスキル運用**: `container.skills` 等の API 配信 (rite-workflow はローカル plugin として配布)
- **`/rite:issue:start` / `/rite:issue:edit` 等の他コマンド**: 本改善は `/rite:issue:create` フローに限定
- **`commands/issue/parent-routing.md` (357 行) / `child-issue-selection.md` (207 行) / `branch-setup.md` (153 行)**: 他コマンドから参照される共通モジュール
- **i18n の英語完全対応**: Phase 0.5 (Deep-Dive Interview) の templates 英語版は別途対応
- **`templates/issue/` の改善**: interview-perspectives.md / template-structure.md / default.md は本改善の対象外
