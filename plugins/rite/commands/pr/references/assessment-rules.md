# Assessment Rules (Phase 5.3)

> **Source**: Extracted from `review.md` Phase 5.3.1-5.3.7. This file is the source of truth for assessment rules.

## 5.3.1 Assessment Rules

**Red blocking rule: If even 1 finding exists, it MUST NOT be assessed as "Merge OK"**

All findings (CRITICAL/HIGH/MEDIUM/LOW) are always blocking regardless of loop count. There is no gradual relaxation — every finding must be resolved before merge.

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

> **[READ-ONLY RULE]**: 評価結果に基づいてコードを直接修正することは禁止されています。`Edit`/`Write` ツールでプロジェクトのソースファイルを変更してはなりません。ブロック指摘が存在する場合は `[review:fix-needed:{n}]` パターンを出力し、修正は `/rite:pr:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、`.rite-flow-state` 更新）のみ許可されます。

**Principle:** Assessment logic result = final decision. AI's role = reporting + mechanical transition to the next phase only.
