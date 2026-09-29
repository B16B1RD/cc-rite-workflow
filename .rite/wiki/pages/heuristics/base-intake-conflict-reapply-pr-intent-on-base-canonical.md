---
type: "heuristics"
title: "base 取り込みの競合は base 側の正本を基準にし、PR の変更意図だけを載せ直す"
domain: "heuristics"
description: "base を取り込んだとき同じ表の行を base と PR の両側が書き換えていたら、base 側の正本の式をそのまま採り、PR が変えたかった点だけを差し替えて解消する。PR の base に対する差分が最小になり、再レビューが確かめる面も最小になる。"
created: "2026-09-27T04:21:02Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T16:54:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T10:30:31Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T16:54:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T041232Z-pr-3204.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T082134Z-pr-3438.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T101550Z-pr-3440.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T162531Z-pr-3452.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T164142Z-pr-3451.md"
tags: []
confidence: medium
---

# base 取り込みの競合は base 側の正本を基準にし、PR の変更意図だけを載せ直す

## 概要

base を取り込んだとき同じ表の行を base と PR の両側が書き換えていたら、base 側の正本の式をそのまま採り、PR が変えたかった点だけを差し替えて解消する。PR の base に対する差分が最小になり、再レビューが確かめる面も最小になる。

## 詳細

PR の作業中に base 側で、PR が触れている表の同じ行を別の変更が書き換えていた。取り込みで競合したときの解き方は 2 通りある。PR 側の行を基準にして base 側の変更を混ぜ込む方法では、取りこぼした base 側の書き換えが、それを巻き戻す変更として PR の差分に紛れ込みうる。レビュアーはそれを PR の変更として読むので、再レビューで新たな指摘の面になる。

実際には base 側の行を正本として丸ごと採り、その上に PR が本来変えたかった点だけを差し替えた。結果として PR の base に対する差分は 1 語になり、再レビューは指摘 0 件で収束した。

判断の軸は「この PR は base に対して何を変えたいのか」である。競合した行の PR 側の版には、PR の意図と、取り込み前の base の古い記述が混ざっている。base 側の版には、取り込み後に正しい記述がすべて入っている。意図だけを取り出して base 側の版へ載せ直せば、古い記述が PR の差分として持ち込まれない。

**末尾追記どうしの競合**: 同じファイルの末尾に両側が別々のブロック（テストなど）を追加した競合は、両方を併存させて解く。共有の後始末（`finally` など、片側のブロックの末尾に付いていたもの）は、併存後に各ブロックが自前で持つ形に補う。確認は、解消後に `git diff <取り込み前>..HEAD` が追加のみ（削除 0 行）であること、両側のブロックが欠落・重複なく並ぶこと、開いた資源が必ず閉じられることで行う。取り込んだ base 側のファイルは本 PR の変更ではないので指摘にせず、本 PR の契約と矛盾しないかだけを Cross-File Impact Check で見る。

**長いループの後に見つかる競合**: review と fix のループが長く続くと、その間に base が進み、mergeable と判定した後の merge の時点で初めて競合が見つかる。サブコマンドを列挙する usage 行や、契約文書の同じ項へ両側が追記した競合は、両側の追加を併記して解ける。取り込みの merge commit の再レビューは、両側の意図が保たれていることと、base 側で入った新しい挙動が PR の経路と干渉しないことを確かめれば足りる。

**独立した追記と仕様衝突を分ける**: 同じ段落への独立した追記は和集合で解ける。一方、同じ判断に対して両側が別の規則を書いた競合は仕様衝突で、勝者を選ばず 2 つの文面を人間に示して判断を仰ぐ。併合後は、取り込み側が足した散文が、この PR で置き場所や仕組みを変えた概念を旧来の言い回しで参照していないかを grep で確かめる。仕様衝突の判断でテストの期待値を変えたら、理由を Decision Log と PR 本文に残す。

**移設した手順の鮮度を 1 回の比較で確かめる**: PR が手順書の bash ブロックを helper の関数へ移していて、base 側がその手順書の散文に新しい手順を足していた場合、競合は散文だけで解ける。移設が古くなっていないかは、base 側の bash ブロックに placeholder の置換を当てたものと helper の関数本体の diff を取れば 1 回の比較で確かめられる。base が bash 本体を変えていなければ移設は古くならない。

## 関連ページ

- [base 取り込み後の再レビューは、同じ差分の再確認ではなく取り込み側との契約整合の確認として指示する](./rereview-after-base-intake-checks-contract-consistency.md)
- [merge で解消した競合のファイルは git show --remerge-diff で求める（diff-tree --cc は clean merge も返す）](../patterns/merge-conflict-resolution-via-remerge-diff.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T041232Z-pr-3204.md)
- [レビュー結果（末尾追記どうしの競合の解消）](../../raw/reviews/20260929T082134Z-pr-3438.md)
- [mergeable 判定後の merge で見つかった競合を解消したレビュー結果](../../raw/reviews/20260929T101550Z-pr-3440.md)
- [仕様衝突を人間の判断へ渡したレビュー結果](../../raw/reviews/20260929T162531Z-pr-3452.md)
- [移設した手順の鮮度を diff で確かめたレビュー結果](../../raw/reviews/20260929T164142Z-pr-3451.md)
