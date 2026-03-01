# Output Pattern Recognition Reference

A guide for robust machine-readable pattern recognition in rite workflow Skills.

> **Note**: This document defines fallback patterns and error recovery strategies for output pattern matching. All Skills that emit machine-readable patterns should follow these conventions.

---

## Table of Contents

1. [Pattern Conventions](#pattern-conventions)
2. [Pattern Catalog](#pattern-catalog)
3. [Recognition Strategies](#recognition-strategies)
4. [Error Recovery](#error-recovery)
5. [Implementation Guidelines](#implementation-guidelines)
6. [Related Documents](#related-documents)

---

## Pattern Conventions

### Standard Format

```
[skill-name:status] or [skill-name:status:{value}]
```

**Components:**
- `skill-name`: The Skill emitting the pattern (`lint`, `review`, `fix`, `pr`)
- `status`: The outcome status (lowercase, hyphen-separated)
- `{value}` (optional): Numeric value or identifier

### Case and Spacing Rules

- **Canonical form**: Lowercase with no extra spaces
- **Whitespace tolerance**: Allow single spaces around `:` and inside brackets
- **Case insensitivity**: Match both `[Review:Mergeable]` and `[review:mergeable]`

---

## Pattern Catalog

### /rite:lint Patterns

| Pattern | Meaning | Value Type |
|---------|---------|------------|
| `[lint:success]` | All checks passed | - |
| `[lint:skipped]` | User chose to skip lint | - |
| `[lint:error]` | Checks failed, fix required | - |
| `[lint:aborted]` | User aborted, proceed to completion | - |

### /rite:pr:create Patterns

| Pattern | Meaning | Value Type |
|---------|---------|------------|
| `[pr:created:{n}]` | PR created successfully | PR number (integer) |
| `[pr:create-failed]` | PR creation failed | - |

### /rite:pr:review Patterns

| Pattern | Meaning | Value Type |
|---------|---------|------------|
| `[review:mergeable]` | No blocking findings, ready to merge | - |
| `[review:fix-needed:{n}]` | Blocking findings exist, fix required | Finding count (integer) |
| `[review:conditional-merge:{n}]` | Non-blocking findings, can merge after conversion | Finding count (integer) |
| `[review:loop-limit:{n}]` | Loop limit reached, convert remaining to Issues | Finding count (integer) |

### /rite:pr:fix Patterns

| Pattern | Meaning | Value Type |
|---------|---------|------------|
| `[fix:pushed]` | Fixes pushed to PR | - |
| `[fix:issues-created:{n}]` | Findings converted to Issues | Issue count (integer) |
| `[fix:replied-only]` | Only replied to findings (no code changes) | - |
| `[fix:error]` | Fix operation failed | - |

---

## Recognition Strategies

### Primary Pattern Matching

Use exact match (case-insensitive, whitespace-normalized):

```regex
# Pseudocode regex patterns
[lint:success]     → /\[\s*lint\s*:\s*success\s*\]/i
[pr:created:123]   → /\[\s*pr\s*:\s*created\s*:\s*(\d+)\s*\]/i
[review:mergeable] → /\[\s*review\s*:\s*mergeable\s*\]/i
```

### Fallback Pattern Recognition

When primary pattern fails, use semantic keyword search as fallback:

| Pattern Family | Fallback Keywords | Context |
|---------------|------------------|---------|
| `lint:success` | "チェック完了", "check complete", "no errors found" | Near end of lint output |
| `lint:skipped` | "スキップ", "skip", "user chose to skip" | Near end of lint output |
| `review:mergeable` | "マージ可", "ready to merge", "no blocking" | In review result section |
| `fix:pushed` | "push完了", "pushed to", "changes committed" | After fix execution |

### Confidence Levels

| Match Type | Confidence | Action |
|-----------|-----------|--------|
| Exact pattern match (primary) | High | Proceed with confidence |
| Fallback keyword match | Medium | Log fallback usage, proceed |
| No match | Low | Trigger error recovery |

---

## Error Recovery

### Pattern Recognition Failure

When no pattern is recognized:

1. **Log the failure**:
   ```
   WARNING: Failed to detect output pattern from [skill-name]
   Expected one of: [list-of-expected-patterns]
   Output received: [truncated-output]
   ```

2. **Request clarification**:
   ```
   [skill-name] が完了しましたが、出力パターンが認識できませんでした。

   以下のいずれかを選択してください:
   - 成功した（次のフェーズへ進む）
   - 失敗した（エラー処理が必要）
   - 中断した（別の対応が必要）
   ```

3. **Use AskUserQuestion** to get explicit confirmation before proceeding

### Malformed Pattern Detection

When pattern is detected but malformed (e.g., missing required value):

```
ERROR: Malformed pattern detected: [review:fix-needed:]
Expected format: [review:fix-needed:{count}]

Falling back to manual count...
```

Attempt to extract value from surrounding context (e.g., "3 blocking findings" → `{count} = 3`).

### Pattern Mismatch Recovery

When detected pattern doesn't match expected workflow state:

```
ERROR: Unexpected pattern [fix:pushed] in current state
Expected patterns: [pr:created:{n}], [pr:create-failed]

This may indicate:
- Workflow step was skipped
- Manual intervention occurred
- Unexpected error in previous step

Requesting user guidance...
```

Use AskUserQuestion to determine correct next step.

---

## Implementation Guidelines

### Pattern Emission (for Skill authors)

1. **Always emit patterns exactly as specified** (no variations)
2. **Emit pattern at the end** of Skill output (after all explanatory text)
3. **One pattern per execution** (do not emit multiple conflicting patterns)
4. **Include required values** in patterns that need them (e.g., `{n}`)

**Example output structure:**

```markdown
[Explanatory text about what the Skill did...]

[Detailed results, tables, code blocks...]

[Final summary...]

[review:mergeable]
```

### Pattern Recognition (for orchestrating commands)

1. **Primary: Exact match** (case-insensitive, whitespace-tolerant regex)
2. **Fallback: Keyword search** (check predefined fallback keywords)
3. **Error recovery: User confirmation** (when both fail)

**Example implementation (pseudocode):**

```python
def detect_pattern(skill_output, expected_patterns):
    # Try exact match
    for pattern in expected_patterns:
        match = regex_match(pattern, skill_output, case_insensitive=True)
        if match:
            return (match, confidence='high')

    # Try fallback keywords
    for pattern_family, keywords in fallback_keywords.items():
        if any(keyword in skill_output for keyword in keywords):
            return (pattern_family, confidence='medium')

    # No match - trigger error recovery
    return (None, confidence='low')
```

### Testing Pattern Recognition

**Test cases to cover:**

1. **Exact canonical pattern**: `[review:mergeable]`
2. **Extra whitespace**: `[ review : mergeable ]`
3. **Case variation**: `[Review:Mergeable]`
4. **With value**: `[fix:issues-created:3]`
5. **Malformed**: `[fix:issues-created:]` (missing value)
6. **Missing**: Output with no pattern at all
7. **Fallback keywords**: Output with keyword but no pattern

---

## Related Documents

- [rite-workflow SKILL.md](../skills/rite-workflow/SKILL.md) - Workflow skill definition
- [AI Coding Principles](../skills/rite-workflow/references/coding-principles.md) - Coding best practices
