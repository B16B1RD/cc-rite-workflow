---
type: "heuristics"
title: "文書中の全箇所を対象にする検査や grep は、書き方の種類を先に列挙してから書く"
domain: "heuristics"
description: "「すべての箇所」を検査するテストや、同じ規範の記述を探す grep は、表記の 1 種類だけを見ると別の書き方の箇所を取りこぼす。inline code と fenced code、言い回しの揺れなど、同じ内容が現れうる書き方を先に列挙してから抽出条件を決める。"
created: "2026-09-29T04:35:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T04:44:52Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T04:44:52Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T041314Z-pr-3425.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T042136Z-pr-3426.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T042705Z-pr-3425.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T042643Z-pr-3426.md"
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

### 抽出を直したら、件数の下限と陽性対照もそろえる

fenced code の取りこぼしを直すときは、抽出を inline code とコマンド行の和集合にするだけでなく、抽出件数の下限を文書にある実数へ合わせる。下限が実数より小さいままだと、抽出がまた一部を落としても件数検査は通る。そのうえで、取りこぼしていた行から該当のオプションを外す変異を当て、テストが落ちることを確かめる。

外すと失敗するはずの形（陽性対照）は、終了コードが非ゼロであることだけでなく、**期待した理由で失敗したこと**まで確かめる。起点事例ではオプションを外した git コマンドが「ブランチが別の worktree で使用中」という理由で拒否されることを、そのメッセージで照合した。終了コードだけでは、パスの衝突など別の理由の失敗でも陽性対照が成立したように見える。英語の拒否文言を読むときのロケール固定と照合の絞り方は、関連ページの locale 依存の項を参照。

陽性対照のためにテストが作る一時 worktree は、スイートの EXIT trap に登録済みの一時ディレクトリの配下に置く。途中で終了しても残骸が残らず、個別の後始末を足す必要もない。

### 否定 pin の解消検証と、正の pin を主にする理由

旧表記が無いことを確かめる否定 pin は、修正前の版に対して grep が 1 件ヒットし、HEAD で 0 件になることを実測すると、pin が空振りしていない（非 vacuous である）ことを強く示せる。ただし否定 pin は 1 つの語形しか禁じないので、別の語形で同じ規範が書き戻されても捕まえない。語形を足し続けるより、規範文そのものが存在することを見る正の pin を主にし、否定 pin の語形拡張は補助にとどめる。別語形の混入が実際に観測されるまでは、否定 pin の拡張に手を広げない。

## 関連ページ

- [検出文法が一部の表記だけを見るとき、同じ画面の別表記が検査外に残って整合が壊れたままゲートは通る](../anti-patterns/partial-format-detector-leaves-sibling-tokens-inconsistent.md)
- [静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く](./static-pin-semantic-allowlist-not-notation-denylist.md)
- [absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する](../patterns/absence-pin-base-present-head-absent-single-line.md)
- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](../anti-patterns/locale-dependent-error-message-grep-assertion.md)

## ソース

- [レビュー結果](../../raw/reviews/20260929T041314Z-pr-3425.md)
- [fix 結果](../../raw/fixes/20260929T042136Z-pr-3426.md)
- [抽出を和集合にし陽性対照を理由まで照合した fix 結果](../../raw/fixes/20260929T042705Z-pr-3425.md)
- [否定 pin の解消検証と正の pin を主にする判断のレビュー結果](../../raw/reviews/20260929T042643Z-pr-3426.md)
