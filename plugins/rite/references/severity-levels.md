# Severity Levels and Evaluation Criteria

This document defines the common severity levels and evaluation criteria used by all reviewers in the Rite Workflow.

## Severity Levels

| Level | Definition | Response Timeline |
|--------|------|---------------|
| **CRITICAL** | Immediately exploitable vulnerabilities, deployment failures, or production crashes | Must fix before merge |
| **HIGH** | Serious issues with significant impact (security risks, data exposure, perceptible degradation) | Recommended to fix before merge |
| **MEDIUM** | Potential concerns or best practice violations that should be addressed | Address early |
| **LOW** | Minor improvements or optimization opportunities | Address when time permits |

**Note**: Each reviewer may provide domain-specific examples of what constitutes each severity level in their respective documentation.

## Evaluation Criteria

Determine evaluation following this flowchart:

```
開始
  │
  ▼
CRITICAL 指摘あり？ ──Yes──> 評価: 要修正
  │No
  ▼
HIGH 指摘あり？ ──Yes──> 評価: 要修正
  │No
  ▼
MEDIUM 指摘あり？ ──Yes──> 評価: 条件付き
  │No
  ▼
LOW 指摘のみ or 指摘なし？ ──Yes──> 評価: 可
```

| Evaluation | Condition |
|------|------|
| **要修正** | 1 or more CRITICAL or HIGH findings |
| **条件付き** | 1 or more MEDIUM findings (no CRITICAL/HIGH) |
| **可** | LOW only, or no findings |
