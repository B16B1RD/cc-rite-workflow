---
type: "heuristics"
title: "レビューループを止めるのは reviewer を減らすことではなく disposition 規則を変えること"
domain: "heuristics"
description: "非実測の文言指摘を毎 cycle 先回りで直すと、その修正が次 cycle のレビュー対象になりループの燃料になる。止める操作は reviewer 数の削減ではなく、「本 PR が既に複数回書き換えた行の文言推敲はスコープ外」と disposition を宣言し、指摘を designated home へ流すこと。"
promote: rite-plugin
created: "2026-09-01T20:30:00+09:00"
generated: { by: "manual/claude-opus-5-5", at: "2026-10-10T02:51:06Z" }
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

**なぜ先回り修正が燃料になるか**: 非実測指摘には designated home がある。fix は非実測（measured=false）の指摘を直さず non-blocking へ移して記録コメントに残し、mergeable 後の NB sweep で採否ゲートが処分を決める（PR 起因として採用（ADOPT）した候補は同じ PR で直し、却下（REJECT）は却下台帳に記録し、Issue を起票するのは PR 以前からある欠陥だけ）。sweep で消化すべき実質的な doc-sync gap と、cycle ごとに湧く文言の推敲は別物で、後者を先回りで直すと次 cycle のレビュー対象を自分で作ることになる。

**やってはいけない止め方**: reviewer 数を削る。これは品質を予算で縛る操作であり、切るべき発散・空転ではなく収束に向かう実サイクルを切っている。

**正しい止め方**: 終端 cycle を宣言し、reviewer への指示に disposition 規則を明示する。

- 「本 PR が既に 2 回以上書き換えた行の文言推敲はスコープ外」
- 「非実測の指摘はその cycle で先回りして直さず、NB sweep の採否ゲートへ渡す。2 回以上書き換えた行の文言推敲は、分類役が却下として却下台帳に記録する」

reviewer の人数と審査の深さは維持したまま、出た指摘の**行き先**だけを変える。

**トレンド判定の「収束中」を額面で読まない**: blocking 件数の推移が `3,0,0,0` で `converging_or_descending` と出ても、毎 cycle の指摘が帰結クラス降格で non-blocking へ落ちているなら、この数列は「指摘が減った」ではなく「降格が効いている」ことの反映である。ブレーカーの機械判定は残しつつ、orchestrator 側は「今 cycle の指摘は前 cycle の修正が原因か」を別途見る。

**scope 判定の基準は cycle の diff ではなく PR の diff**: ある行が base に存在しないなら、それは何 cycle 目に入った行であれ PR のスコープ内である。cycle 単位で scope を判定すると、前 cycle で入った行が永久に「差分外」になり、誰も直せない領域ができる。

## 関連ページ

- [実装が Issue の MUST と原則の両方に挟まれたら、実装を戻さず契約側（Decision Log と AC の例外）を更新する](./contract-update-over-revert-on-must-conflict.md)
- [PR 起因と判定した非 blocking の候補は、同じ PR の fix の計画に入れて直す](./pr-origin-nonblocking-fixed-in-same-pr-plan.md) — 対象が異なる。あちらは採否ゲートが PR 起因の欠陥として採用した候補で、同じ PR で直す。こちらは 2 回以上書き換えた行への非実測の文言推敲で、先回りで直さず却下台帳へ送る
- [追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない](../patterns/mutation-prove-new-pin.md)

## ソース

- [レビュー結果](../../raw/reviews/20260901T110702Z-pr-2498.md)
