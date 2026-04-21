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

## Observed Likelihood Axis

Severity alone (impact axis) is insufficient. Every finding must also be classified along the **Observed Likelihood** axis — the degree to which the triggering condition can be demonstrated to exist in the codebase under review.

| Likelihood | Definition |
|-----------|-----------|
| **Observed** | The bug has been reproduced (test failure, crash log, runtime trace, or grepped error in CI) on the diff under review. |
| **Demonstrable** | The bug has not been reproduced, but the triggering call site or entrypoint connection exists in the **diff-applied codebase as a whole** (existing code + new code introduced by this PR). The reviewer can cite the call site by `file:line`. |
| **Hypothetical** | The triggering condition is plausible in principle but the reviewer cannot cite a concrete call site or entrypoint that reaches the buggy code in the diff-applied codebase. |

### Demonstrable: scope of proof

The proof scope is the **diff-applied codebase as a whole**, not "existing code only". This intentionally closes the new-feature-PR loophole: a PR that introduces a brand-new module would otherwise have no pre-existing call sites and would be auto-downgraded to Hypothetical even when the new module's own entrypoint is wired up.

Acceptable evidence for Demonstrable status (any one of the following is sufficient):

1. **Existing call site**: `Grep` finds a pre-existing caller of the function/path in question.
2. **New call site**: The PR diff itself adds a caller of the function/path.
3. **Entrypoint connection**: The buggy code is reachable from a CLI command, HTTP route, webhook, cron, framework convention (controller / handler / hook), test runner, or other registered entrypoint — even if `Grep` for the function name returns no results because dispatch is dynamic (reflection, decorator, plugin registry, hook system, configuration-driven routing).
4. **Runtime observation**: The reviewer has actually run the diff-applied code and observed the failure.

The reviewer must record which evidence type was used in the finding's `内容` column using the standardized machine-readable prefix `Likelihood-Evidence: <label> <location>` defined in [`agents/_reviewer-base.md` "Demonstrable: proof of burden"](../agents/_reviewer-base.md#demonstrable-proof-of-burden). Examples: `Likelihood-Evidence: existing_call_site src/api.ts:45`, `Likelihood-Evidence: new_call_site src/new-module.ts:12`, `Likelihood-Evidence: entrypoint_connection commands/foo.md → hooks/foo.sh L23`. See `_reviewer-base.md` for the full label list and the machine-detection contract.

### Grep failure ≠ Hypothetical

If a static text search (`Grep`) returns no results, that alone does NOT downgrade a finding to Hypothetical. Dynamic dispatch, reflection, hook scripts, framework conventions (e.g., Rails controllers, Next.js route files, Django URL routers, Claude Code skill auto-discovery), and configuration-file-driven routing all produce real call sites that `Grep` cannot see. The reviewer must:

1. Search for entrypoint registration files (`commands/`, `hooks/`, `skills/`, `routes/`, `urls.py`, etc.) that mention the buggy file or function.
2. If an entrypoint mentions the file, the reviewer has met the Demonstrable bar — even with zero `Grep` hits for the function name.
3. Only when neither direct call sites nor entrypoint connections can be demonstrated does the finding fall to Hypothetical.

## Impact × Observed Likelihood Matrix

The final severity reported in the findings table is determined by combining the Impact axis (CRITICAL / HIGH / MEDIUM / LOW) with the Observed Likelihood axis. The matrix below is the mechanical rule reviewers apply at finding-emission time:

| Impact \ Likelihood | Observed | Demonstrable | Hypothetical |
|---|---|---|---|
| **CRITICAL** | CRITICAL | CRITICAL | **降格 → 推奨事項** (例外カテゴリを除く) |
| **HIGH** | HIGH | HIGH | **降格 → 推奨事項** (例外カテゴリを除く) |
| **MEDIUM** | MEDIUM | MEDIUM | **降格 → 推奨事項** (例外カテゴリを除く) |
| **LOW** | LOW | LOW | 報告禁止 |

**Rule**: Hypothetical findings in the CRITICAL / HIGH / MEDIUM rows are all downgraded to **推奨事項** (a single, mechanical destination — no reviewer-side judgment required). LOW × Hypothetical is **報告禁止** because both axes are already at the lowest tier and further downgrade would produce zero-information findings. The only exceptions are reviewers in the Hypothetical Exception Categories below.

## Hypothetical Exception Categories

Four reviewer categories MAY retain **CRITICAL / HIGH / MEDIUM** severity for Hypothetical findings (matching the Matrix rows that specify "降格 → 推奨事項 (例外カテゴリを除く)"), because in their domain a single occurrence of the bug is catastrophic and "wait until we observe it in production" is not an acceptable risk model:

| Category | Reviewer | Rationale |
|---|---|---|
| **Security** | `security.md` | Adversarial input is the reviewer's job. A SQL injection vector that has no observed exploit today is still a CRITICAL risk because the attacker chooses when to demonstrate it. |
| **Database migration** | `database.md` | A migration runs once in production. A destructive or irreversible migration cannot be retried. The blast radius is the entire production dataset. |
| **Infrastructure** | `devops.md` | Deployment, rollback, and infra-as-code paths are exercised rarely but failure leaves production in a broken state with no rollback. |
| **Dependencies** | `dependencies.md` | Known CVEs, supply-chain compromise, and license violations are inherently "could happen any time" risks. Waiting for observed exploitation is wrong. |

Reviewers in these categories MUST still record the Likelihood classification in the finding's `内容` column (e.g., "Likelihood: Hypothetical (例外カテゴリ: security)") so the reader knows the severity was not auto-downgraded.

All other reviewers MUST apply the matrix above and downgrade Hypothetical findings.

> **Note — 3 ゲート運用への forward-pointer**: 指摘事項化の必要条件は impact + likelihood の 2 軸に加えて **revert test を含む 3 ゲート** を同時充足することが求められます。revert test の運用手順は [`agents/_reviewer-base.md` "Necessary conditions for inclusion in 指摘事項"](../agents/_reviewer-base.md#necessary-conditions-for-inclusion-in-指摘事項) を参照してください。本ファイル (severity-levels.md) は impact + likelihood の 2 軸定義に特化しており、revert test の定義は意図的に `_reviewer-base.md` に集約されています。

## Evaluation Criteria

Determine evaluation following this flowchart (after applying the Impact × Likelihood matrix):

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
