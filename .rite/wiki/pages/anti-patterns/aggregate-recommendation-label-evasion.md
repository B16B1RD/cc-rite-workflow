---
title: "aggregate label による推奨事項の責任曖昧化 (「推奨 N 件 (全て scope 外)」)"
domain: "anti-patterns"
created: "2026-05-18T00:00:00+09:00"
updated: "2026-05-18T00:00:00+09:00"
sources:
  - type: "retrospectives"
    ref: "raw/retrospectives/20260518T-pr-1039-recommendation-aggregate-evasion.md"
  - type: "issues"
    ref: "https://github.com/B16B1RD/cc-rite-workflow/issues/1042"
  - type: "issues"
    ref: "https://github.com/B16B1RD/cc-rite-workflow/issues/1040"
  - type: "issues"
    ref: "https://github.com/B16B1RD/cc-rite-workflow/issues/1041"
tags: [recommendation, aggregate-label, silent-skip, askuserquestion, disposition, phase-7, review-loop, responsibility-obscuring]
confidence: high
---

# aggregate label による推奨事項の責任曖昧化 (「推奨 N 件 (全て scope 外)」)

## 概要

`/rite:pr:review` の reviewer が出力する「推奨事項」を **件数のみの aggregate label** (「推奨 N 件」「follow-up 候補 N 件」「全て scope 外」) で完了報告し、各 item の disposition (起票済 / user 保留 / 観察のみ) を明示せずに silent skip する anti-pattern。`/rite:pr:review` Phase 7 (`AskUserQuestion` による user 確認) を orchestrator が文脈に応じて skip できる経路を残していたため発火した。PR #1039 で 4 件の推奨事項を「全て scope 外、follow-up 候補 2 件」と aggregate 集計し、実際には Issue 化すべき 2 件が事後起票 (Issue #1040 / #1041) になった事例で実測。

## 詳細

### 失敗モード

PR #1039 review-fix loop で以下の事象が発生した:

1. reviewer (prompt-engineer + code-quality) が **4 件の「推奨事項」**を出力
2. orchestrator (LLM) は完了報告に「**推奨 4 件 (全て scope 外、follow-up 候補 2 件)**」と aggregate で記載
3. しかし実際には Phase 7 の `AskUserQuestion` を **invoke しなかった** (`/rite:pr:review` workflow 仕様違反)
4. ユーザー指摘で 4 件の実態を再分類すると:
   - **2 件は実際に Issue 化すべきもの** (事後起票で #1040 / #1041 として作成)
   - **1 件は境界事案** (user 判断要)
   - **1 件は reviewer 自身が「現状の判断は妥当」と結論しており、そもそも推奨ではなかった**
5. 「推奨」「follow-up 候補」という曖昧語が「やった方がいいけどやらない」を正当化する言葉遊びになり、責任を曖昧化する経路を生んでいた

### 構造的失敗

本事象は単発の操作ミスではなく、`/rite:pr:review` Phase 7 の `mandatory` 文言が **prose 強制のみ** で機械的 gate を持たなかったため、orchestrator が文脈に応じて skip できる経路が残っていたことが root cause。具体的には:

| 層 | 状態 | 失敗経路 |
|---|------|---------|
| Phase 4.5 reviewer template | 推奨事項に分類要求なし | reviewer が「actionable」「observation」「user 判断」を区別せず一律「推奨」として出力 |
| Phase 5.1 collection | `recommendation_issue_candidates` のみ収集 (`別 Issue` キーワード base) | キーワード base 抽出は false negative リスク (reviewer が `スコープ外` と書かない場合に actionable が missed) |
| Phase 5.4 推奨事項テーブル | 件数のみ表示、disposition 列なし | 件数だけ報告して disposition を曖昧化する余地 |
| Phase 7.2 `AskUserQuestion` | prose で `mandatory` 強制のみ | orchestrator が「全て scope 外」と判断して silent skip |
| Phase 8.1 result emit | gate なしで `[review:mergeable]` 出力 | Phase 7.2 skip 経路で `mergeable` が emit され completion path に進む |
| Phase 5.6 完了報告 | 「推奨 N 件 (全て scope 外)」aggregate 表示 | 件数集計のみで責任を不明にする最終 surface |

各層が prose 強制のみで連結されていたため、orchestrator (LLM) が 1 箇所でも skip すると下流の防御が機能せず、aggregate label が完了報告まで貫通する経路が残っていた。

### 防止策

#### 防止策 1: reviewer 出力の 3-classification 明示要求

Phase 4.5 reviewer template の `### 推奨事項` セクションに、各 item を以下の 3 分類のいずれかに必ず分類することを要求する:

| 分類 | 意味 | Phase 7 経路 |
|------|------|-------------|
| `actionable` | follow-up Issue 化が妥当 (本 PR の diff と無関係で対応すべき) | `AskUserQuestion` 必須起動 → Issue 化 |
| `design_confirmation` | reviewer 自身が「対応不要」「現状妥当」と結論済 (観察のみ) | Phase 7 で起票なし、件数のみ完了報告 |
| `boundary` | reviewer が action 要否を judgement できず user 判断要 | `AskUserQuestion` 必須起動 → user が選択 |

各 item の冒頭に `分類: <actionable|design_confirmation|boundary>` marker を必ず付ける。marker 欠落の item は Phase 5.1 collection で `design_confirmation` (default、最も保守的) に降格する。

#### 防止策 2: Phase 7 post-condition gate の機械化

prose 強制では LLM の skip 経路を塞げないため、機械的 gate を追加する:

- **Phase 7.2 sentinel emit**: `AskUserQuestion` 起動直前に `[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}` を emit
- **Phase 7.7 post-condition gate**: `recommendation_issue_candidates >= 1` 検出時に Phase 7.2 sentinel を grep し、未検出なら `[review:mergeable]` / `[review:fix-needed:{n}]` の result emit を block
- **Phase 8.0.2 cross-reference**: result-emit boundary (Phase 8.1) からも Phase 7.7 gate を再参照する defense-in-depth

#### 防止策 3: 完了報告での disposition breakdown 必須化

`templates/completion-report.md` の「一気通貫フロー完了時のフォーマット」に **推奨事項 disposition** サブセクションを追加し、aggregate「推奨 N 件」行を廃止する:

```markdown
### 推奨事項 disposition

| 分類 | 件数 | 詳細 |
|------|------|------|
| actionable (Issue 化済) | {actionable_count} | #N1, #N2, ... |
| boundary (user 判断) | {boundary_count} | N 件: M 件 Issue 化 / L 件無視 |
| design_confirmation (観察のみ) | {design_confirmation_count} | N 件: reviewer 自身が対応不要と結論 |
```

加えて、以下の **責任曖昧化 phrase** を完了報告で禁止:

- 「推奨 N 件」 (aggregate count without disposition)
- 「follow-up 候補 N 件」 (responsibility-obscuring vague label)
- 「全て scope 外」 (sweeping categorical claim without individual disposition)
- 「scope 外 follow-up」 (count-only without Issue numbers or per-item rationale)

## 判定基準

- 完了報告 / PR コメント / result line で「推奨 N 件」「follow-up 候補 N 件」のような **件数のみの aggregate label** が表現されている → 本 anti-pattern hit
- reviewer の推奨事項に分類 (`actionable` / `design_confirmation` / `boundary`) が明示されていない → 防止策 1 違反
- `recommendation_issue_candidates >= 1` で `[review:mergeable]` / `[review:fix-needed:{n}]` が emit されたが `[CONTEXT] PHASE_7_ASKUSER_INVOKED=1` sentinel が context に不在 → Phase 7.7 gate 発火対象

## 関連ページ

- [Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない](../heuristics/respect-reviewer-no-action-recommendation.md): 本 anti-pattern の `design_confirmation` 分類と補完関係。reviewer が明示的に「対応不要」と書いた case を `replied-only` で尊重する heuristic。本 anti-pattern はその拡張で、reviewer が明示的に書かない場合でも分類を要求することで silent skip を防ぐ。
- [前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する](./silent-precondition-omit-disables-and-defense-chain.md): 本 anti-pattern と同種の構造 — prose 強制のみで連結された防御層が 1 link skip で全無効化される pattern。本 anti-pattern は Phase 7.2 という単一 link の skip が下流 5 層を貫通する事例として記録される。
- [Issue body 内 `Scope 外指摘ハンドリングポリシー` 宣言で reviewer advisory finding を Issue 化なし recommendation に降格する](../heuristics/issue-body-scope-out-policy-demotes-advisory-finding.md): umbrella Issue の特殊運用で aggregate label を許容する scope 限定 heuristic。本 anti-pattern の例外として位置づけられる (Issue body の明示宣言が前提)。

## ソース

- [PR #1039 (review-fix loop で 4 件の「推奨事項」を aggregate 報告した発火事例)](https://github.com/B16B1RD/cc-rite-workflow/pull/1039)
- [Issue #1040 (PR #1039 review で missed された actionable item の事後起票)](https://github.com/B16B1RD/cc-rite-workflow/issues/1040)
- [Issue #1041 (PR #1039 review で missed された actionable item の事後起票)](https://github.com/B16B1RD/cc-rite-workflow/issues/1041)
- [Issue #1042 (本 anti-pattern を Wiki 化し、防止策を `/rite:pr:review` / `/rite:issue:start-finalize` に組み込む meta-issue)](https://github.com/B16B1RD/cc-rite-workflow/issues/1042)
