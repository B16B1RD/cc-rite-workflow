---
type: "anti-patterns"
title: "few-shot 例に「実行していない実測」を書く — LLM はもっともらしいコマンドを書く挙動を学習する"
domain: "anti-patterns"
description: "LLM 向け calibration 文書の few-shot 例に、実際には走らせていない再現コマンドと観測結果を書くと、その形がそのまま模倣される。PR #2035 では -H 'Content-Type: application/json' の無い curl で「JSON として parse された」と主張する例を載せ、主張した観測が出ないコマンドを模範として提示していた。調査手順に現れないコマンド結果をアンカーに書かない。"
created: "2026-07-27T10:57:51+09:00"
updated: "2026-07-27T10:57:51+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260727T010154Z-pr-2035.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T011853Z-pr-2035.md"
  - type: "reviews"
    ref: "raw/reviews/20260726T171439Z-pr-2030.md"
tags: []
confidence: high
---

# few-shot 例に「実行していない実測」を書く — LLM はもっともらしいコマンドを書く挙動を学習する

## 概要

reviewer / agent 向けの calibration 文書（finding-examples.md 等）に「実測アンカー付きの良い例」を追加するとき、例に載せる再現コマンドと観測結果を実際には走らせずに書いてしまう anti-pattern。few-shot は**形をそのまま模倣される**ため、「もっともらしいコマンドを書けば実測アンカーを付けてよい」という挙動を学習させる。実測を要求する機構を導入する PR ほど、その機構の few-shot 例で同じ罪を犯しやすい。

## 詳細

### 観測された 2 形態

**1. 主張した観測が出ないコマンドを載せる**

PR #2035 の finding-examples.md で、実測手順として `curl -X POST ... -d '{json}'` を書いたが `-H 'Content-Type: application/json'` が無く、主張した観測結果（JSON として parse され生値が DB に到達する）が実際には出ないコマンドだった。読む側は「この程度の粒度で書けばよい」と受け取り、同じく検証されていないコマンドを生成する。

**2. 調査手順に現れないコマンド結果をアンカーに書く**

例の「調査プロセス」欄に grep と Read しか書かれていないのに、末尾のアンカーには `repro <コマンド> => <出力>` が付いている。読む側は調査手順とアンカーの対応関係を学習しないため、「アンカーは後から書き足すもの」という誤った形を模倣する。

**処方**: 実測アンカーを載せる例では、**調査手順側にも実行ステップを明示する**。あるいはアンカーを外して「実測できないから付けない」例にする。PR #2035 は 5 例のうち 2 例にアンカー + 実測ステップを追加し、残り 3 例は「なぜ実測できないか」を明記して意図的に非アンカー化した。

### 例の主旨との整合も確認する

PR #2030 では「pre-existing で revert test に落ちる」ことが主旨の例に `failing_test` を付けたため、例が自己無効化した（失敗するテストがあるなら pre-existing ではない）。**calibration 文書の修正は、追加する要素が例の主旨と矛盾しないかまで確認する**。

### チェックリスト

few-shot 例に実測アンカーを追加するとき:

1. そのコマンドを実際に走らせたか
2. 走らせた出力をそのまま貼ったか（要約・整形していないか）
3. 例の「調査プロセス」欄にその実行ステップが現れているか
4. 追加したアンカーが例の主旨（pre-existing / スコープ外 / 実測不能）と矛盾しないか
5. アンカーを付けない例には「なぜ付けないか」が書いてあるか

## 関連ページ

- [Enum 拡張時は few-shot example で全 enum 値の使用例を網羅する (calibration coverage gap 防止)](../heuristics/enum-extension-few-shot-coverage-completeness.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](../heuristics/empirical-reproduction-over-invariant-reasoning.md)
- [fix コメント / commit message で hallucinated canonical reference を生成する](./hallucinated-canonical-reference.md)

## ソース

- [PR #2035 fix results (cycle 4)](../../raw/fixes/20260727T011853Z-pr-2035.md)
