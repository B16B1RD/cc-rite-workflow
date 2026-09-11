# Implementation Contract Section Mapping — Type → Section 3 / Perspective → Section 1-9

> **SoT scope**: Issue body の rich template (Section 1-9 structure) における **Type → Section 3 mapping** と **Perspective → Section 1-9 mapping** の rubric。`templates/issue/default.md` から SoT として参照される。`skills/issue-create/SKILL.md` ステップ 4.2 はこの rubric に従い Implementation Contract (Section 0-9) を生成する（Complexity Gate で確定 Complexity に応じてセクションをスケールする）。`skills/issue-create/SKILL.md` ステップ 1.3 / 4.1 で得た入力をどの Section に反映するかは本 reference の Step 2-3 と Section Inclusion Rules で定める。

## 位置づけ

Rich template (Section 1-9) を生成する場合の 4 step 構成:

| Step | 役割 | SoT |
|------|------|-----|
| Step 1 | Apply Complexity Gate (MUST/SHOULD/OMIT 判定) | [`complexity-gate.md`](./complexity-gate.md) |
| Step 2 | Select Type Core Section (Section 3) | 本 reference |
| Step 3 | Map Perspective inputs to Sections (Section 1-9) | 本 reference |
| Step 4 | Section template 適用 | [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) |

## Implementation Contract Section 1-9 概観

`templates/issue/template-structure.md` で定義される rich Issue body の section 構成:

| Section | 名称 | 主な内容 |
|---------|------|---------|
| 0 | Meta | Type / Complexity / Parent Issue (任意) |
| 1 | Goal | Goal / Non-goal |
| 2 | Scope | In Scope / Out of Scope |
| 3 | Type Core Section | Type に応じた core section (Step 2 で 1 つ選択) |
| 4.1 | Target Files | 変更対象ファイルリスト |
| 4.2 | Non-Target Files | MUST NOT modify 対象 |
| 4.3 | Interface / Data Contract | Before / After |
| 4.4 | Behavioral Requirements | MUST / SHOULD / MAY / MUST NOT |
| 4.5 | Error Handling / Constraints | Error Condition × Expected Behavior |
| 5 | Acceptance Criteria | Given / When / Then 形式の AC リスト |
| 6 | Test Specification | T-xx ID と Related AC mapping |
| 7 | Important Conventions | CLAUDE.md からの MUST/MUST NOT 抜粋 (max 5) |
| 8 | Definition of Done | 完了条件チェックリスト |
| 9 | Decision Log | 実装中の意思決定記録 |

各 Section の正規 template は [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md)、Complexity Gate の MUST/SHOULD/OMIT 判定は [`complexity-gate.md`](./complexity-gate.md) を参照。

## Step 2: Type → Type Core Section (Section 3) Mapping

`skills/issue-create/SKILL.md` ステップ 4.1 の AskUserQuestion で確定した Type に基づき、Section 3 として include する Type Core Section を選択する:

| Type | Section 3 内容 | template-structure.md 内 subsection |
|------|---------------|------------------------------------|
| Feature | User Scenarios | [`3-Feature: User Scenarios`](../../../templates/issue/template-structure.md#3-feature-user-scenarios) |
| BugFix | Bug Details (Reproduction / Root Cause Hypothesis) | [`3-BugFix: Bug Details`](../../../templates/issue/template-structure.md#3-bugfix-bug-details) |
| Refactor | Before / After Contract / Compatibility Policy | [`3-Refactor: Before / After Contract`](../../../templates/issue/template-structure.md#3-refactor-before--after-contract) |
| Chore | Operational Context | [`3-Chore: Operational Context`](../../../templates/issue/template-structure.md#3-chore-operational-context) |
| Docs | Documentation Target | [`3-Docs: Documentation Target`](../../../templates/issue/template-structure.md#3-docs-documentation-target) |

**Type 判定の優先順位**: Labels > title keywords > body content analysis。`skills/issue-create/SKILL.md` ステップ 4.1 の AskUserQuestion で確定する type は **Commit Type**（feat/fix/...）で、LLM がこの優先順位で推定したものを提示する。本表の `Type` 列は対応する **Contract Type**（Feature/BugFix/...）であり、Commit Type ↔ Contract Type の crosswalk は [`templates/issue/default.md` Type Definitions](../../../templates/issue/default.md#type-definitions) が SoT（本 reference では対応関係を再定義しない）。

## Step 3: Perspective → Target Sections Mapping

`skills/issue-create/SKILL.md` ステップ 1.3 (What/Why/Where 抽出) + ステップ 4.1 (AskUserQuestion 確認) で得られた input を、Section 1-9 のどの section に反映するかの mapping:

| Perspective | Target Sections |
|-------------|----------------|
| Technical Implementation | 4.1 Target Files / 4.3 Interface / Data Contract / 4.4 Behavioral Requirements |
| User Experience | 1 Goal / 3 Type Core (Feature scenarios) / 5 AC (Happy Path) |
| Edge Cases | 5 AC (Boundary / Error) / 6 Test Specification |
| Existing Feature Impact | 2 Scope (Out) / 4.2 Non-Target / 4.4 MUST NOT |
| Non-Functional Requirements | 4.5 Error Handling / Constraints / 5 AC (NFR outcome) / 6 Test Specification |
| Tradeoffs | 1 Non-goal / 4.4 SHOULD / MAY / 9 Decision Log |

逆方向 mapping (section から perspective を引く) が必要な場合は本表の右列を起点に検索する。

## Step 3.1: 探索サマリ Section → Contract Section Mapping (`/rite:unknowns` 連携時)

`skills/issue-create/SKILL.md` ステップ 1.3.1 で「# 探索サマリ:」見出し（[`skills/unknowns/SKILL.md`](../../unknowns/SKILL.md) セクション 4 の出力形式）を検出した場合、上記 Step 3 の通常 mapping に先立ち以下を適用する。線引き rationale は [`unknowns-boundary-rationale.md`](./unknowns-boundary-rationale.md#線引き) を参照。

| 探索サマリのセクション | マップ先 | 備考 |
|----------------------|---------|------|
| 出発点 | 1 Goal (Why) | ステップ 1.3 の Why 抽出結果として扱う |
| 確定したこと | 1 Goal (What) / 4.5 Constraints / 4.1 Target Files（実パスがあるとき） | 仮定解決済み扱い。ステップ 4.0/5.0 の仮定列挙（手順 1）から除外し再質問しない。実パスは Section 4.1 にも載せる |
| 却下した代替案 | 9 Decision Log | Section 9 が SHOULD/MUST になる Complexity（M 以上、[`templates/issue/default.md`](../../../templates/issue/default.md) Complexity Gate 参照）で生成時、`- {date} D-0N: {案}を不採用 / Reason: {却下理由} / Impact: {影響 Section}` 形式で記載する |
| 未解決の問い | ステップ 4.0/5.0 手順 3 の 3 分類 (b)/(c) | 手順 1（仮定列挙）を経由せず直接 (b) または (c) へ合流させる |
| 発見した盲点 | ステップ 4.0/5.0 手順 2（盲点列挙） | 手順 2 自体をスキップする（unknowns で実施済み扱い。前提とスキップの妥当範囲は [`unknowns-boundary-rationale.md#なぜ探索サマリ検出で-4050-を丸ごとスキップしないか`](./unknowns-boundary-rationale.md#なぜ探索サマリ検出で-4050-を丸ごとスキップしないか) 参照） |
| 成果物 | 1 Goal 本文 / 4.1 Target Files（実パスがあるとき） | 新規サブセクションは設けず `{what_to_achieve}` 内の参考リンクとして地の文に含める（`templates/issue/template-structure.md` の Section 構造は変更しない）。実パスは Section 4.1 にも載せる |

**セクション欠落時のフォールバック**: 見出しのみ・一部セクション欠落の入力では、存在するセクションのみ本表でマップし、欠落したセクションに対応する情報は通常の Step 1.3 抽出（What/Why/Where）へフォールバックする（エラーにしない）。サマリ外の追加テキストが入力に混在する場合も、そのテキストは通常の What/Why 抽出へ合流させる。

## Section Inclusion Rules

Step 2 で Section 3 を確定し、Step 3 で input を section に mapping した後、各 section の include / omit / placeholder 挿入を以下の rule で決定する:

| Condition | Behavior |
|-----------|----------|
| Perspective に対応する情報が input から取得できなかった | Target sections を omit (Complexity Gate で MUST 指定でない限り) |
| Perspective に対応する情報が input から取得できた | Target sections に input 結果を populate |
| Section が MUST だが input data なし | Section に placeholder comment (`<!-- 情報未収集 -->`) を含めて include。Section 4.1 File 列は例外（次行） |
| Section 4.1 File 列が MUST だが実パスなし | プレースホルダを置かず、4.2 実パス検査の「実パス 0 行」として扱う（作成せず案内して本文生成をやり直す） |
| Sub-Issue decompose path で `docs/designs/{slug}.md` が生成された場合 | 該当 design doc の内容を Section 4 (Implementation Details) の design context として include |

**MUST/SHOULD/OMIT の判定基準**: [`complexity-gate.md#complexity-heuristics-scoring`](./complexity-gate.md#complexity-heuristics-scoring) と [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) の Complexity Gate 表を参照。Complexity (XS/S/M/L/XL) ごとに各 section の include 必須度が決定される。

## 関連参照

- [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) — Section 1-9 の正規 markdown template
- [`templates/issue/default.md`](../../../templates/issue/default.md) — Complexity Gate / Type 定義の overview
- [`complexity-gate.md`](./complexity-gate.md) — Complexity (XS/S/M/L/XL) 判定基準と MUST/SHOULD/OMIT mapping
