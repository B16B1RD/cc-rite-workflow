---
title: "同 file 内 MUST NOT vs MUST 衝突: bare form 禁止規約と bare form 出力義務の自己矛盾"
domain: "anti-patterns"
created: "2026-04-20T13:25:00+00:00"
updated: "2026-04-20T15:15:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260420T104328Z-pr-623.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T105116Z-pr-623.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T143336Z-pr-624.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T144134Z-pr-624.md"
tags: [prompt-engineering, design-conflict, cross-validation, bare-sentinel, step-addition]
confidence: high
---

# 同 file 内 MUST NOT vs MUST 衝突: bare form 禁止規約と bare form 出力義務の自己矛盾

## 概要

同一 prompt ファイル内で「形式 X を禁止 (MUST NOT)」する既存規約と、新しく追加する「形式 X を義務化 (MUST)」する指示が衝突する設計欠陥。single-reviewer では気づきにくく、prompt-engineer × tech-writer のような cross-validation で初めて検出される。根本対策は形式自体を区別できる別 form (HTML コメント等) を採用すること。

## 詳細

### 実例 (PR #623)

`commands/pr/cleanup.md` は Issue #604 契約として bare bracket 形式 (`[cleanup:completed]`) を LLM turn-boundary heuristic 誤発火源として MUST NOT 化していた。同 file 内に routing dispatcher (Item 0) を追加する際、以下の evidence 出力義務を MUST として書き込んだ:

```
[routing-check] ingest=matched
```

これは bare bracket 形式であり、同 file 内の既存 MUST NOT 規約 (bare bracket sentinel 禁止) と衝突する。ユーザーが prompt を実行する際、LLM は「bare form は禁止では?」「evidence 出力すべき?」の判断に窮する (そして LLM は silent skip する経路に流れやすい)。

### 検出困難性

single-reviewer (特に prompt-engineer 単独) では、自分が追加する新規 evidence 義務化仕様に集中するあまり、同 file 内の既存 MUST NOT 規約との衝突に気づきにくい。PR #623 cycle 1 では以下の cross-validation で初検出された:

- **prompt-engineer**: evidence 出力義務化の prompt 文言を評価
- **tech-writer**: 既存 MUST NOT 契約との整合性を評価 (別観点)
- → 両者の独立指摘で衝突が発覚

single-reviewer であれば別層の指摘が落ちる構造。

### canonical 対策

形式そのものを区別できる別 form を採用する:

**旧 (衝突あり)**:
```
[routing-check] ingest=matched
```

**新 (HTML コメント化で衝突回避)**:
```
<!-- [routing-check] ingest=matched -->
```

HTML コメント形式は:
- bare bracket 形式とは構文的に別物 (MUST NOT の対象外)
- LLM turn-boundary heuristic の誤発火 trigger にならない
- grep-matchable property は保持される (`grep -F '[routing-check]'` で検出可能)

### 予防策

新規 MUST 指示を書く前に、同 file 内に以下の conflicting pattern が存在しないか grep で事前確認:

```bash
grep -i 'MUST NOT.*bare\|禁止.*bracket' commands/*.md
```

MUST NOT 条項が見つかった場合、新規 MUST 指示が同形式を要求していないか check する。

### cross-reviewer 設計指針

evidence 義務化 / 新規 sentinel / 新規 prompt 規約を追加する PR は、以下の **役割の異なる 2 reviewer** を必ず assign する:

- **prompt-engineer**: 新規仕様の内部整合性 (指示の明確性 / LLM 実行可能性)
- **tech-writer** または **既存契約熟知 reviewer**: 同 file 内既存規約との衝突 (cross-reference 整合性)

### 新 Step 追加 × 既存 MUST NOT 衝突と layer 明示対策 (PR #624 での evidence)

PR #624 (Issue #618) で `commands/wiki/ingest.md` Phase 9.1 に新 Step 3 (`.rite-flow-state` terminal patch、bash 実行) を追加した際、既存の MUST NOT #621 reinforce (「三点セット #2/#3 間に recap 等の追加行を挿入してはならない」) と Step 3 の実行タイミング指示が衝突するように読める F1 CRITICAL が prompt-engineer × code-quality の cross-validation で検出された。

**衝突の構造**:

- 既存 MUST NOT: `[CONTEXT] continuation` HTML コメント (#2) と `<!-- [ingest:completed] -->` sentinel (#3) の間に追加行を入れると、LLM turn-boundary heuristic が #2 を terminator と誤認して #3 を absolute last line として出力する前に turn を閉じる
- 新 Step 3 (Issue #618): sentinel 出力後に flow-state を `ingest_completed` に deactivate patch する bash 実行を追加
- 読み取り衝突: 「sentinel 出力後に bash 実行」が「#2/#3 間の挿入禁止」と矛盾するように読める (LLM が Step 3 を sentinel 前に移動するか廃止する silent regression 誘発)

**canonical 対策 (PR #624 cycle 1 fix で確立)**:

bash tool output と response text の **layer 境界** を prose で明示する:

- Claude Code の実行モデル上、bash tool の stdout/stderr は Bash tool result として conversation 上別枠表示され、**assistant response の markdown text content には相当しない**
- MUST NOT の禁止対象は「response text 追加行」のみ
- Step 3 の bash 実行は別チャンネルのため「#2/#3 間 recap 挿入禁止」の対象外
- 実行順序は document 記載順序と一致: Step 1 (response text 出力) → Step 2 (response text 最終行 sentinel 出力) → Step 3 (bash tool 実行、response text に content 追加しない)

本 pattern は「新規 Step/bash 実行を既存 MUST NOT 条項のあるファイルに追加する際」に一般化される:

1. **実行層の特定**: 新 Step が response text に行を追加するか、bash tool 別チャンネル経由か、meta-step (非出力) かを分類する
2. **MUST NOT の禁止対象 layer 明示**: 既存 MUST NOT が「response text 追加行」のみを禁止しているのか、bash 実行全般を禁止しているのかを prose で明確化する
3. **対象外であることの prose 明示**: 新 Step が MUST NOT の対象外であれば、"bash tool 実行 note" 等の見出しで理由を説明する (LLM が後続編集で Step を誤って move / 削除する regression を防ぐ)
4. **Output ordering 表に meta-step を含めない**: response text 出力行のみで「#1 → #2 → #3 は連続 3 行」invariant を維持し、bash 実行などの meta-step は表外で document 記載順序に配置する

**DRIFT-CHECK ANCHOR**:

本 pattern を適用した PR では、Step 番号 ↔ Output ordering 対応を semantic name 参照の ANCHOR で 3 site (Step 見出しの prose / MUST NOT の "bash tool 実行 note" / 設計メモ非レンダリング注釈) に展開し、将来の編集時に「Step 3 meta-step の扱いを変更する場合は MUST NOT 本文も同時に更新すること」を grep 可能な形で contract 化する。詳細は [DRIFT-CHECK ANCHOR は semantic name 参照で記述する](../patterns/drift-check-anchor-semantic-name.md) 参照。

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](prose-design-without-backing-implementation.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)

## ソース

- [PR #623 review results (cycle 1)](raw/reviews/20260420T104328Z-pr-623.md)
- [PR #623 fix results (cycle 1)](raw/fixes/20260420T105116Z-pr-623.md)
- [PR #624 review results (新 Step × 既存 MUST NOT 衝突、bash tool output 境界)](raw/reviews/20260420T143336Z-pr-624.md)
- [PR #624 fix results (layer 明示対策の確立)](raw/fixes/20260420T144134Z-pr-624.md)
