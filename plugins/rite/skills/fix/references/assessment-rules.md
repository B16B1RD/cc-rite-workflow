# Assessment Rules (Phase 5.3)

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述は書かない。

> **Source**: Extracted from `pr-review.md` ステップ 5.3.1-5.3.7. This file is the source of truth for assessment rules.

## 5.3.0 Observed Likelihood Gate (Post-Reviewer Safety Net)

Before 5.3.1 Red blocking rule, apply the following **mechanical** demotion as a **safety net** for findings that escaped the reviewer-side Observed Likelihood Gate defined in [`_reviewer-base.md`](../../../agents/_reviewer-base.md#observed-likelihood-gate). This is a deterministic rule — AI judgment is NOT involved and is explicitly prohibited (see 5.3.7).

**Position in the gate chain**:

1. **Reviewer-side Gate** (primary): Each reviewer applies the [Impact × Observed Likelihood Matrix](../../../references/severity-levels.md#impact--observed-likelihood-matrix) at finding-emission time. Hypothetical findings are moved to the **推奨事項** section (not the 指摘事項 table) with a single, mechanical destination, and the reviewer records a `Likelihood-Evidence:` marker for every Demonstrable/Observed finding.
2. **Phase 5.3.0 safety net** (secondary): If a finding slipped into `全指摘事項` without a `Likelihood-Evidence:` marker (reviewer-side Gate was skipped or the reviewer forgot the marker), this Phase demotes the finding to **推奨事項** to match the matrix destination.

**Mechanical detection + demotion**:

```
For each finding in 全指摘事項:
  if reviewer_type in Hypothetical Exception Categories
     (= {security, devops, dependencies}; see severity-levels.md#hypothetical-exception-categories)
     or (reviewer_type == application
         and finding's 内容 column contains `Likelihood: Hypothetical (例外カテゴリ: database migration)`
         — application は Database migration 例外を migration 関連 finding に限り継承する):
    skip (severity 維持、例外カテゴリ)
  else:
    if finding's 内容 column lacks a `Likelihood-Evidence:` prefix line
       (machine-detectable anchor defined in _reviewer-base.md):
      if severity == LOW:
        remove from 全指摘事項
        (matrix rule: LOW × Hypothetical は報告禁止)
      else:
        move to 推奨事項 section
        (matrix rule: CRITICAL/HIGH/MEDIUM/LOW-MEDIUM × Hypothetical → 推奨事項へ 1 ステップ降格)
```

**"Missing `Likelihood-Evidence:` anchor"** means the finding's `内容` column does NOT contain a match for the following regex (per `_reviewer-base.md` "Demonstrable: proof of burden"):

```
(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Likelihood-Evidence:[[:space:]]*(existing_call_site|new_call_site|entrypoint_connection|runtime_observation)
```

**Anchor boundary semantics** (drift prevention vs `_reviewer-base.md` L127 placement rules):

- `(?m)` — multiline mode is **required**. Without it, `^` matches only at string start and the regex misses anchors placed after the WHAT/WHY narrative (which is the common case in `内容` columns).
- `(?:^|<br\s*/?>|[\s|>(])` — accepts four boundary variants: (a) physical line start `^`, (b) HTML `<br>` / `<br/>` / `<br />` separator (per `_reviewer-base.md` L127 "For Markdown table cells where physical newlines are not supported, use `<br>` as the separator"), (c) whitespace/tab (same-line continuation after WHAT+WHY narrative per `_reviewer-base.md` L127), (d) Markdown table cell boundary `|` / `>` / `(` (defense-in-depth).

This boundary set matches the canonical pattern used in `pr-review.md` ステップ 5.1.1.1 (`(?m)^### 修正検証結果\s*$`) and ステップ 5.1.3 Step 2 (`(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:`). Updates to `_reviewer-base.md` L127 placement rules MUST be synchronized with this regex — the two are the single source of truth for anchor placement (authoring) and anchor detection (safety net).

Absence of any of these matches is the reviewer-side contract violation that Phase 5.3.0 corrects as safety net.

**Excluded reviewer types** (demotion skipped, severity preserved):

| Reviewer | Rationale |
|----------|-----------|
| `security` | Attack surface must be evaluated pre-exploitation; waiting for observed exploit is wrong |
| `application` (migration 関連 finding に限る — `Likelihood: Hypothetical (例外カテゴリ: database migration)` 表記を伴うもの) | Destructive DDL/DML cannot be "wait and see"。旧 `database` reviewer の Database migration 例外を統合先の `application` が migration finding に限り継承する |
| `devops` | Infra rollback/deploy paths failure leaves production broken |
| `dependencies` | Known CVEs and supply-chain risks are inherently "could happen any time" |

These categories inherit [Hypothetical Exception Categories](../../../references/severity-levels.md#hypothetical-exception-categories) (severity-levels.md の表は Database migration 例外の参照先を `application-reviewer.md` に更新済み)。Updates to the exception list MUST be synchronized across this section and `pr-review.md` ステップ 5.1 (Demoted findings collection)。

**Relation to 5.3.7 (AI independent judgment prohibition)**: The mechanical demotion in 5.3.0 is **explicitly permitted** because it follows a deterministic algorithm (regex match on `Likelihood-Evidence:` anchor + destination fixed by matrix) with no AI discretion. In contrast, 5.3.7 prohibits AI from applying severity exceptions based on its own judgment (e.g., "this CRITICAL is actually minor"). Mechanical rule = allowed; AI judgment = forbidden.

**Recording demoted findings**: Record each demoted finding in an `### Observed Likelihood 降格結果` section of the integrated report (ステップ 5.4) so the demotion is auditable. The full table schema is defined by the ステップ 5.4 template in `pr-review.md`; this section only specifies the columns:

```markdown
### Observed Likelihood 降格結果

| 元重要度 | 降格後 | ファイル:行 | 内容 | 降格理由 |
|---------|-------|------------|------|---------|
| HIGH | 推奨事項 | {file:line} | {description} | Likelihood-Evidence marker 未提示 (reviewer-side Gate skip) |
| LOW | （削除） | {file:line} | {description} | LOW × Hypothetical は報告禁止 |
```

**Expected firing frequency**: When reviewers correctly apply the reviewer-side Gate, Phase 5.3.0 SHOULD fire zero times (all findings carry `Likelihood-Evidence:` markers). Non-zero firings indicate reviewer-side contract violations that warrant investigation via Wiki Ingest or reviewer training.

## 5.3.0.M 実測必須ゲート (Measured CONFIRMED Gate)

5.3.0 の後・5.3.1 の前に適用する **mechanical** な分類ゲート (Issue #2024)。ゲート定義の SoT は [severity-levels.md §実測必須ゲート](../../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate)。5.3.0 と同じく deterministic rule であり、AI judgment は関与しない (5.3.7 の禁止対象外 — mechanical rule = allowed)。

**Mechanical detection + demotion**:

```
For each finding in 全指摘事項 (post-5.3.0):
  if finding's 内容 column contains a `Verification:` anchor
     (repro / failing_test、_reviewer-base.md §Verification: runtime 実測の添付 で定義)
     and the anchor's `=>` 右辺 (観測結果 / 失敗出力) is non-empty:
    keep (measured=true、blocking 候補として 5.3.1 以降へ)
  else:
    move to non_blocking_findings
    (severity / scope は維持したまま blocking 集合から除外。破棄しない。
     アンカーはあるが実測内容が空の場合は schema 違反として WARNING を stderr に出し同様に降格 — invariant #6)
```

**Anchor detection regex** (5.3.0 の `Likelihood-Evidence:` regex と同じ boundary semantics):

```
(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(repro|failing_test)[[:space:]]+\S.*=>[[:space:]]*\S
```

**non_blocking_findings の扱い**:

- `total_findings` にカウントしない (mergeable countdown から除外)
- 5.4 integrated report の `### 実測なし指摘 (non-blocking)` section に記録する (severity 明示)
- pr-review.md ステップ 6.1.d で PR コメントに記録する (gh 失敗は WARNING のみ — 記録失敗でループを止めない)
- 6.1.a JSON には `verification: {measured: false, ...}` として含める (`/rite:fix` 読取側が修正対象から除外できるようにする)
- fix サイクルは起動しない (fix.md 側の除外分岐は [fix-relaxation-rules.md](./fix-relaxation-rules.md) §Fix Target Classification 参照)

**scope=nit-noted との関係**: nit-noted は従来どおり §5.3.1 の nit-noted exclusion で扱い、本ゲートの対象にしない (二重計上防止)。本ゲートの対象は `scope ∈ {current-pr, follow-up}` の finding のみ。

**指摘ゼロの場合**: `全指摘事項` が空なら本ゲートは no-op であり、mergeable 判定は現行と同一 (AC-4 非退行)。

## 5.3.1 Assessment Rules

**Red blocking rule: If even 1 finding with `scope ∈ {current-pr, follow-up}` **and measured=true** exists (after 5.3.0 / 5.3.0.M demotion), it MUST NOT be assessed as "Merge OK"**

All findings (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW) with `scope ∈ {current-pr, follow-up}` remaining in `全指摘事項` after 5.3.0 **and 5.3.0.M (実測必須ゲート)** demotion are always blocking regardless of loop count. There is no gradual relaxation — every remaining blocking finding must be resolved before merge. 実測 (repro / failing_test) を伴わない finding は 5.3.0.M で `non_blocking_findings` に分類済みのため本 rule の対象に残らない — blocking = 「runtime 実測を伴う CONFIRMED 指摘」のみであり、「指摘ゼロ」は到達可能な終了条件になる (Issue #2024)。

**scope=nit-noted exclusion**: Findings with `scope == "nit-noted"` (`acknowledged` トラックの informational 情報共有) are **excluded from `overall_assessment`** and **excluded from the mergeable countdown**. They are surfaced via two separate paths: (a) `/rite:pr-review` ステップ 5.4 「指摘事項」表の **scope 列** (pr-review.md ステップ 5.4 Integrated Report の `全指摘事項` 表で scope=nit-noted 行として可視化)、および (b) `/rite:fix` ステップ 1.4 display の独立した「nit (認知のみ) ({nit_noted_count}件)」セクション (fix.md 内のサブセクション、修正対象外と明示)。両者は表示先が異なるが scope=nit-noted という意味は共通で、いずれも merge を block しない。 The `/rite:fix` ステップ 2.4 `nit-noted-reply` サブステップで「nit、認知済」reply を投稿することで decay-track され、ステップ 4.6 サマリでは `acknowledged_nit_count` として独立カウントされる。これは fix commit 対象からも完全除外される。schema invariant #4 (CRITICAL/HIGH × nit-noted FAIL) により blocker 級の指摘を nit に降格する経路は禁止されているため、本除外は安全に運用できる。詳細な fix loop 経路は [`fix-relaxation-rules.md`](./fix-relaxation-rules.md) §Fix Target Classification を参照。

**Fact-Check exclusion**: When `review.fact_check.enabled: true`, CONTRADICTED (❌) findings and UNVERIFIED:ソース未確認 (⚠️) findings are removed from `全指摘事項` by the Fact-Checking Phase before assessment. Only findings remaining in `全指摘事項` after fact-checking are counted in `total_findings`. UNVERIFIED:リソース超過 findings remain in `全指摘事項` with `[未検証:リソース超過]` annotation and are counted (blocking maintained).

**Pre-existing issue handling**: Pre-existing issues (problems that existed before the current PR's changes, confirmed via revert test) are excluded from findings entirely by the reviewer's scope judgment rule. They are NOT collected as a separate report section and NOT auto-Issue-ified. If a reviewer wants to surface a pre-existing concern, it goes into the "調査推奨" section of the integrated report (Phase 5) — the user may optionally run `/rite:investigate {file}` separately (non-blocking, not counted in `total_findings`).

When executed standalone (outside a loop), the same rules apply: scope ∈ {current-pr, follow-up} findings are blocking, scope=nit-noted findings are excluded from blocking countdown.

## 5.3.3 Assessment Logic

Use **only findings with `scope ∈ {current-pr, follow-up}` and `measured == true`** for determination (nit-noted findings are excluded per §5.3.1 nit-noted exclusion; non-measured findings are excluded per §5.3.0.M 実測必須ゲート). Priority: CRITICAL findings → Requires fixes | HIGH/MEDIUM/LOW-MEDIUM/LOW findings → Cannot merge (blocking findings exist) | 0 blocking findings (nit-noted / non-measured のみ残存可) → Merge OK.

**`total_findings` definition**: `total_findings = count(findings where scope ∈ {current-pr, follow-up} and verification.measured == true)`. `acknowledged_nit_count = count(findings where scope == "nit-noted")` は独立 metric で `overall_assessment` 評価には使われない (Phase 4.6 サマリ表示のみ)。`non_blocking_count = count(non_blocking_findings)` (5.3.0.M で分類) も独立 metric で、5.3.5 サマリと 6.1.d PR コメント記録に使う (`overall_assessment` 評価には使われない)。

## 5.3.5 Output Format at Assessment Decision Time

When determining the assessment, explicitly output the finding count in the following format:

```
【指摘件数サマリー】
- CRITICAL: {count} 件
- HIGH: {count} 件
- MEDIUM: {count} 件
- LOW-MEDIUM: {count} 件
- LOW: {count} 件
- 合計: {total} 件（すべて blocking = 実測あり）

【実測必須ゲート】
- 実測あり (blocking): {total} 件
- 実測なし (non-blocking、PR コメント記録): {non_blocking_count} 件

【評価判定】
- 指摘件数: {total} 件
- 優先度 {n} に該当: {条件の説明}
- 総合評価: {マージ可 / マージ不可（指摘あり） / 修正必要}
```

**【実測必須ゲート】の省略規則**: `non_blocking_count == 0` かつ `total == 0` (指摘ゼロ) の場合は【実測必須ゲート】ブロック自体を省略してよい (AC-4: 指摘ゼロ経路の出力を現行と同一に保つ)。いずれかが 1 件以上なら必ず出力する。

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

**Important**: Any findings → cannot merge → `/rite:iterate` loop continues. "Merge OK" = 0 findings.

## 5.3.6 Return Values to Caller (Important)

Return: total_findings (if >0, `/rite:fix` required), evaluation, review_mode.

**Red important constraint:**

The caller (`/rite:iterate` review-fix loop) **mechanically** invokes `/rite:fix` when `total_findings > 0` or `evaluation != "マージ可"`, **regardless of AI judgment**.

The following decisions MUST NOT be made by `/rite:pr-review`:
- "The findings are minor, so no action is needed"
- Independently modifying assessment rules

`/rite:pr-review` is responsible only for accurately reporting the assessment results.

## 5.3.7 Prohibition of Independent Judgment After Assessment

> **It is prohibited for the AI to override the assessment logic (5.3.3) results.**

Prohibited actions: Exception handling by severity (e.g., "Only LOWs, so minor"), overriding assessment (e.g., "Effectively merge-OK"), inserting user confirmation.

> **[READ-ONLY RULE]**: 評価結果に基づいてコードを直接修正することは禁止されています。`Edit`/`Write` ツールでプロジェクトのソースファイルを変更してはなりません。ブロック指摘が存在する場合は `[review:fix-needed:{n}]` パターンを出力し、修正は `/rite:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、flow state 更新）と **read-only な git コマンド**（完全な許可・禁止一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照）のみ許可されます。working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）は **禁止** です。

**Principle:** Assessment logic result = final decision. AI's role = reporting + mechanical transition to the next phase only.
