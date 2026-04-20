---
title: "同 file 内 MUST NOT vs MUST 衝突: bare form 禁止規約と bare form 出力義務の自己矛盾"
domain: "anti-patterns"
created: "2026-04-20T13:25:00+00:00"
updated: "2026-04-20T13:25:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260420T104328Z-pr-623.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T105116Z-pr-623.md"
tags: [prompt-engineering, design-conflict, cross-validation, bare-sentinel]
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

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](prose-design-without-backing-implementation.md)

## ソース

- [PR #623 review results (cycle 1)](raw/reviews/20260420T104328Z-pr-623.md)
- [PR #623 fix results (cycle 1)](raw/fixes/20260420T105116Z-pr-623.md)
