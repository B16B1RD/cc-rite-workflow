# Assessment Rules (Phase 5.3)

> **Source**: Extracted from `review.md` Phase 5.3.1-5.3.7. This file is the source of truth for assessment rules.

## 5.3.0 Observed Likelihood Gate (Post-Reviewer Safety Net)

Before 5.3.1 Red blocking rule, apply the following **mechanical** demotion as a **safety net** for findings that escaped the reviewer-side Observed Likelihood Gate defined in [`_reviewer-base.md`](../../../agents/_reviewer-base.md#observed-likelihood-gate). This is a deterministic rule — AI judgment is NOT involved and is explicitly prohibited (see 5.3.7).

**Position in the gate chain**:

1. **Reviewer-side Gate** (primary): Each reviewer applies the [Impact × Observed Likelihood Matrix](../../../references/severity-levels.md#impact--observed-likelihood-matrix) at finding-emission time. Hypothetical findings are moved to the **推奨事項** section (not the 指摘事項 table) with a single, mechanical destination, and the reviewer records a `Likelihood-Evidence:` marker for every Demonstrable/Observed finding.
2. **Phase 5.3.0 safety net** (secondary): If a finding slipped into `全指摘事項` without a `Likelihood-Evidence:` marker (reviewer-side Gate was skipped or the reviewer forgot the marker), this Phase demotes the finding to **推奨事項** to match the matrix destination.

**Mechanical detection + demotion**:

```
For each finding in 全指摘事項:
  if reviewer_type in Hypothetical Exception Categories
     (= {security, database, devops, dependencies}; see severity-levels.md#hypothetical-exception-categories):
    skip (severity 維持、例外カテゴリ)
  else:
    if finding's 内容 column lacks a `Likelihood-Evidence:` prefix line
       (machine-detectable anchor defined in _reviewer-base.md):
      if severity == LOW:
        remove from 全指摘事項
        (matrix rule: LOW × Hypothetical は報告禁止)
      else:
        move to 推奨事項 section
        (matrix rule: CRITICAL/HIGH/MEDIUM × Hypothetical → 推奨事項へ 1 ステップ降格)
```

**"Missing `Likelihood-Evidence:` anchor"** means the finding's `内容` column does NOT contain a match for the following regex (per `_reviewer-base.md` "Demonstrable: proof of burden"):

```
(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Likelihood-Evidence:[[:space:]]*(existing_call_site|new_call_site|entrypoint_connection|runtime_observation)
```

**Anchor boundary semantics** (drift prevention vs `_reviewer-base.md` L127 placement rules):

- `(?m)` — multiline mode is **required**. Without it, `^` matches only at string start and the regex misses anchors placed after the WHAT/WHY narrative (which is the common case in `内容` columns).
- `(?:^|<br\s*/?>|[\s|>(])` — accepts four boundary variants: (a) physical line start `^`, (b) HTML `<br>` / `<br/>` / `<br />` separator (per `_reviewer-base.md` L127 "For Markdown table cells where physical newlines are not supported, use `<br>` as the separator"), (c) whitespace/tab (same-line continuation after WHAT+WHY narrative per `_reviewer-base.md` L127), (d) Markdown table cell boundary `|` / `>` / `(` (defense-in-depth).

This boundary set matches the canonical pattern used in `review.md` Phase 5.1.1.1 (`(?m)^### 修正検証結果\s*$`) and Phase 5.1.3 Step 2 (`(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:`). Updates to `_reviewer-base.md` L127 placement rules MUST be synchronized with this regex — the two are the single source of truth for anchor placement (authoring) and anchor detection (safety net).

Absence of any of these matches is the reviewer-side contract violation that Phase 5.3.0 corrects as safety net.

**Excluded reviewer types** (demotion skipped, severity preserved):

| Reviewer | Rationale |
|----------|-----------|
| `security` | Attack surface must be evaluated pre-exploitation; waiting for observed exploit is wrong |
| `database` | Destructive DDL/DML cannot be "wait and see" |
| `devops` | Infra rollback/deploy paths failure leaves production broken |
| `dependencies` | Known CVEs and supply-chain risks are inherently "could happen any time" |

These 4 categories match [Hypothetical Exception Categories](../../../references/severity-levels.md#hypothetical-exception-categories) exactly. Updates to the exception list MUST be synchronized across `severity-levels.md`, `_reviewer-base.md`, and this section.

**Relation to 5.3.7 (AI independent judgment prohibition)**: The mechanical demotion in 5.3.0 is **explicitly permitted** because it follows a deterministic algorithm (regex match on `Likelihood-Evidence:` anchor + destination fixed by matrix) with no AI discretion. In contrast, 5.3.7 prohibits AI from applying severity exceptions based on its own judgment (e.g., "this CRITICAL is actually minor"). Mechanical rule = allowed; AI judgment = forbidden.

**Recording demoted findings**: Record each demoted finding in an `### Observed Likelihood 降格結果` section of the integrated report (Phase 5.4) so the demotion is auditable. The full table schema is defined by the Phase 5.4 template in `review.md`; this section only specifies the columns:

```markdown
### Observed Likelihood 降格結果

| 元重要度 | 降格後 | ファイル:行 | 内容 | 降格理由 |
|---------|-------|------------|------|---------|
| HIGH | 推奨事項 | {file:line} | {description} | Likelihood-Evidence marker 未提示 (reviewer-side Gate skip) |
| LOW | （削除） | {file:line} | {description} | LOW × Hypothetical は報告禁止 |
```

**Expected firing frequency**: When reviewers correctly apply the reviewer-side Gate, Phase 5.3.0 SHOULD fire zero times (all findings carry `Likelihood-Evidence:` markers). Non-zero firings indicate reviewer-side contract violations that warrant investigation via Wiki Ingest or reviewer training.

## 5.3.1 Assessment Rules

**Red blocking rule: If even 1 finding exists (after 5.3.0 demotion), it MUST NOT be assessed as "Merge OK"**

All findings (CRITICAL/HIGH/MEDIUM/LOW) remaining in `全指摘事項` after 5.3.0 demotion are always blocking regardless of loop count. There is no gradual relaxation — every remaining finding must be resolved before merge.

**Fact-Check exclusion**: When `review.fact_check.enabled: true`, CONTRADICTED (❌) findings and UNVERIFIED:ソース未確認 (⚠️) findings are removed from `全指摘事項` by the Fact-Checking Phase before assessment. Only findings remaining in `全指摘事項` after fact-checking are counted in `total_findings`. UNVERIFIED:リソース超過 findings remain in `全指摘事項` with `[未検証:リソース超過]` annotation and are counted (blocking maintained).

**Pre-existing issue handling**: Pre-existing issues (problems that existed before the current PR's changes, confirmed via revert test) are excluded from findings entirely by the reviewer's scope judgment rule. They are NOT collected as a separate report section and NOT auto-Issue-ified. If a reviewer wants to surface a pre-existing concern, it goes into the "調査推奨" section of the integrated report (Phase 5) — the user may optionally run `/rite:investigate {file}` separately (non-blocking, not counted in `total_findings`).

When executed standalone (outside a loop), the same rule applies: all findings are blocking.

## 5.3.3 Assessment Logic

Use **all findings** for determination (all findings are blocking). Priority: CRITICAL findings → Requires fixes | HIGH/MEDIUM/LOW findings → Cannot merge (findings exist) | 0 findings → Merge OK.

## 5.3.5 Output Format at Assessment Decision Time

When determining the assessment, explicitly output the finding count in the following format:

```
【指摘件数サマリー】
- CRITICAL: {count} 件
- HIGH: {count} 件
- MEDIUM: {count} 件
- LOW: {count} 件
- 合計: {total} 件（すべて blocking）

【評価判定】
- 指摘件数: {total} 件
- 優先度 {n} に該当: {条件の説明}
- 総合評価: {マージ可 / マージ不可（指摘あり） / 修正必要}
```

**Additional output when fact-check was executed:**

When `review.fact_check.enabled: true` and external claims > 0, output the following in addition to the above:

```
【外部仕様検証】
- 外部仕様の主張: {total_external} 件
- 検証済み (✅): {verified} 件
- 矛盾 (❌): {contradicted} 件（指摘から除外済み）
- 未検証:ソース未確認 (⚠️): {unverified_source} 件（指摘から除外済み）
- 未検証:リソース超過: {unverified_limit} 件（blocking 維持）
```

**Additional output for verification mode:**

When `review_mode == "verification"`, output the following in addition to the above:

```
【検証モード情報】
- レビューモード: 検証 (verification)
- 前回レビュー commit: {last_reviewed_commit}
- 修正検証: FIXED {fixed} / NOT_FIXED {not_fixed} / PARTIAL {partial}
- リグレッション: {regression_count} 件
```

**Important**: Any findings → cannot merge → `/rite:issue:start` loop continues. "Merge OK" = 0 findings.

## 5.3.6 Return Values to Caller (Important)

Return: total_findings (if >0, `/rite:pr:fix` required), evaluation, review_mode.

**Red important constraint:**

The caller (`/rite:issue:start` Phase 5.5) **mechanically** invokes `/rite:pr:fix` when `total_findings > 0` or `evaluation != "マージ可"`, **regardless of AI judgment**.

The following decisions MUST NOT be made by `/rite:pr:review`:
- "The findings are minor, so no action is needed"
- Independently modifying assessment rules

`/rite:pr:review` is responsible only for accurately reporting the assessment results.

## 5.3.7 Prohibition of Independent Judgment After Assessment

> **It is prohibited for the AI to override the assessment logic (5.3.3) results.**

Prohibited actions: Exception handling by severity (e.g., "Only LOWs, so minor"), overriding assessment (e.g., "Effectively merge-OK"), inserting user confirmation.

> **[READ-ONLY RULE]**: 評価結果に基づいてコードを直接修正することは禁止されています。`Edit`/`Write` ツールでプロジェクトのソースファイルを変更してはなりません。ブロック指摘が存在する場合は `[review:fix-needed:{n}]` パターンを出力し、修正は `/rite:pr:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、`.rite-flow-state` 更新）と **read-only な git コマンド**（完全な許可・禁止一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照）のみ許可されます。working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）は **禁止** です。

**Principle:** Assessment logic result = final decision. AI's role = reporting + mechanical transition to the next phase only.
