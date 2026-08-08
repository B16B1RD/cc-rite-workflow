---
type: "heuristics"
title: "差分スコープのレビューは diff の外を基準以前に見られない — cycle 上限到達後にフルレビューを 1 回挟む"
domain: "heuristics"
promote: rite-plugin
description: "cycle 2 以降を差分スコープ化すると「範囲は絞るが基準は緩めない」と規定していても、範囲の外は基準以前に観測されない。PR #2130 では 5 cycle の差分スコープを消化した直後のフルレビューで blocking 5 件 (うち HIGH 3 件) が出て、すべてが各 cycle の diff の外側にあった。cycle 上限到達後にフルレビューを 1 回挟む運用がこの構造的限界への実効的な対処になる。"
created: "2026-08-07T18:40:00+09:00"
updated: "2026-08-07T18:40:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260807T043149Z-pr-2130.md"
tags: []
confidence: high
---

# 差分スコープのレビューは diff の外を基準以前に見られない — cycle 上限到達後にフルレビューを 1 回挟む

## 概要

レビューループの cycle 2 以降を差分スコープ（前 cycle の fix diff のみを見る）にすると効率は上がるが、**範囲の外にある欠陥は「基準を満たすか」以前に観測されない**。「範囲は絞るが基準は緩めない」という規定は、範囲内の判定品質を約束するだけで、範囲外の被覆については何も言っていない。

## 詳細

PR #2130 での実測。前の run で 5 cycle の差分スコープを消化し、blocking を **7 → 5 → 4 → 5 → 1** まで落とした。サーキットブレーカーの上限に到達したあと、人間が `/rite:iterate` を再実行して**新しい run の cycle 1 = PR 全体のフルレビュー**を回した。

結果、**差分スコープが 5 cycle 通して一度も見なかった面から blocking 5 件（うち HIGH 3 件）が出た**。内訳:

- gate の判定 anchor を gate される側が選ぶ構造（HIGH、security / prompt-engineer が独立検出）
- AC が degraded に倒すと明示列挙する 5 群のうち 1 群が未被覆。しかも degraded と pass は rc が同値なので rc の assert では原理的に検出できない
- fixture の並べ方が境界条件を消していた（pin を常に最古のファイルに置いていたため後段の判定が一度も走らず、no-op 化しても全 assert が緑）
- assert 名と fixture の乖離（「同 SHA を持っても pass しない」という名前の assert の fixture が実は別 SHA）

**これらはすべて、各 cycle の diff の外側にある**。差分スコープの各 cycle は正しく動作しており、見落としではない — 構造的に見えない。

**なぜ収束曲線が誤解を招くか**: 7 → 5 → 4 → 5 → 1 は「収束している」ように読める。しかし減っているのは**差分スコープが見ている面での blocking 件数**であって、PR 全体の欠陥密度ではない。差分スコープを続ける限り、この曲線は必ず 0 に向かう — 見る範囲が縮み続けるからである。**収束の主張は、その判定が見ている範囲の広さとセットでしか意味を持たない**。

**対処**:

1. **cycle 上限到達後にフルレビューを 1 回挟む**。PR #2130 ではこれが実効的に機能し、差分スコープが構造的に見られない面から HIGH 3 件を回収した
2. 差分スコープの run で blocking が 0 or 1 に落ちても、**それだけを根拠に mergeable と判定しない**。「差分スコープで収束した」と「PR 全体が基準を満たす」は別の主張である
3. cycle 数の上限は「品質の妥協点」ではなく「スコープを切り替える合図」として使う。上限で止めるのではなく、上限でフルパスへ切り替える

**判定の目安**: 直近の cycle の diff に含まれないファイル・関数で、その PR が新規追加したものがあれば、それは差分スコープが一度も見ていない面である。fixture の配置・assert 名と fixture の対応・AC の列挙と被覆の対応は、いずれも diff の外に留まりやすい典型。

## 関連ページ

- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](./reviewer-scope-antidegradation.md)
- [cycle が進んでも findings が減らないときは点修正をやめて構造を疑う](./non-converging-review-loop-suspect-structure.md)

## ソース

- [PR #2130 review results (full pass)](../../raw/reviews/20260807T043149Z-pr-2130.md)
