# Execution Metrics Reference

Metrics format definition for rite workflow quality measurement and continuous improvement.

## Overview

Metrics are recorded in Issue work memory comments at workflow completion. They enable trend analysis and corrective actions across Issues.

> **Note**: Section headings and definitions are in English. Output templates and user-facing messages (recording format, safety messages, AskUserQuestion options) are in Japanese per project i18n conventions.

---

## Metrics Definitions

| Metric | Description | Unit | Window | Baseline Target |
|--------|-------------|------|--------|-----------------|
| `plan_deviation_rate` | Plan vs actual step count divergence | % | Issue | ≤30% |
| `test_pass_rate` | Test pass rate at PR creation time | % | Issue | 100% |
| `review_critical_high` | CRITICAL+HIGH review findings count | count | 5-Issue MA | ≤ baseline_ma × 0.80 |
| `review_fix_loops` | review-fix loop count | count | Issue | ≤3 |
| `plan_deviation_count` | Number of plan deviations during implementation | count | 5-Issue MA | ≤ baseline_ma × 0.90 |

### Formula Definitions

| Metric | Formula |
|--------|---------|
| `plan_deviation_rate` | `abs(actual_steps - planned_steps) / planned_steps * 100` (planned_steps = 0: skip evaluation) |
| `test_pass_rate` | `passed_tests / total_tests * 100` (0 tests = 100%) |
| `review_critical_high` | `count(severity in [CRITICAL, HIGH])` from review results |
| `review_fix_loops` | `loop_count` from `.rite-flow-state` at completion |
| `plan_deviation_count` | Count of re-planning events during implementation |

### Threshold Evaluation

Per-Issue thresholds (fixed):
- `plan_deviation_rate <= 30`
- `test_pass_rate == 100`
- `review_fix_loops <= 3`

Moving average thresholds (relative to baseline):
- `review_critical_high`: `current_ma5 <= baseline_ma5 * 0.80`
- `plan_deviation_count`: `current_ma5 <= baseline_ma5 * 0.90`

**Note**: `baseline_ma5` refers to the average of the first `baseline_issues` (default: 3) completed Issues. This value is fixed once the baseline period ends and used as the reference point for all subsequent MA threshold evaluations.

---

## Baseline Collection

### Initial Period (First 3 Issues)

During the first 3 completed Issues after metrics are enabled:
- **Record** all metrics normally
- **Skip** all threshold evaluations (no warnings, no fail-closed)
- Display: `📊 Baseline 収集中 ({n}/3) — 閾値判定はスキップします`

After 3 Issues are collected:
- Calculate baseline values (average of 3 Issues)
- Begin threshold evaluation from Issue 4 onward

### Moving Average Calculation

- **Window**: 5 most recent completed Issues (skip/abort excluded)
- **ma5 not established** (fewer than 5 Issues): Use all available completed Issues for average
- **Missing values / denominator 0**: Skip threshold evaluation for that metric (conservative)

---

## Failure Classification

| Classification | Definition | Required Corrective Action |
|---------------|------------|---------------------------|
| `plan_miss` | Implementation plan assumptions were incorrect | Add pattern to [`implementation-plan.md`](../commands/issue/implementation-plan.md) plan generation |
| `impl_miss` | Code implementation error, test failure | Add test cases + record failure pattern in [`coding-principles.md`](../skills/rite-workflow/references/coding-principles.md) |
| `eval_miss` | Review false positive/negative | Update reviewer skill checklist |

### Metric-to-Failure-Class Mapping

| Metric | Failure Class on `warn` |
|--------|------------------------|
| `plan_deviation_rate` | `plan_miss` |
| `test_pass_rate` | `impl_miss` |
| `review_critical_high` | `eval_miss` |
| `review_fix_loops` | `impl_miss` |
| `plan_deviation_count` | `plan_miss` |

### Primary Failure Class Determination

When an Issue has threshold violations:
1. Classify each violation into `plan_miss`, `impl_miss`, or `eval_miss`
2. **Primary**: Most frequent classification
3. **Tie-break**: Use the last occurring classification

---

## Recording Format

### Work Memory Metrics Section

Appended to the Issue work memory comment at workflow completion (Phase 5.5.2 of [`start.md`](../commands/issue/start.md)):

```markdown
### 📊 メトリクス

| メトリクス | 値 | 閾値 | 判定 |
|-----------|-----|------|------|
| 計画乖離率 | {plan_deviation_rate}% | ≤30% | {pass/warn/skip} |
| テスト通過率 | {test_pass_rate}% | 100% | {pass/warn/skip} |
| レビュー指摘(CRITICAL+HIGH) | {review_critical_high}件 | MA5≤{threshold} | {pass/warn/skip} |
| review-fixループ | {review_fix_loops}回 | ≤3 | {pass/warn/skip} |
| 計画逸脱回数 | {plan_deviation_count}回 | MA5≤{threshold} | {pass/warn/skip} |

**Baseline**: {baseline_status}
**失敗分類**: {primary_failure_class} ({corrective_action_pointer})
```

### Judgment Values

| Value | Meaning |
|-------|---------|
| `pass` | Within threshold |
| `warn` | Exceeded threshold |
| `skip` | Baseline not established or denominator 0 |

---

## Review Metrics

Recorded in review result comment (Phase 6.1.2 of [`review.md`](../commands/pr/review.md)).

> **Note**: Debate metrics (`debate_triggered`, `debate_resolved`, `debate_escalated`, `debate_resolution_rate`) are **recording-only** — they are not included in the Metrics Definitions table above and have no threshold evaluation. They serve as observational data for reviewing the debate phase's effectiveness.

```markdown
### 📊 レビューメトリクス

| 項目 | 値 |
|------|-----|
| 指摘数(CRITICAL) | {count} |
| 指摘数(HIGH) | {count} |
| 指摘数(MEDIUM) | {count} |
| 指摘数(LOW) | {count} |
| ループカウント | {loop_count} |
| 討論: 矛盾検出 | {debate_triggered} |
| 討論: 自動解決 | {debate_resolved} |
| 討論: エスカレーション | {debate_escalated} |
| 討論: 解決率 | {debate_resolution_rate}% |
```

---

## Safety Thresholds

Defined in `rite-config.yml` under the `safety` section. See [Safety Configuration](#safety-configuration) below.

### Safety Configuration

```yaml
safety:
  # review-fix loop hard limit was removed in v0.4.0 (#557). Loop now exits on 0 findings or 4-signal escalation.
  max_implementation_rounds: 20  # implementation round hard limit
  time_budget_minutes: 120       # time budget per Issue (advisory, not enforced by timer)
  auto_stop_on_repeated_failure: true  # stop on repeated failure
  repeated_failure_threshold: 3  # consecutive same-class failure count
```

### Fail-Closed Behavior

When a safety threshold is exceeded (`max_implementation_rounds`, `repeated_failure_threshold`):

> **Note**: `time_budget_minutes` is advisory only. Claude Code has no timer mechanism, so this threshold is not automatically enforced. It serves as a reference for manual intervention decisions.

1. **Stop** the current flow immediately
2. **Report** the situation to the user:
   ```
   ⚠️ 安全装置が発動しました
   原因: {threshold_name} 超過 ({current_value} > {limit})
   ```
3. **Present options** via `AskUserQuestion`:
   - 続行（制限を引き上げ）
   - 中止（作業メモリに状態保存）
   - 手動介入（ユーザーが直接対応）

### Repeated Failure Detection

When `auto_stop_on_repeated_failure: true`:
- Track the failure classification of the last N Issues
- If the same classification appears `repeated_failure_threshold` times consecutively:
  1. Trigger fail-closed
  2. Display corrective action pointer for the repeated classification
  3. Require user acknowledgment before continuing

---

## Configuration Reference

```yaml
# rite-config.yml
metrics:
  enabled: true           # Enable/disable metrics recording
  baseline_issues: 3      # Number of Issues for baseline collection
  thresholds:
    plan_deviation_rate: 30       # Max plan deviation (%)
    test_pass_rate: 100           # Required test pass rate (%)
    review_fix_loops: 3           # Max review-fix loops
    review_critical_high_improvement: 0.80  # MA5 improvement factor
    plan_deviation_improvement: 0.90        # MA5 improvement factor

safety:
  # review-fix loop hard limit was removed in v0.4.0 (#557). Loop now exits on 0 findings or 4-signal escalation.
  max_implementation_rounds: 20  # implementation round hard limit
  time_budget_minutes: 120       # time budget per Issue (advisory, not enforced by timer)
  auto_stop_on_repeated_failure: true  # stop on repeated failure
  repeated_failure_threshold: 3  # consecutive same-class failure count
```
