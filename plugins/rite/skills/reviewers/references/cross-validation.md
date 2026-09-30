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

1. **Code Quality vs Application**
   - Code Quality: "This function should be split"
   - Application: "Inlining improves performance"

2. **Security vs Usability**
   - Security: "Input validation should be stricter"
   - Application: "Allow flexible input for usability"

3. **Test Coverage vs Development Speed**
   - Test: "Edge case tests should be added"
   - DevOps: "Prioritize release schedule"

4. **Readability vs Brevity**
   - Code Quality: "Variable names should be more descriptive"
   - Application: "Shorter variable names reduce bundle size"

## Debate Protocol

When contradictions are detected in cross-validation, attempt automatic resolution through deliberation before escalating to the user. This phase executes only when `review.debate.enabled: true` in `rite-config.yml`.

### Trigger Conditions

矛盾とは、**同じ `file:line` に対する両 reviewer の評価を同時には採用できない**状態を指す。典型例:

- 相反する推奨（一方は "fix"、他方は "OK"）
- 扱いが変わるほど大きく乖離した severity 判断（CRITICAL vs LOW のような 2 段階以上の乖離が典型だが、段数そのものではなく「どちらの扱いに従うかが決められない」ことが基準）

**Not triggered** when: Findings overlap but do not contradict (e.g., both say "fix" with different details — this is consensus, handled by severity boost).

### Deliberation Principle

各矛盾について、両 reviewer の主張と証拠を実コードと突き合わせて検討する。それぞれの立場から、相手の論点の妥当な部分を認めた上で最終見解を出す（一方の肩を最初から持たない）。

**決着判断**:

- 検討の結果、両論が**同じ対応**（fix / accept / modify）を支持できるなら合意として採用する
- 対応は一致するが severity の見解が割れる場合は、乖離幅に関わらず**高い方の severity を採用**する（見逃しより過剰警告を許容）
- `max_rounds` 回検討しても**対応そのものが相反したまま**なら決着不能 — ユーザーへエスカレーションする（下記 Escalation Conditions）

**Note**: `{Reviewer A}`, `{Reviewer B}` use Japanese display names per the [Reviewer Type Identifiers table in SKILL.md](../SKILL.md#reviewer-type-identifiers).

### Escalation Conditions

Escalation occurs in two stages: a pre-debate guard and post-debate evaluation.

**Pre-debate guard** (evaluated before entering deliberation):

| Condition | Action |
|-----------|--------|
| Either reviewer's finding is CRITICAL severity | Skip deliberation entirely, escalate to user immediately |

**Before any escalation** (both stages): check both positions against the code at `file:line` and run the reproduction command or test each side cites. A contradiction the run settles is resolved by that result and recorded as agreed; it is not escalated. Escalate only what the run cannot settle — which behaviour the specification should have — and write the request with the four elements of [question_resolution](../../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) rule 6. Never ask a person to judge whether the code is correct.

**Post-deliberation evaluation**:

Escalate to user (via `AskUserQuestion`) when:

1. No agreement after `max_rounds` (configured in `review.debate.max_rounds`, default: 1)
2. The contradiction spans fundamentally different review domains where no single "correct" answer exists. Typical cross-domain pairs: security vs performance, security vs usability, test coverage vs development speed, readability vs brevity (see [Contradiction Examples](#contradiction-examples) above for reference)

**Escalation format:**

```
⚠️ 実行しても決まらない判断があります

ファイル: {file}:{line}

何を決めるか: {挙動の割れなら「この箇所の挙動として、どちらを仕様とするか」、scope の割れなら「この PR で直すか、別 Issue に回すか」}
  案 A（{Reviewer A}）: {revised_position_a}
    根拠: {evidence_a}
  案 B（{Reviewer B}）: {revised_position_b}
    根拠: {evidence_b}

なぜ AI では決められないか: {両案の再現コマンド・テストを実行した結果と、仕様に記載が無い点}
どう判断するか: {案 A を採ったときの帰結} / {案 B を採ったときの帰結}
期待する回答: 採る案

討論の経緯:
  - {Reviewer A} は {concession_a} を認めつつも、{claim_a} を主張
  - {Reviewer B} は {concession_b} を認めつつも、{claim_b} を主張

オプション:
- 案 A を採る
- 案 B を採る
- 両方を満たす形にする（最高 severity を採用）
- どちらも採らない（指摘を取り下げる）
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
