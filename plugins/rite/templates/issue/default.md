# Issue Template: Implementation Contract

This template defines the "Implementation Contract" format for Issue body generation.
Claude reads this template when creating Issues via `/rite:issue-create` (ステップ 4.2)
and dynamically generates the Issue body based on Type and Complexity.

## Usage Instructions

- **Section headings**: English (maximizes LLM structural recognition)
- **Body text**: Follow `rite-config.yml` `language` setting
- **Dynamic generation**: Include/omit sections per Complexity Gate below
- **Type Core Section**: Use the matching type section only (Feature/BugFix/Refactor/Chore/Docs)
- **Placeholders**: Replace `{...}` with actual values; remove unused placeholders

---

## Type Definitions

> **Type 表記の SoT (crosswalk)**: 下表の `Commit Type` 列が、Issue body 構造で用いる **Contract Type** (Feature/BugFix/...) と Conventional Commits 系の **Commit Type** (feat/fix/...) の対応を定義する単一の Source of Truth。`skills/issue-create/SKILL.md` (Step 4.1 / 4.2)、`skills/issue-create/references/contract-section-mapping.md`、`templates/issue/template-structure.md` Section 3 はこの crosswalk を参照する（各箇所で対応関係を再定義しない）。

| Type (Contract) | Commit Type | Characteristic Section | Heuristics |
|-----------------|-------------|----------------------|------------|
| Feature | feat | User Scenarios | New user-facing functionality or workflow |
| BugFix | fix | Bug Details (Reproduction, Root Cause) | Symptom + repro steps + incorrect current behavior |
| Refactor | refactor | Before/After Contract, Compatibility Policy | Internal structure improvement, compatibility considerations |
| Chore | chore | Operational Context | Maintenance/tooling/dependency update, no behavior change |
| Docs | docs | Documentation Target | Documentation addition/update is the primary deliverable |

### Type Notation Policy

rite には 2 つの正当な type 語彙が併存する:

- **Contract Type** (Feature/BugFix/Refactor/Chore/Docs): Issue body の Section 3 名・本テーブルなど **body 構造選択**の語彙。
- **Commit Type** (feat/fix/refactor/chore/docs): commit message / branch 名 / PR title の語彙（CLAUDE.md が必須と規定する Conventional Commits 由来。`pr/open.md` の branch type 派生もこの系列）。

**判断**: どちらか一方へ統一せず、両系列を残し上表 `Commit Type` 列を単一 crosswalk SoT とする。**根拠**: 統一しても seam は消えず別境界（Issue body ↔ commit/branch）へ移動するだけで、Conventional Commits は外部標準として commit/branch に不可欠、Contract Type は section 名として可読。境界マッピングを 1 箇所で明示するのが drift を最小化する。非自明な対応は `feat↔Feature` / `fix↔BugFix` のみ（他は大文字小文字差）。

## Complexity Gate

Legend: `M` = MUST (required), `S` = SHOULD (recommended), `O` = OMIT (skip)

| Section | XS | S | M | L | XL |
|---------|-----|-----|-----|-----|-----|
| 0. Meta | M | M | M | M | M |
| 1. Goal | M | M | M | M | M |
| 2. Scope (In/Out) | M | M | M | M | M |
| 3. Type Core Section | S | M | M | M | M |
| 4. Implementation Details (parent) | M | M | M | M | M |
| 4.1 Target Files | M | M | M | M | M |
| 4.2 Non-Target Files | S | M | M | M | M |
| 4.3 Interface / Data Contract | O | S | M | M | M |
| 4.4 Behavioral Requirements | M | M | M | M | M |
| 4.5 Error Handling / Constraints | O | S | M | M | M |
| 5. Acceptance Criteria | M | M | M | M | M |
| 6. Test Specification | O | S | M | M | M |
| 7. Important Conventions | O | S | M | M | M |
| 8. Definition of Done | M | M | M | M | M |
| 9. Decision Log | O | O | S | M | M |

**Gate rules**:
- `M`: Always include. Use placeholder comment if information unavailable.
- `S`: Include if information gathered during interview. Omit silently if not discussed.
- `O`: Do not include unless user explicitly requests.

---

## Complexity Heuristics

> **Moved**: 本セクションの定義は [`../../skills/issue-create/references/complexity-gate.md#complexity-heuristics-scoring`](../../skills/issue-create/references/complexity-gate.md#complexity-heuristics-scoring) に移動しました。Score テーブル (6 条件、各 +1) と Score → complexity mapping (0-1=XS / 2=S / 3-4=M / 5=L / 6+=XL) を参照してください。本テンプレート内の Heuristics 表は SoT (`references/complexity-gate.md`) の単一定義に集約されています。

---

## Template Structure

> **Extracted to separate file**: The full section-by-section template (Sections 0-9) has been
> moved to [template-structure.md](./template-structure.md) to reduce context consumption.
> Read that file only when generating the Issue body (ステップ 4.2).

### Section Overview

| Section | Content | Complexity Gate Reference |
|---------|---------|--------------------------|
| 0. Meta | Type, Complexity, Parent Issue | Always MUST |
| 1. Goal | What to achieve + Non-goal | Always MUST |
| 2. Scope | In Scope / Out of Scope | Always MUST |
| 3. Type Core | Type-specific section (Feature/BugFix/Refactor/Chore/Docs) | XS: SHOULD, S+: MUST |
| 4. Implementation Details | Target Files, Non-Target, Interface, Behavioral Req, Error Handling | Varies (4.1/4.4: Always MUST, others: XS-S vary) |
| 5. Acceptance Criteria | Given/When/Then format | Always MUST |
| 6. Test Specification | Test case table linked to ACs | S: SHOULD, M+: MUST |
| 7. Important Conventions | CLAUDE.md conventions | S: SHOULD, M+: MUST |
| 8. Definition of Done | Completion checklist | Always MUST |
| 9. Decision Log | Implementation decisions | M: SHOULD, L+: MUST |

---

## Interview to Template Mapping

> **Moved**: Interview Perspective → Target Sections の正規 mapping table は [`skills/issue-create/references/contract-section-mapping.md#step-3-perspective--target-sections-mapping`](../../skills/issue-create/references/contract-section-mapping.md#step-3-perspective--target-sections-mapping) に移動しました。本 template から interview mapping を参照する場合は本 reference を経由すること。

---

## Output Validation Checklist

After generating the Issue body, verify all items:

- [ ] Type and Complexity are set in Meta
- [ ] All MUST sections for the complexity level are present
- [ ] AC count matches complexity guideline
- [ ] Each AC has a corresponding Test Case ID (T-xx)
- [ ] Target Files list exists with file paths
- [ ] All MUST requirements are testable (no vague verbs)
- [ ] No empty headings (remove section if no content)

---

🤖 Generated with [rite workflow](https://github.com/B16B1RD/cc-rite-workflow)
