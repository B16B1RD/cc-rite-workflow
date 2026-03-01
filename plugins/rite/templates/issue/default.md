# Issue Template: Implementation Contract

This template defines the "Implementation Contract" format for Issue body generation.
Claude reads this template when creating Issues via `/rite:issue:create` (Phase 2.2)
and dynamically generates the Issue body based on Type and Complexity.

## Usage Instructions

- **Section headings**: English (maximizes LLM structural recognition)
- **Body text**: Follow `rite-config.yml` `language` setting
- **Dynamic generation**: Include/omit sections per Complexity Gate below
- **Type Core Section**: Use the matching type section only (Feature/BugFix/Refactor/Chore/Docs)
- **Placeholders**: Replace `{...}` with actual values; remove unused placeholders

---

## Type Definitions

| Type | Characteristic Section | Heuristics |
|------|----------------------|------------|
| Feature | User Scenarios | New user-facing functionality or workflow |
| BugFix | Bug Details (Reproduction, Root Cause) | Symptom + repro steps + incorrect current behavior |
| Refactor | Before/After Contract, Compatibility Policy | Internal structure improvement, compatibility considerations |
| Chore | Operational Context | Maintenance/tooling/dependency update, no behavior change |
| Docs | Documentation Target | Documentation addition/update is the primary deliverable |

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

Score +1 for each matching condition:

| Condition | Score |
|-----------|-------|
| Changed files > 3 | +1 |
| Spans multiple modules/services | +1 |
| Public API/interface changes | +1 |
| Migration/backward compatibility needed | +1 |
| Strict non-functional requirements | +1 |
| 2+ unresolved design decisions | +1 |

Score to complexity: 0-1 = XS, 2 = S, 3-4 = M, 5 = L, 6+ = XL

---

## Template Structure

> **Extracted to separate file**: The full section-by-section template (Sections 0-9) has been
> moved to [template-structure.md](./template-structure.md) to reduce context consumption.
> Read that file only when generating the Issue body (Phase 2.2 Step 2+).

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

| Interview Perspective | Target Sections |
|----------------------|----------------|
| Technical Implementation | 4.1 Target Files, 4.3 Interface/Data Contract, 4.4 Behavioral Requirements |
| User Experience | 1 Goal, 3 Type Core (Feature scenarios), 5 AC (Happy Path) |
| Edge Cases | 5 AC (Boundary/Error), 6 Test Specification (Boundary/Error rows) |
| Existing Feature Impact | 2 Scope (Out of Scope), 4.2 Non-Target, 4.4 MUST NOT |
| Non-Functional Requirements | 4.5 Error/Constraints, 5 AC (NFR outcome), 6 Test Specification |
| Tradeoffs | 1 Non-goal, 4.4 SHOULD/MAY, 9 Decision Log |

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

🤖 Generated with [rite workflow](https://github.com/{owner}/cc-rite-workflow)
