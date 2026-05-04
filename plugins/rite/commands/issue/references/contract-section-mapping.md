# Implementation Contract Section Mapping — Interview → Section 1-9

> **Source of Truth**: 本ファイルは `/rite:issue:create` ワークフローにおける Issue Body 生成時の **Implementation Contract Section 1-9 への mapping** の SoT である。`create-register.md` Phase 2.2 (Step 2 Type Core Section / Step 3 Map Interview Results to Sections) と `create-decompose.md` Phase 0.7.3 cancel path の mapping 参照は本ファイルへ semantic 参照する。
>
> **抽出経緯**: Type → Section 3 mapping table・Interview Perspective → Target Sections mapping table・Section inclusion rules table の 3 つの mapping 表が `create-register.md` Phase 2.2 Step 2-3 に集約されていた状況を、Issue #773 (#768 P1-3) PR 7/8 で本 reference に集約。Step 4-6 (AC 生成 / Test 仕様 / Output Validation) は Implementation Contract の **生成手順** であり mapping ではないため、本 reference には含めず `create-register.md` 本体に維持する。

## 位置づけ

`create-register.md` Phase 2.2 における Implementation Contract format の生成は以下の 6 step で構成される:

| Step | 役割 | SoT |
|------|------|-----|
| Step 1 | Apply Complexity Gate (MUST/SHOULD/OMIT 判定) | [`complexity-gate.md`](./complexity-gate.md) |
| **Step 2** | **Select Type Core Section (Section 3)** | **本 reference** |
| **Step 3** | **Map Interview Results to Sections (Section 1-9)** | **本 reference** |
| Step 4 | Generate Acceptance Criteria (AC 生成順序 / writing rules) | `create-register.md` 本体 |
| Step 5 | Generate Test Specification Table | `create-register.md` 本体 |
| Step 6 | Output Validation Checklist | `create-register.md` 本体 |

本 reference は **Step 2 (Type → Section 3 mapping) と Step 3 (Interview → Section 1-9 mapping)** の正規定義を集約する。Section 1-9 の **template 定義** (各 Section の markdown skeleton) は [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) を参照すること。

## Implementation Contract Section 1-9 概観

`templates/issue/template-structure.md` で定義される Issue body の section 構成:

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

各 Section の正規 template は [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) を参照。Complexity Gate による MUST/SHOULD/OMIT 判定は [`complexity-gate.md`](./complexity-gate.md) を参照。

## Step 2: Type → Type Core Section (Section 3) Mapping

Phase 1.2 で確定した Type に基づき、Section 3 として include する Type Core Section を選択する:

| Type | Section 3 内容 | template-structure.md 参照 |
|------|---------------|---------------------------|
| Feature | User Scenarios | `3-Feature: User Scenarios` |
| BugFix | Bug Details (Reproduction / Root Cause Hypothesis) | `3-BugFix: Bug Details` |
| Refactor | Before / After Contract / Compatibility Policy | `3-Refactor: Before / After Contract` |
| Chore | Operational Context | `3-Chore: Operational Context` |
| Docs | Documentation Target | `3-Docs: Documentation Target` |

**Type 判定の優先順位**: Labels > title keywords > body content analysis (`create-register.md` Phase 1.2 参照)。

## Step 3: Interview Perspective → Target Sections Mapping

Phase 0.5 interview で収集した観点 (Perspective) を、Section 1-9 のどの section に反映するかの mapping:

| Interview Perspective | Target Sections |
|----------------------|----------------|
| Technical Implementation | 4.1 Target Files / 4.3 Interface / Data Contract / 4.4 Behavioral Requirements |
| User Experience | 1 Goal / 3 Type Core (Feature scenarios) / 5 AC (Happy Path) |
| Edge Cases | 5 AC (Boundary / Error) / 6 Test Specification |
| Existing Feature Impact | 2 Scope (Out) / 4.2 Non-Target / 4.4 MUST NOT |
| Non-Functional Requirements | 4.5 Error Handling / Constraints / 5 AC (NFR outcome) / 6 Test Specification |
| Tradeoffs | 1 Non-goal / 4.4 SHOULD / MAY / 9 Decision Log |

**逆方向 mapping (section から perspective を引く)** が必要な場合は本表の右列を起点に検索すること。

## Section Inclusion Rules

Step 2 で Section 3 を確定し、Step 3 で interview 結果を section に mapping した後、各 section の include / omit / placeholder 挿入を以下の rule で決定する:

| Condition | Behavior |
|-----------|----------|
| Interview not conducted for a perspective | Omit target sections (unless MUST by Complexity Gate) |
| Interview conducted for a perspective | Populate target sections with interview results |
| Section is MUST but no interview data | Include section with placeholder comment (`<!-- 情報未収集 -->`) |
| Phase 0.7 cancel path with specification document | Include `docs/designs/{slug}.md` content as design context in Section 4 (Implementation Details). Pre-validated specification supplements interview results for Section 4.1-4.5 |
| Phase 0.3-0.5 all skipped (`phases_skipped: "0.3-0.5"`) | Apply [EDGE-3 row 4](./edge-cases-create.md#edge-3-interview-result-reflection-rules): populate all MUST sections per Complexity Gate using Phase 0.1 context (What/Why/Where). For MUST sections where no data is available from Phase 0.1, include `<!-- 情報未収集 -->` placeholder. AI-inferred content is marked with `（推定）`. SHOULD/OMIT sections follow normal Gate rules |

**MUST/SHOULD/OMIT の判定基準**: [`complexity-gate.md#complexity-gate-section-inclusion`](./complexity-gate.md) を参照。Complexity (XS/S/M/L/XL) ごとに各 section の include 必須度が決定される。

## 関連参照

- [`templates/issue/template-structure.md`](../../../templates/issue/template-structure.md) — Section 1-9 の正規 markdown template
- [`templates/issue/default.md`](../../../templates/issue/default.md) — Complexity Gate / Type 定義の overview
- [`complexity-gate.md`](./complexity-gate.md) — Complexity (XS/S/M/L/XL) 判定基準と MUST/SHOULD/OMIT mapping
- [`edge-cases-create.md`](./edge-cases-create.md) — EDGE-3 Interview Result Reflection Rules (`phases_skipped` ハンドリング)
- [`sub-skill-handoff-contract.md`](./sub-skill-handoff-contract.md) — orchestrator / sub-skill 間 hand-off の正規定義
- [`regression-history.md`](./regression-history.md) — 本 reference を含む `/rite:issue:create` ワークフロー周辺の incident 時系列史
