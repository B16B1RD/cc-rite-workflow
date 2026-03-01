# Cross-Validation Reference

Logic to validate and integrate results from multiple reviewers.

## Same File Analysis

When multiple reviewers comment on the same file:

```
For each file with multiple reviewers:
  1. Group findings by line number
  2. Check for contradictions (one says "fix", another says "OK")
  3. Boost severity if multiple reviewers flag same issue
  4. Note in summary if consensus reached
```

## Severity Adjustment

| Condition | Action |
|-----------|--------|
| 2+ reviewers flag same issue | Severity +1 (LOW→MEDIUM→HIGH→CRITICAL, capped at CRITICAL) |
| Reviewers contradict | Mark for user decision |
| All reviewers pass | High confidence approval |

**Severity +1 examples:**
- Original LOW → promoted to MEDIUM
- Original MEDIUM → promoted to HIGH
- Original HIGH → promoted to CRITICAL
- Original CRITICAL → stays CRITICAL (cap)

## Contradiction Resolution

Display format when contradictions are detected:

```
Conflicting findings on {file}:{line}:
 - {Reviewer A}: {finding}
 - {Reviewer B}: {finding}

Please clarify which recommendation to follow.
```

**Note**: `{Reviewer A}`, `{Reviewer B}` use Japanese display names. See the [Reviewer Type Identifiers table in SKILL.md](../SKILL.md#reviewer-type-identifiers) for the mapping.

### Contradiction Examples

1. **Code Quality vs Performance**
   - Code Quality: "This function should be split"
   - Performance: "Inlining improves performance"

2. **Security vs Usability**
   - Security: "Input validation should be stricter"
   - API Design: "Allow flexible input for usability"

3. **Test Coverage vs Development Speed**
   - Test: "Edge case tests should be added"
   - DevOps: "Prioritize release schedule"

4. **Readability vs Brevity**
   - Code Quality: "Variable names should be more descriptive"
   - Performance: "Shorter variable names reduce bundle size"

## Debate Protocol (Evaluator-Optimizer Pattern)

When contradictions are detected in cross-validation, attempt automatic resolution through a structured debate before escalating to the user. This phase executes only when `review.debate.enabled: true` in `rite-config.yml`.

### Trigger Conditions

A debate is triggered when **any** of the following conditions are met:

| Condition | Description | Example |
|-----------|-------------|---------|
| Opposing assessments | Two reviewers give contradictory recommendations for the same `file:line` | One says "fix", another says "OK" |
| Severity gap ≥ 2 levels | Same `file:line` with severity difference of 2+ levels | CRITICAL vs LOW, HIGH vs LOW |

**Not triggered** when: Findings overlap but do not contradict (e.g., both say "fix" with different details — this is consensus, handled by severity boost).

### Debate Template

For each detected contradiction, generate a structured debate prompt:

```markdown
## Debate: {file}:{line}

### Contradiction Summary
- {Reviewer A} ({reviewer_type_a}): {finding_a} [Severity: {severity_a}]
- {Reviewer B} ({reviewer_type_b}): {finding_b} [Severity: {severity_b}]

### Round {n} / {max_rounds}

**{Reviewer A} ({reviewer_type_a})**, present your argument:
1. **Claim**: Restate your finding with supporting evidence
2. **Evidence**: Cite specific code patterns, best practices, or documentation
3. **Concession**: Acknowledge any valid points from the opposing reviewer
4. **Revised position**: State your final recommendation considering both perspectives

**{Reviewer B} ({reviewer_type_b})**, present your counter-argument:
1. **Claim**: Restate your finding with supporting evidence
2. **Evidence**: Cite specific code patterns, best practices, or documentation
3. **Concession**: Acknowledge any valid points from the opposing reviewer
4. **Revised position**: State your final recommendation considering both perspectives
```

**Note**: `{Reviewer A}`, `{Reviewer B}` use Japanese display names per the [Reviewer Type Identifiers table in SKILL.md](../SKILL.md#reviewer-type-identifiers).

### Resolution Criteria

After each debate round, evaluate whether agreement has been reached:

| Outcome | Condition | Action |
|---------|-----------|--------|
| **Agreement** | Both reviewers converge on the same recommendation (severity and action) | Auto-resolve: adopt the agreed finding |
| **Partial agreement** | Reviewers agree on action but differ on severity by 1 level | Auto-resolve: adopt the higher severity |
| **No agreement** | Reviewers maintain opposing positions after `max_rounds` | Escalate to user |

**Agreement detection heuristic**: Claude evaluates the "Revised position" from both reviewers:
- **Agreement**: Both recommend the same action (fix/accept/modify) with the same severity (within 0 levels)
- **Partial agreement**: Both recommend the same action but differ on severity by exactly 1 level
- Other cases are treated as **No agreement**

### Escalation Conditions

Escalation occurs in two stages: a pre-debate guard and post-debate evaluation.

**Pre-debate guard** (evaluated before entering debate):

| Condition | Action |
|-----------|--------|
| Either reviewer's finding is CRITICAL severity | Skip debate entirely, escalate to user immediately |

**Post-debate evaluation** (evaluated after `max_rounds` complete):

Escalate to user (via `AskUserQuestion`) when:

1. No agreement after `max_rounds` (configured in `review.debate.max_rounds`, default: 1)
2. The contradiction spans fundamentally different review domains where no single "correct" answer exists. Typical cross-domain pairs: security vs performance, security vs usability, test coverage vs development speed, readability vs brevity (see [Contradiction Examples](#contradiction-examples) above for reference)

**Escalation format:**

```
⚠️ レビュアー間で合意に至りませんでした

ファイル: {file}:{line}

  {Reviewer A} の最終見解:
    主張: {revised_position_a}
    根拠: {evidence_a}

  {Reviewer B} の最終見解:
    主張: {revised_position_b}
    根拠: {evidence_b}

討論の経緯:
  - {Reviewer A} は {concession_a} を認めつつも、{claim_a} を主張
  - {Reviewer B} は {concession_b} を認めつつも、{claim_b} を主張

どちらの評価を採用しますか？
オプション:
- {Reviewer A} の評価を採用
- {Reviewer B} の評価を採用
- 両方の指摘を統合（最高 severity を採用）
- この指摘を無視
```

### Debate Metrics

Record the following metrics for each debate (appended to review metrics in `review.md` Phase 6.1.2):

| Metric | Description |
|--------|-------------|
| `debate_triggered` | Number of contradictions processed (including pre-debate guard escalations) |
| `debate_resolved` | Number resolved through debate (agreement or partial agreement) |
| `debate_escalated` | Number escalated to user (no agreement after debate, or pre-debate guard CRITICAL escalation) |
| `debate_resolution_rate` | `debate_resolved / debate_triggered` (percentage) |

**Metrics output format** (included in PR comment):

```
### 討論メトリクス
- 矛盾検出: {debate_triggered} 件
- 自動解決: {debate_resolved} 件
- エスカレーション: {debate_escalated} 件
- 解決率: {debate_resolution_rate}%
```

### Configuration

```yaml
# rite-config.yml
review:
  debate:
    enabled: true       # Enable/disable debate phase (default: true)
    max_rounds: 1       # Max debate rounds per contradiction (default: 1)
```

When `review.debate.enabled: false`, skip the debate phase entirely and fall through to the existing `AskUserQuestion`-based contradiction resolution.

## Severity Levels

| Level | Description |
|-------|-------------|
| Critical | Blocker, cannot merge |
| High | Significant issue, must fix |
| Medium | Improvement recommended |
| Low | Minor suggestion |

## Related

- [Output Format](./output-format.md) - Unified report format
- [Context Management](./context-management.md) - Large PR handling
