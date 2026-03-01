# Issue Template: Section Structure Reference

This file contains the section-by-section template structure for Issue body generation.
Extracted from `default.md` for targeted reading — `create.md` reads this file
only when generating the Issue body (Phase 2.2 Step 2+), reducing context consumption.

For the Complexity Gate, Type Definitions, and overview, see [default.md](./default.md).

---

## Template Structure

### 0. Meta

```markdown
**Type**: {type}
**Complexity**: {complexity}
**Parent Issue**: #{parent_number} <!-- omit if no parent -->
```

### 1. Goal

```markdown
## 1. Goal

{what_to_achieve}

### Non-goal

- {what_is_explicitly_not_in_scope}
```

### 2. Scope

```markdown
## 2. Scope

### In Scope

- {in_scope_item}

### Out of Scope

- {out_of_scope_item}
```

### 3. Type Core Section

Select ONE matching the Issue type.

#### 3-Feature: User Scenarios

```markdown
## 3. User Scenarios

- Scenario 1: {actor} wants {action} so that {value}
- Scenario 2: {actor} wants {action} so that {value}
```

#### 3-BugFix: Bug Details

```markdown
## 3. Bug Details

### 3.1 Reproduction

- Preconditions: {env/version/flag/data}
- Steps:
  1. {step1}
  2. {step2}
  3. {step3}
- As-Is: {observed_behavior}
- To-Be: {expected_behavior}

### 3.2 Root Cause Hypothesis

- {why_it_happens}
```

#### 3-Refactor: Before / After Contract

```markdown
## 3. Before / After Contract

### 3.1 Public Interface Before

{existing_interface}

### 3.2 Public Interface After

{new_interface_or_unchanged}

### 3.3 Compatibility Policy

- {fully_compatible | additive | breaking}
- If breaking: {migration_path}
```

#### 3-Chore: Operational Context

```markdown
## 3. Operational Context

- Current pain: {problem}
- Expected improvement: {outcome}
- User-facing behavior change: none
```

#### 3-Docs: Documentation Target

```markdown
## 3. Documentation Target

- Audience: {who_reads_this}
- Docs location: {file_path}
- Source of truth: {what_docs_align_with}
- Example updates needed: {yes_no_details}
```

### 4. Implementation Details

#### 4.1 Target Files

```markdown
## 4. Implementation Details

### 4.1 Target Files

| File | Change Description |
|------|-------------------|
| {file_path} | {what_changes} |
```

#### 4.2 Non-Target Files

```markdown
### 4.2 Non-Target Files

> MUST NOT modify these files in this Issue.

- {file_path}: {reason_to_exclude}
```

#### 4.3 Interface / Data Contract

```markdown
### 4.3 Interface / Data Contract

**Before**:

{existing_interface_or_data}

**After**:

{new_interface_or_data}
```

#### 4.4 Behavioral Requirements

```markdown
### 4.4 Behavioral Requirements

**MUST**:
- {must_requirement}

**SHOULD**:
- {should_requirement}

**MAY**:
- {may_requirement}

**MUST NOT**:
- {must_not_requirement}
```

#### 4.5 Error Handling / Constraints

```markdown
### 4.5 Error Handling / Constraints

| Error Condition | Expected Behavior |
|----------------|-------------------|
| {error_condition} | {expected_behavior} |
```

### 5. Acceptance Criteria

```markdown
## 5. Acceptance Criteria

### AC-1: {title}

- **Given**: {precondition}
- **When**: {action}
- **Then**: {observable_outcome}
```

**AC count guideline**:

| Complexity | Count | Composition |
|-----------|-------|-------------|
| XS | 2-3 | Happy 1 + Error/Boundary 1-2 |
| S | 3-5 | Happy 1-2 + Error 1-2 + Boundary 1 |
| M | 5-8 | Happy 2-3 + Error 2-3 + Boundary 1-2 |
| L | 8-12 | Happy 3-4 + Error 3-4 + Boundary 2-4 |
| XL | 12+ | Split recommended |

**AC generation order**:
1. Happy path: from UX/purpose
2. Error path: from edge cases + constraints
3. Boundary: from min/max/empty/null/duplicate/timeout
4. Non-regression: when existing feature impact exists
5. Compatibility: when interface/public contract changes

**AC writing rules**:
- Given: Explicit preconditions (state/data/flag/role)
- When: One specific action
- Then: Observable outcomes only (status code, UI text, DB state, event, log)
- 1 AC = 1 verification purpose
- Forbidden vague verbs: "appropriately", "correctly", "optimally"

### 6. Test Specification

```markdown
## 6. Test Specification

| ID | Category | Description | Related AC |
|----|----------|-------------|------------|
| T-01 | Happy | {test_description} | AC-1 |
| T-02 | Error | {test_description} | AC-2 |
| T-03 | Boundary | {test_description} | AC-2 |
```

**Minimum test rows**:

| Complexity | Minimum |
|-----------|---------|
| XS | 2 |
| S | 3 |
| M | 5 |
| L | 8 |
| XL | 12 (split recommended) |

**Rules**:
- Every AC maps to at least 1 T-xx row
- BugFix/Refactor: add Non-regression rows
- Non-functional requirements present: add NFR test rows

### 7. Important Conventions

```markdown
## 7. Important Conventions (from CLAUDE.md)

- MUST: {convention} (CLAUDE.md {section_ref})
- MUST NOT: {convention} (CLAUDE.md {section_ref})
```

**Rules**:
- Maximum 5 items
- Only conventions whose violation causes implementation failure
- Each item: 1 line, MUST/MUST NOT prefix
- Always cite source (CLAUDE.md section)
- Do NOT re-state common conventions (lint, format, etc.) — reference only

### 8. Definition of Done

```markdown
## 8. Definition of Done

- [ ] All MUST requirements implemented
- [ ] All Acceptance Criteria (AC-xx) verified
- [ ] All test cases (T-xx) passing
- [ ] No regression in existing functionality
- [ ] Target files modified, non-target files untouched
- [ ] Code follows project conventions
```

### 9. Decision Log

```markdown
## 9. Decision Log

<!-- Record decisions made during implementation that affect the spec -->
- YYYY-MM-DD D-01: {decision} / Reason: {reason} / Impact: {AC_or_Test_ID}
```

---

🤖 Generated with [rite workflow](https://github.com/{owner}/cc-rite-workflow)
