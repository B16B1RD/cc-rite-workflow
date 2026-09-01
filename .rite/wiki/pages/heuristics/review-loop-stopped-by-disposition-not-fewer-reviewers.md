---
type: "heuristics"
title: "レビューループを止めるのは reviewer を減らすことではなく disposition 規則を変えること"
domain: "heuristics"
description: "非実測の文言指摘を毎 cycle 先回りで直すと、その修正が次 cycle のレビュー対象になりループの燃料になる。止める操作は reviewer 数の削減ではなく、「本 PR が既に複数回書き換えた行の文言推敲はスコープ外」と disposition を宣言し、指摘を designated home へ流すこと。"
promote: rite-plugin
created: "2026-09-01T20:30:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-01T20:30:00+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T110702Z-pr-2498.md"
tags: []
confidence: high
---

# レビューループを止めるのは reviewer を減らすことではなく disposition 規則を変えること

## 概要

非実測の文言指摘を毎 cycle 先回りで直すと、その修正が次 cycle のレビュー対象になりループの燃料になる。止める操作は reviewer 数の削減ではなく、「本 PR が既に複数回書き換えた行の文言推敲はスコープ外」と disposition を宣言し、指摘を designated home へ流すこと。

## 詳細

**観測された形**: ある PR の cycle 3 と cycle 4 の指摘は、いずれも「直前 cycle の修正が触った行のコメント文言」に対するものだった。パッチの重ね掛けが 2 cycle 続き、cycle 4 では前 cycle の修正そのものが over-fix と判定されて差し戻された。

**なぜ先回り修正が燃料になるか**: 非実測指摘には designated home がある（記録コメントと、cleanup が作る follow-up Issue）。sweep で消化すべき実質的な doc-sync gap と、cycle ごとに湧く文言の推敲は別物で、後者を先回りで直すと次 cycle のレビュー対象を自分で作ることになる。

**やってはいけない止め方**: reviewer 数を削る。これは品質を予算で縛る操作であり、切るべき発散・空転ではなく収束に向かう実サイクルを切っている。

**正しい止め方**: 終端 cycle を宣言し、reviewer への指示に disposition 規則を明示する。

- 「本 PR が既に 2 回以上書き換えた行の文言推敲はスコープ外」
- 「非実測の指摘は修正せず記録と follow-up へ回す」

reviewer の人数と審査の深さは維持したまま、出た指摘の**行き先**だけを変える。

**トレンド判定の「収束中」を額面で読まない**: blocking 件数の推移が `3,0,0,0` で `converging_or_descending` と出ても、毎 cycle の指摘が帰結クラス降格で non-blocking へ落ちているなら、この数列は「指摘が減った」ではなく「降格が効いている」ことの反映である。ブレーカーの機械判定は残しつつ、orchestrator 側は「今 cycle の指摘は前 cycle の修正が原因か」を別途見る。

**scope 判定の基準は cycle の diff ではなく PR の diff**: ある行が base に存在しないなら、それは何 cycle 目に入った行であれ PR のスコープ内である。cycle 単位で scope を判定すると、前 cycle で入った行が永久に「差分外」になり、誰も直せない領域ができる。

## 関連ページ

- [実装が Issue の MUST と原則の両方に挟まれたら、実装を戻さず契約側（Decision Log と AC の例外）を更新する](./contract-update-over-revert-on-must-conflict.md)
- [追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない](../patterns/mutation-prove-new-pin.md)

## ソース

- [PR #2498 review results (cycle 5)](../../raw/reviews/20260901T110702Z-pr-2498.md)
