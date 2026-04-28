# Severity Levels and Evaluation Criteria

This document defines the common severity levels and evaluation criteria used by all reviewers in the Rite Workflow.

## Severity Levels

| Level | Definition | Response Timeline |
|--------|------|---------------|
| **CRITICAL** | Immediately exploitable vulnerabilities, deployment failures, or production crashes | Must fix before merge |
| **HIGH** | Serious issues with significant impact (security risks, data exposure, perceptible degradation) | Recommended to fix before merge |
| **MEDIUM** | Potential concerns or best practice violations that should be addressed | Address early |
| **LOW-MEDIUM** | Minor concerns whose blast radius is bounded (例: 独自ジャーゴン濫用 — 個別修正で完了する localized 問題) | Address when convenient (LOW より優先) |
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

The final severity reported in the findings table is determined by combining the Impact axis (CRITICAL / HIGH / MEDIUM / LOW-MEDIUM / LOW) with the Observed Likelihood axis. The matrix below is the mechanical rule reviewers apply at finding-emission time:

| Impact \ Likelihood | Observed | Demonstrable | Hypothetical |
|---|---|---|---|
| **CRITICAL** | CRITICAL | CRITICAL | **降格 → 推奨事項** (例外カテゴリを除く) |
| **HIGH** | HIGH | HIGH | **降格 → 推奨事項** (例外カテゴリを除く) |
| **MEDIUM** | MEDIUM | MEDIUM | **降格 → 推奨事項** (例外カテゴリを除く) |
| **LOW-MEDIUM** | LOW-MEDIUM | LOW-MEDIUM | **降格 → 推奨事項** (例外カテゴリを除く) |
| **LOW** | LOW | LOW | 報告禁止 |

**Rule**: Hypothetical findings in the CRITICAL / HIGH / MEDIUM / LOW-MEDIUM rows are all downgraded to **推奨事項** (a single, mechanical destination — no reviewer-side judgment required). LOW × Hypothetical is **報告禁止** because both axes are already at the lowest tier and further downgrade would produce zero-information findings. The only exceptions are reviewers in the Hypothetical Exception Categories below.

## COMMENT_QUALITY 軸 (Impact カテゴリ)

`COMMENT_QUALITY` は Impact 軸 (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW) に対する Impact カテゴリ分類の一つで、コメント品質違反 (Comment Rot / ジャーナルコメント / 過剰冗長 / 内部 helper の些末コメント等) を Impact × Likelihood Matrix で扱うための軸である。本軸は Issue #699 の SoT ([`comment-best-practices.md`](../skills/rite-workflow/references/comment-best-practices.md)) と Issue #700 の reviewer 側 [`Comment Quality Finding Gate`](../agents/_reviewer-base.md#comment-quality-finding-gate) を統合する severity 判定の入口となる。

### Impact 等級概要

| Impact 等級 | 該当する Comment Quality 違反 (高レベル概要) |
|-----------|-----------------------------------------|
| **CRITICAL** | Comment Rot (security/correctness 主張が現コードと不一致 — 読者を能動的にミスリード) |
| **HIGH** | ジャーナルコメント (`cycle N` / `verified-review` / `PR #N` 等)、行番号・cycle 番号参照 |
| **MEDIUM** | 過剰冗長 (内部 helper のコメント密度逆転、公開 API の docstring 0 行 等) |
| **LOW-MEDIUM** | 独自ジャーゴン濫用 (Whitelist 外の造語) |
| **LOW** | 内部 helper の些末 WHAT コメント等 (詳細粒度は SoT 参照) |

> **重要度プリセット表本体は SoT に集約**: 上記は概要のみ。各違反パターンと SoT check 参照を含む完全な重要度プリセット表は [`_reviewer-base.md` の Comment Quality Finding Gate](../agents/_reviewer-base.md#comment-quality-finding-gate) を参照すること。本ファイル (`severity-levels.md`) で表本体を複製すると Issue #707 が解消しようとしている SoT 重複問題 (= 同じ重要度プリセット表が複数ファイルに重複している状態。Issue #707 で別途整理予定) を再導入してしまうため、forward-pointer のみとする。粒度の対応関係: SoT 表は検出パターン単位で記述され (各 Impact 等級に対して 1 つ以上の具体的検出パターンを列挙)、概要表は Impact 等級単位で要約する。両者の粒度差は意図的であり、reviewer は finding 発行時に SoT 表で対応する具体的検出パターンを参照する。

### Hypothetical 降格ルール (本軸での適用例)

`COMMENT_QUALITY` カテゴリは Hypothetical Exception Categories (security / database migration / devops infra / dependencies) に **含まれない**。したがって Impact × Observed Likelihood Matrix の通常ルールに従い、Hypothetical 判定の finding は **推奨事項に降格** される。

典型的な Hypothetical 降格例:

- 「将来の cycle で orphan になるかもしれない」コメント (e.g., `// 旧実装は ... — cycle 8 で削除予定`) — 削除予定コードが現時点で reachable な call site を持たず、`Grep` でも参照が確認できない場合は Hypothetical → **推奨事項** に降格
- 「もしリファクタが入ったら drift する可能性がある」cycle 番号参照 — 現時点で参照先 cycle が存在しなくても、コメント単体が誤誘導しているわけではない場合は Hypothetical → **推奨事項** に降格

### Demonstrable 昇格 signal (本軸での適用例)

逆に、以下のような observation を提示できれば Hypothetical → **Demonstrable** に昇格させ、Impact 等級そのままで finding を発行できる:

- **`git blame` 実証**: `git blame {file}` で当該コメント行が対応する code change より明確に古い (= merge 済み) ことを示し、かつコメント中の reference (`cycle N` / `PR #N` / 関数名) が現コードベースで grep ヒット 0 であることを実証 → 該当 reference の宛先が更新されていない Comment Rot として **HIGH** 以上で finding 発行可
- **新規 diff 由来**: `git diff {base_branch}...HEAD` の `+` 行に対象コメントが追加されている場合、`Likelihood-Evidence: new_call_site {file}:{line} (本 PR diff の `+` 行で追加)` を提示できるため Demonstrable 確定 (これは [`_reviewer-base.md` Comment Quality Finding Gate `Hypothetical → Demonstrable 昇格 signal`](../agents/_reviewer-base.md#hypothetical--demonstrable-昇格-signal) と同じ判定基準)

## Hypothetical Exception Categories

Four reviewer categories MAY retain **CRITICAL / HIGH / MEDIUM / LOW-MEDIUM** severity for Hypothetical findings (matching the Matrix rows that specify "降格 → 推奨事項 (例外カテゴリを除く)"), because in their domain a single occurrence of the bug is catastrophic and "wait until we observe it in production" is not an acceptable risk model:

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
MEDIUM or LOW-MEDIUM 指摘あり？ ──Yes──> 評価: 条件付き
  │No
  ▼
LOW 指摘のみ or 指摘なし？ ──Yes──> 評価: 可
```

| Evaluation | Condition |
|------|------|
| **要修正** | 1 or more CRITICAL or HIGH findings |
| **条件付き** | 1 or more MEDIUM or LOW-MEDIUM findings (no CRITICAL/HIGH) |
| **可** | LOW only, or no findings |
