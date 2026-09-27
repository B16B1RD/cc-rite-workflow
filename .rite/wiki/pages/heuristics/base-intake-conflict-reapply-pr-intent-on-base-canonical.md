---
type: "heuristics"
title: "base 取り込みの競合は base 側の正本を基準にし、PR の変更意図だけを載せ直す"
domain: "heuristics"
description: "base を取り込んだとき同じ表の行を base と PR の両側が書き換えていたら、base 側の正本の式をそのまま採り、PR が変えたかった点だけを差し替えて解消する。PR の base に対する差分が最小になり、再レビューが確かめる面も最小になる。"
created: "2026-09-27T04:21:02Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T04:21:02Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T041232Z-pr-3204.md"
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

## 関連ページ

- [base 取り込み後の再レビューは、同じ差分の再確認ではなく取り込み側との契約整合の確認として指示する](./rereview-after-base-intake-checks-contract-consistency.md)
- [merge で解消した競合のファイルは git show --remerge-diff で求める（diff-tree --cc は clean merge も返す）](../patterns/merge-conflict-resolution-via-remerge-diff.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T041232Z-pr-3204.md)
