---
title: "Markdown table 内に HTML コメントを挿入すると GFM table boundary が破壊される"
domain: "anti-patterns"
description: "GitHub Flavored Markdown の table 内部に `<!-- comment -->` を挿入すると、その時点で table 構造が終了したと解釈され、後続行が `<p>` 段落として render される silent regression を起こす。"
promote: rite-plugin
created: "2026-05-03T12:53:26Z"
updated: "2026-08-06T22:40:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260503T110855Z-pr-792-fix-cycle3.md"
  - type: "fixes"
    ref: "raw/fixes/20260806T111135Z-pr-2124.md"
tags: []
confidence: high
---

# Markdown table 内に HTML コメントを挿入すると GFM table boundary が破壊される

## 概要

GitHub Flavored Markdown の table 内部に `<!-- comment -->` を挿入すると、その時点で table 構造が終了したと解釈され、後続行が `<p>` 段落として render される silent regression を起こす。**Edit ツールでの一時的な「行の論理的削除コメント化」目的での HTML コメント挿入は table boundary を破壊するため禁忌**。

## 詳細

### 発生条件

GFM の table 解析は「`|` を含む連続行ブロック」を table とみなす。途中に HTML コメント行が挿入されると、その行は table cell として解釈されないため table boundary が直前で閉じ、コメント以降の `|` を含む行は別 table または `<p>` 段落として再解釈される。Markdown processor (npx marked / GitHub renderer) で render すると以下のように脱落する:

```markdown
| Phase | 説明 |
|-------|-----|
| Phase 1 | 検査 |
<!-- Phase 2 は廃止 -->
| Phase 3 | 報告 |    ← この行が <p> 段落として render され、table から脱落
```

`Phase 3` 行は visual には table 内に見えるが、render 結果では table の外に放り出される silent regression。`grep` 等の plain-text 検索では検出不能。

### Detection Heuristic

- **render 検証**: `npx marked < file.md` で HTML 出力を確認し、対象 table の `<tr>` 行数が期待数と一致するか verify する
- **CI 自動検証**: Markdown lint rule で `^<!--.*-->$` を含む行が table block 内にあれば fail する custom check
- **PR diff レビュー**: table 構造を変更する diff で、HTML コメントが挿入されている場合は必ず render 結果を verify する

### Mitigation — 代替パターン

行を一時的に「論理的削除」したい場合の代替:

1. **Table 直前または直後の独立段落へ配置**: コメントは table boundary の外に置く。table の上に `<!-- 旧 Phase 2 は #793 で廃止 -->` を独立段落として記述する
2. **Footnote / 別セクションへの move**: 廃止理由を別セクション (例: `## 履歴`) に移し、table からは行ごと削除
3. **Strikethrough テキスト**: 残したい場合は `| ~~Phase 2~~ | 廃止 |` で render される取り消し線セル
4. **Comment column 追加**: 廃止 status を別 column として明示 (`| Phase | 説明 | Status |`)

### 起点事例の cycle 3 での実測

起点事例の cycle 2 で SPEC-IMPL-FILES table 内の特定行を一時的にコメントアウトする目的で `<!-- removed: ... -->` を挿入したところ、cycle 3 review で「table の最終行が `<p>` 段落として脱落」が tech-writer によって検出された。npx marked で render verification すると確かに最終行が table 外で render されており、修正は HTML コメントを **table 終了直後 (空行を挟んで) の独立段落** に移動することで解消した。

### code span で囲んでもパイプはセル境界を割る（PR #2124 cycle 3）

HTML コメントだけでなく、**テーブルセル内の code span に含まれる raw pipe** も同じ形でセル境界を破壊する。バッククォートで囲んでも GFM はパイプのエスケープ（\|）を要求する。PR #2124 では SPEC.md の 1 セルが割れ、Purpose 列が文中で切断され Notes 値が破棄されていた。

### 「テーブルが壊れる」は目視ではなく API 実測で示す

ローカルの markdown プレビューでは GFM 固有のセル境界解釈を再現できない。tech-writer reviewer は **GitHub の `/markdown` API に実際に POST してレンダリング結果を観測**し、`<td>` の数を数えて修正前後を実測した（4 セル → 3 セル、Notes 値の復帰）。文書の修正は文書を読むのではなく、**レンダラに実際に食わせて確かめる**。

## 関連ページ

- [Markdown code fence の balance は commit 前に awk で機械検証する](../patterns/markdown-fence-balance-precommit-check.md)
- [Markdown inline code を Japanese corner brackets 「!」 に置換すると LLM 提示時 semantic interpretation が劣化する](./markdown-japanese-corner-brackets-break-inline-code.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #792 cycle 3 fix results (GFM table 構造破壊 + Asymmetric Fix Transcription 再発)](../../raw/fixes/20260503T110855Z-pr-792-fix-cycle3.md)
- [PR #2124 fix results (cycle 3)（code span 内 raw pipe のセル境界破壊を /markdown API の td 数で実測）](../../raw/fixes/20260806T111135Z-pr-2124.md)
