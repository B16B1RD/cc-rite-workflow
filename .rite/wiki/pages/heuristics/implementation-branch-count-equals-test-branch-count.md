---
type: "heuristics"
title: "実装が分岐しているならテストも分岐の数だけ要る — 既定構成の経路こそ抜けやすい"
domain: "heuristics"
description: "同じ機能が構成（branch_strategy 等）ごとに別実装を持つとき、片方のカバレッジは他方を担保しない。しかも抜けるのは非既定側ではなく既定側になりやすい。過去のレビュー事例では存在プローブが git cat-file -e と [ -f ] の 2 実装で、テストは非既定の same_branch だけを pin しており、既定側のプローブを丸ごと潰しても 148 assertion が全緑だった。「構成で保証する」と決めた設計判断は、構成 pin の網羅性そのものが担保になるため、分岐数と pin の本数が一致するかを明示的に数える。"
created: "2026-08-01T00:21:06+09:00"
updated: "2026-08-01T00:21:06+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260731T064414Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260731T072309Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260731T065426Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260731T073514Z-pr-2070.md"
tags: []
confidence: high
---

# 実装が分岐しているならテストも分岐の数だけ要る — 既定構成の経路こそ抜けやすい

## 概要

同じ責務が設定値によって別実装に分かれているとき（`separate_branch` と `same_branch`、`git cat-file -e` と `[ -f ]` など）、片方のテストは他方を一切担保しない。直感に反して**抜けるのは非既定側ではなく既定側**になりやすい。fixture を作るとき手元で動かしやすい構成を選ぶためである。結果として「テストはある」のに本番既定経路が無防備、という状態が緑のまま維持される。

## 詳細

起点事例では 2 段階で同じ形が現れた。

- 追加した 11 TC はすべて `same_branch` 経路のみを通り、本番既定の `separate_branch` 経路は存在プローブを no 固定に変異させても 97 PASS のまま緑だった。
- 後の cycle でも存在プローブが `git cat-file -e`（既定側）と `[ -f ]`（非既定側）の別実装で、pin は非既定側だけ。既定側のプローブを丸ごと潰しても 148 assertion が全緑だった。

この問題は「構成で保証する」型の設計判断と特に相性が悪い。Decision Log が「非回帰は測定ではなく構成（この行を変更しないこと）で保証する」と宣言して測定テストを省く判断は妥当なことがあるが、**その瞬間に担保の根拠は構成 pin の網羅性そのものへ移る**。起点事例では pages_list が branch_strategy ごとに 2 経路で組まれていたのに静的 pin は 1 経路分しかなく、pin していない側への変異が全 assertion 緑のまま通っていた。構成論で測定を省くなら、**構成の分岐数と pin の本数が一致するかを明示的に数える**こと。

さらに、構成保証は一度は測定で裏づけるべきである。起点事例の cycle 5 で application reviewer が初めて実 wiki 313 ページに対し develop / HEAD の両版を走らせ、per-page marker 行の byte 一致を確認した。5 cycle を経てようやく構成論の前提が測定で確かめられた形になった。

関連して、**「移行に耐える」ための行単位分岐は混在 fixture が無いと守られていることを検証できない**。producer と現行データが別形式のとき（テンプレートは箇条書き、稼働 wiki はテーブル）、移行期の 1 ファイル内混在は仮定ではなく必然である。単一形式の fixture を何本並べても、形式判別をファイル単位へ寄せる変異は kill できない。Decision Log に「〜にも耐える」と書いたら、その「〜」そのものを 1 本の fixture にする。

**適用条件**: 設定値・戦略で実装が分岐する機能にテストを書くとき。既定構成側から先に書く。

## 関連ページ

- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](./mutation-testing-measures-assertion-strength.md)
- [却下理由が採用案にも等しく当てはまる — differentiator でない根拠をコメントに残す](../anti-patterns/rejected-rationale-applies-to-adopted-option.md)

## ソース

- [PR #2070 review results (cycle 1)](../../raw/reviews/20260731T064414Z-pr-2070.md)
- [PR #2070 review results (cycle 2)](../../raw/reviews/20260731T072309Z-pr-2070.md)
- [PR #2070 fix results (cycle 1)](../../raw/fixes/20260731T065426Z-pr-2070.md)
- [PR #2070 fix results (cycle 2)](../../raw/fixes/20260731T073514Z-pr-2070.md)
