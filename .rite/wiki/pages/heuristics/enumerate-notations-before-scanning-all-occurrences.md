---
type: "heuristics"
title: "文書中の全箇所を対象にする検査や grep は、書き方の種類を先に列挙してから書く"
domain: "heuristics"
description: "「すべての箇所」を検査するテストや、同じ規範の記述を探す grep は、表記の 1 種類だけを見ると別の書き方の箇所を取りこぼす。inline code と fenced code、言い回しの揺れなど、同じ内容が現れうる書き方を先に列挙してから抽出条件を決める。"
created: "2026-09-29T04:35:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T04:35:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T041314Z-pr-3425.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T042136Z-pr-3426.md"
tags: ["grep", "pin", "fence", "notation"]
confidence: medium
---

# 文書中の全箇所を対象にする検査や grep は、書き方の種類を先に列挙してから書く

## 概要

「すべての箇所」を検査するテストや、同じ規範の記述を探す grep は、表記の 1 種類だけを見ると別の書き方の箇所を取りこぼす。inline code と fenced code、言い回しの揺れなど、同じ内容が現れうる書き方を先に列挙してから抽出条件を決める。

## 詳細

### 抽出の対象から fenced code が漏れる

文書から案内のコマンドを抜き出して「全箇所に必要なオプションが付いているか」を検査するテストが、backtick で囲んだ inline code だけを走査していた。fenced code block の中のコマンド行は検査されず、その行からオプションを外しても suite は green のままだった。2 人の reviewer が同じ根因を独立に報告し、該当行を変異させても落ちないことを隔離した作業ツリーで実測した。文書中のコマンドは inline code にも fenced code にも現れるので、抽出対象を両方にする。変異で落ちることまで確かめると、抽出の漏れが見える。

### 同じ規範が別表記で 2 か所にあり、片方だけ直る

手順書の step 一覧と本文の両方に「件数が 0 なら呼ばない」という規範が書かれていた。本文だけを直したため、step 一覧が食い違ったまま残った。旧表記を探す grep が「対象 0 件」の 1 表記にしか掛からず、「対象 0」という書き方を見落としていた。規範を直す前に、同じ規範が書かれた箇所を表記を変えた複数の grep で列挙する。旧表記が無いことを確かめる pin は、assert を増やさず、既存の否定 assert の正規表現を表記の揺れ（「件」の有無など）に掛かる形へ広げる。旧表記に戻す変異で落ちることを確かめる。

## 関連ページ

- [検出文法が一部の表記だけを見るとき、同じ画面の別表記が検査外に残って整合が壊れたままゲートは通る](../anti-patterns/partial-format-detector-leaves-sibling-tokens-inconsistent.md)
- [静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く](./static-pin-semantic-allowlist-not-notation-denylist.md)

## ソース

- [レビュー結果](../../raw/reviews/20260929T041314Z-pr-3425.md)
- [fix 結果](../../raw/fixes/20260929T042136Z-pr-3426.md)
