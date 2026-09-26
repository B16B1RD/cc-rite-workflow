---
type: "heuristics"
title: "テスト用の偽コマンドは入力を読み切ってから終了する"
domain: "heuristics"
description: "パイプやプロセス置換から入力を受ける偽コマンドが入力を読まずに終了すると、書き手のプロセスが壊れたパイプに当たる。SIGPIPE で黙って終わるか EPIPE のエラー行を出すかは OS ごとに違うため、stderr を検査するテストが一部の CI ランナーでだけ非決定的に落ちる。"
created: "2026-09-26T08:23:48Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T08:23:48Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T081826Z-pr-3124.md"
tags: []
confidence: high
---

# テスト用の偽コマンドは入力を読み切ってから終了する

## 概要

パイプやプロセス置換から入力を受ける偽コマンドが入力を読まずに終了すると、書き手のプロセスが壊れたパイプに当たる。SIGPIPE で黙って終わるか EPIPE のエラー行を出すかは OS ごとに違うため、stderr を検査するテストが一部の CI ランナーでだけ非決定的に落ちる。

## 詳細

失敗経路を試すために PATH の先頭へ置く偽コマンドは、1 行出力して非ゼロで終わるだけの短いスクリプトになりやすい。本物のコマンドが `cmd <(producer) <(producer)` のようにプロセス置換で入力を受ける場合、偽コマンドが入力を読まずに終わると、producer 側の `sort` などが閉じたパイプへ書き込むことになる。

Linux の GNU sort は SIGPIPE の既定動作で黙って終了するので、Linux の CI では何も起きない。macOS の sort は EPIPE を受けて `sort: stdout: Broken pipe` を stderr に出す。テストが「WARNING の直後の行が原因行であること」のように stderr の並びを検査していると、この行が割り込んで macOS でだけ時々落ちる。Linux の CI が通っていても、修正の前後を区別できるのは macOS ランナーの結果だけである。Linux で再現したいときは SIGPIPE を無視するシェル（`trap "" PIPE`）から起動すると、書き手が EPIPE のエラー行を出す状態を作れる。

対処は、偽コマンドが受け取った入力を EOF まで読み切ってから従来の出力と終了コードを返すことである（`cat "$2" "$3" >/dev/null` など）。書き手はすべて書き終えてからパイプを閉じるので、EPIPE の経路が構造的になくなる。assert を「原因行の集合に含まれるか」へ緩めると検査力が落ちるので、偽コマンド側で競合を消す。偽コマンドの出力と終了コードは変えないため、本物のコマンドの終了コードを見落とす変異や原因行の出力を消す変異は、引き続き同じテストで検出できる。

プロセス置換 `<(...)` の中のコマンドの stderr は、外側のコマンドに付けた `2>file` には入らず、スクリプト全体の stderr に出る。外側のコマンドの stderr だけを集めて原因行として表示する作りでは、producer 自体の失敗メッセージはその原因行に載らない。

偽コマンドは本物の引数の形（`comm -12 A B` なら `$2` と `$3` が入力）に位置で依存する。本物の呼び出し形を変えると偽コマンドの `cat` が失敗し、テストははっきり落ちる。黙って通過する壊れ方にはならない。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T081826Z-pr-3124.md)
