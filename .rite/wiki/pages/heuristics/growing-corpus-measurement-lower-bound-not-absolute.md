---
type: "heuristics"
title: "増え続ける corpus の実測値は絶対値ではなく下限 + caveat で書く"
domain: "heuristics"
description: "ドキュメントやコメントに実測値を書くとき、その値が **サイクルごとに増え続ける corpus** から取られたものなら、絶対値のまま書くと確実に陳腐化する。"
created: "2026-08-02T09:53:11+09:00"
updated: "2026-08-02T09:53:11+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260801T170512Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T224211Z-pr-2070.md"
tags: ["stale-measurement", "doc-accuracy", "defect-class-sweep", "hedge"]
confidence: high
---

# 増え続ける corpus の実測値は絶対値ではなく下限 + caveat で書く

## 概要

ドキュメントやコメントに実測値を書くとき、その値が **サイクルごとに増え続ける corpus** から取られたものなら、絶対値のまま書くと確実に陳腐化する。書く前に「この文の荷重を担っているのは **『0 ではない』** ことなのか、**『N である』** ことなのか」を見極める。前者なら下限表記（「N 件以上」「少なくとも N 件」）+ スナップショットである旨の caveat にする。

## 詳細

**過小表示は判断を誤らせる**

PR #2070 の rationale ドキュメントは 3 種のマスクの実測行数を `15 / 1 / 9` と書いていたが、実体は `27 / 3 / 9` に増えていた。特に「1 行」と書かれた項目は実体 3 行で、**最も弱く見える項目を 3 分の 1 に過小表示**していた。この rationale が本来防ごうとしているのは「その機構は 1 行しか守っていないから削ってよい」という判断であり、過小表示はまさにその判断を誘発する。

**同一ファイル内の hedge の混在は drift のサイン**

同じファイルが別の項目には「サイクルごとに増えるため厳密値は持たない」と明記していたのに、片方だけが裸の絶対値だった。**同一ファイル内で hedge の有無が混在していたら、それ自体が drift のサイン**である。片方の書き手は増加を認識していたのに、もう片方に伝播していない。

同型の事例が PR #2070 cycle 1 にもある。log.md / raw/ には「サイクルごとに増えるため厳密値は持たない」と注記しつつ、index.md だけ絶対値 230 を pin していた。merge 前の時点で既に 235 へ drift していた。

**同じ defect class は 1 度にまとめて掃く**

`230 hits` という stale な絶対値は **3 ファイル 6 箇所**にあり、3 サイクルにわたり複数 reviewer が繰り返し観測していた（毎回 nit-noted / 調査推奨として非 blocking 扱い）。1 箇所だけ直すと残りが次サイクルで再浮上する。**同一 PR の追加行で同じ規約違反が複数箇所にあるなら、指摘された 1 箇所ではなく class 全体を掃く**（[[change-sweep-spans-old-vocabulary-and-notations]]）。

**書き方の使い分け**

| 荷重を担うもの | 書き方 |
|---------------|--------|
| 「0 ではない」= 機構が実際に発火している | 「N 件以上」「少なくとも N 件」+ 増加する旨の caveat |
| 「N である」= その値自体が主張の根拠（before/after の delta 等） | 絶対値 + 測定日 + 再測定コマンド |
| 増減する母数に対する比率 | 比率を書き、母数の絶対値は書かない |

delta（差分）は絶対値と違って陳腐化しにくい。「22 → 250 に増えた」は corpus が育っても主張として生き残るが、「250 件ある」は次のサイクルで偽になる。

## 関連ページ

- [暫定注記は対象成果物内の同種表記を全数列挙してから書く](./interim-notice-enumerate-all-stale-references-first.md)
- [状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)](../anti-patterns/stale-historical-comment-after-state-change.md)
- [変更・削除の掃き出しは旧語彙・置換した条件式・別記法トークンまで広げる](./change-sweep-spans-old-vocabulary-and-notations.md)

## ソース

- [PR #2070 review results](../../raw/reviews/20260801T170512Z-pr-2070.md)
- [PR #2070 fix results (cycle 4)](../../raw/fixes/20260801T224211Z-pr-2070.md)
