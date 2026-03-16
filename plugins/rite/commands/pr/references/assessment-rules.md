# Assessment Rules (Phase 5.3)

> **Source**: Extracted from `review.md` Phase 5.3.1-5.3.7. This file is the source of truth for assessment rules.

## 5.3.1 Assessment Rules (Loop Count Aware)

**Red blocking rule: If even 1 blocking finding exists, it MUST NOT be assessed as "Merge OK"**

Distinguish between "blocking findings" and "non-blocking findings" based on loop count. Determined from the `review.loop` settings in `rite-config.yml` and the review-fix loop count in conversation context. When executed standalone (outside a loop), treat as loop iteration 1.

**Gradual relaxation table:**

| Loop Count | Gate Mode | Blocking Target | Non-Blocking |
|-----------|------------|------------|--------------|
| 1 to `relax_medium_after - 1` (default: 1-2) | Strict mode | CRITICAL/HIGH/MEDIUM/LOW | None |
| `relax_medium_after` to `relax_high_after - 1` (default: 3-4) | MEDIUM/LOW relaxation | CRITICAL/HIGH | MEDIUM/LOW |
| `relax_high_after` to `max_iterations - 1` (default: 5-6) | HIGH relaxation | CRITICAL only | HIGH/MEDIUM/LOW |
| `max_iterations` (default: 7) | Forced termination | -- | All remaining findings are converted to separate Issues and the loop exits |

Load `review.loop` from `rite-config.yml` (defaults: max_iterations=7, relax_medium_after=3, relax_high_after=5). Non-blocking findings reported but not in `total_blocking_findings`; candidates for separate Issue creation.

## 5.3.3 Assessment Logic (Loop Count Aware)

Use **only blocking findings** for determination. Priority: CRITICAL blocking → Requires fixes | HIGH/MEDIUM/LOW blocking → Cannot merge (findings exist) | 0 blocking → Merge OK.

## 5.3.5 Output Format at Assessment Decision Time

When determining the assessment, explicitly output the finding count and loop information in the following format:

```
【ループ情報】
- 現在のループ回数: {loop_count} / {max_iterations}
- 適用中のゲート: {厳格モード / MEDIUM/LOW 緩和 / HIGH 緩和 / 強制終了}
- 非ブロック指摘: {non_blocking_count} 件（別 Issue 化対象）

【指摘件数サマリー】
- CRITICAL: {count} 件
- HIGH: {count} 件 {※非ブロック の場合は "(非ブロック)" を付記}
- MEDIUM: {count} 件 {※非ブロック の場合は "(非ブロック)" を付記}
- LOW: {count} 件 {※非ブロック の場合は "(非ブロック)" を付記}
- 合計: {total} 件（ブロック: {blocking} 件 / 非ブロック: {non_blocking} 件）

【評価判定】
- ブロック指摘件数: {blocking} 件
- 優先度 {n} に該当: {条件の説明}
- 総合評価: {マージ可 / マージ不可（指摘あり） / 修正必要}
```

**Note**: For standalone execution (outside a loop), display the loop count in the "Loop Information" section as "1 / {max_iterations} (standalone execution)".

**Additional output for verification mode:**

When `review_mode == "verification"`, output the following in addition to the above:

```
【検証モード情報】
- レビューモード: 検証 (verification)
- 前回レビュー commit: {last_reviewed_commit}
- 修正検証: FIXED {fixed} / NOT_FIXED {not_fixed} / PARTIAL {partial}
- リグレッション: {regression_count} 件
- Stability Concerns: {stability_concern_count} 件（非ブロック）
```

**Important**: Blocking findings → cannot merge → `/rite:issue:start` loop continues. "Merge OK" = 0 blocking findings (non-blocking handled via separate Issues).

## 5.3.6 Return Values to Caller (Important)

Return: total_findings, **total_blocking_findings** (if >0, `/rite:pr:fix` required), total_non_blocking_findings, evaluation, loop_count, gate_mode, review_mode, stability_concerns.

**Red important constraint:**

The caller (`/rite:issue:start` Phase 5.5) **mechanically** invokes `/rite:pr:fix` when `total_blocking_findings > 0` or `evaluation != "マージ可"`, **regardless of AI judgment**.

The following decisions MUST NOT be made by `/rite:pr:review`:
- "Since blocking findings are 0, non-blocking findings can also be ignored"
- "The findings are minor, so no action is needed"
- Independently modifying the gradual relaxation table configuration values

`/rite:pr:review` is responsible only for accurately reporting the assessment results. Gradual relaxation is applied mechanically according to the `rite-config.yml` settings.

## 5.3.7 Prohibition of Independent Judgment After Assessment

> **It is prohibited for the AI to override the assessment logic (5.3.3) results.**

Prohibited actions: Exception handling by severity (e.g., "Only LOWs, so minor"), overriding assessment (e.g., "Effectively merge-OK"), inserting user confirmation.

> **[READ-ONLY RULE]**: 評価結果に基づいてコードを直接修正することは禁止されています。`Edit`/`Write` ツールでプロジェクトのソースファイルを変更してはなりません。ブロック指摘が存在する場合は `[review:fix-needed:{n}]` パターンを出力し、修正は `/rite:pr:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、`.rite-flow-state` 更新）のみ許可されます。

**Principle:** Assessment logic result = final decision. AI's role = reporting + mechanical transition to the next phase only.
