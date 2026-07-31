---
type: "heuristics"
title: "強制層の機械化は裁量を消すが依存を消さない — 依存先が移った先に検出と復旧を同時に設計する"
domain: "heuristics"
description: "LLM の分類判断を決定論的 helper の regex 判定へ置き換えると、分類の依存先は「LLM の裁量」から「LLM の記述忠実性（転記の正確さ）」へ移るだけで、依存そのものは消えない。起点事例では Markdown セルの <br> を日本語句点へ潰す転記だけで実測 13 件の blocking が全件 non-blocking 化し、mergeable に反転した。機械化を入れるときは、新しい依存先に対する検出と復旧経路を同時に設計する。"
created: "2026-08-01T00:21:06+09:00"
updated: "2026-08-01T00:21:06+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260731T111118Z-pr-2074.md"
  - type: "fixes"
    ref: "raw/fixes/20260731T114035Z-pr-2074.md"
  - type: "fixes"
    ref: "raw/fixes/20260731T135712Z-pr-2074.md"
tags: []
confidence: high
---

# 強制層の機械化は裁量を消すが依存を消さない — 依存先が移った先に検出と復旧を同時に設計する

## 概要

「LLM の判断に置くと構造的に実行されない」種類の契約を、決定論的な helper へ機械化するのは正しい方向である。しかし機械化が消すのは**裁量**であって**依存**ではない。regex full match で分類するようにした瞬間、分類は「LLM が正しく判断するか」ではなく「LLM が正しく転記するか」に依存するようになる。依存先が移ったことに気づかないと、fail-open が新しい形で再発する。

## 詳細

起点事例は、レビュー指摘の blocking / non-blocking 分類（実測必須ゲート）を LLM の推論ステップから helper script による JSON 後処理へ移した。cycle 1 の CRITICAL 2 件はどちらも「依存先が移った先を検査していない」形だった。

- **scope 値の妥当性**: helper が `.scope` を正規化なしの完全一致で判定したため、enum 外の値（`Current-PR` 等）を持つ finding が blocking 集合からも降格対象からも**同時に**脱落した。出力される `blocking=0; demoted=0` は「指摘ゼロの正常終了」と区別できない。新しい述語を書くときは「述語から外れた要素はどちらのバケットへ行くか」を全分岐で確認する。同じ関数内で `severity` だけ `ascii_upcase` されている非対称は、意図した厳格さではなく見落としの signal だった。
- **アンカー直前の境界**: Markdown セル内の `<br>` を日本語の句点へ潰す——ごく自然な転記の揺れ——だけで、実測済み 13 件の blocking すべてが「アンカーなし = 非実測 = non-blocking」へ降格し、assessment が mergeable に反転した。しかも routing 表は WARNING に対して「続行」しか指示しておらず、復旧経路が存在しなかった。

同じ作業で、実測アンカーの repro に raw pipe が入るだけで無音降格する問題も観測されている（[実測アンカーの repro に書くパイプは U+00A6 へ置換する](../patterns/verification-anchor-pipe-substitution.md)）。書式契約を厳しくするほど、その契約自体について書くことが難しくなるという摩擦も現れた。

**適用条件**: 散文の規約・LLM の判断を機械的な強制層へ置き換える設計をするとき。「これで裁量が消えた」で止めず、(1) 新しい依存先は何か、(2) その依存先が破れたことを機械的に検出できるか、(3) 検出したとき何をすれば復旧するか、を 3 点セットで設計する。

## 関連ページ

- [緩い検出述語の出力を停止条件へ昇格させてはならない](../anti-patterns/loose-detector-predicate-promoted-to-stop-condition.md)
- [実測アンカーの repro に書くパイプは U+00A6 へ置換する](../patterns/verification-anchor-pipe-substitution.md)
- [同一主張を複数言語で持つ記述は grep の盲点になる](../anti-patterns/same-claim-in-multiple-languages-evades-grep.md)

## ソース

- [PR #2074 review results](../../raw/reviews/20260731T111118Z-pr-2074.md)
- [PR #2074 fix results (cycle 1)](../../raw/fixes/20260731T114035Z-pr-2074.md)
- [PR #2074 fix results (5 cycle 総括)](../../raw/fixes/20260731T135712Z-pr-2074.md)
