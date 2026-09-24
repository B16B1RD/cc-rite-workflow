---
type: "heuristics"
title: "同じ設定値を独立した bash 呼び出しで複数回読むなら、不在・読み取り不能の扱いを読み取り箇所ごとに揃える"
domain: "heuristics"
promote: rite-plugin
description: "同じ設定値を別々の bash 呼び出しで読む箇所が複数あると、1 箇所目が出した WARNING は 2 箇所目の無言の既定値化を覆わない。共通 helper へ置換するときに caller ごとに失敗の扱いを変えると片側に無音経路が残るため、設定ファイルの不在は WARNING + 既定値、読み取り不能は ERROR で停止、という分岐を読み取り箇所ごとに揃え、各箇所の告知をテストで固定する。"
created: "2026-09-24T17:20:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-24T17:20:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260924T165521Z-pr-3058.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T170034Z-pr-3058.md"
tags: []
confidence: high
---

# 同じ設定値を独立した bash 呼び出しで複数回読むなら、不在・読み取り不能の扱いを読み取り箇所ごとに揃える

## 概要

同じ設定値を別々の bash 呼び出しで読む箇所が複数あると、1 箇所目が出した WARNING は 2 箇所目の無言の既定値化を覆わない。共通 helper へ置換するときに caller ごとに失敗の扱いを変えると片側に無音経路が残るため、設定ファイルの不在は WARNING + 既定値、読み取り不能は ERROR で停止、という分岐を読み取り箇所ごとに揃え、各箇所の告知をテストで固定する。

## 詳細

### 観測された形

設定ファイルの所在解決を共通 helper へ置き換えた変更で、同じ設定値（レビュー・修正ループの上限）を読む箇所が 2 つあった。片方は helper の rc を見て、不在なら WARNING、読み取り不能なら ERROR を出す形に直された。もう片方（ループの毎サイクルで実行される側）は `2>/dev/null || echo /dev/null` の形で呼んでおり、設定ファイルが無いと何も告げずに既定値で続行した。受入条件を検証するレビュアーが、一時リポジトリと linked worktree で組んだ fixture を実行してこの差を観測し、blocking として挙げた。

### なぜ 1 回の告知で足りると誤るか

スキル本文の fenced bash は、ブロックごとに別の Bash 呼び出しとして実行される。シェル変数も stderr の出力履歴も次のブロックへは渡らない（[SKILL.md 新規セクションでシェル変数を Bash 呼び出し間の値受け渡しに使うと dead code 化する](../anti-patterns/skill-md-shell-var-cross-bash-call-dead-code.md) と同じ仕組み）。そのため「最初の読み取りで検証済みだから、後の読み取りは silent でよい」という判断は、同じ値を毎回読み直している 2 回目以降の読み取りの状態を何も保証しない。1 回目のあとに設定ファイルが消えても、そもそも 1 回目が別経路で飛ばされても、2 回目は何も言わずに既定値へ倒れる。

修正側はこの区別を次のように整理した。「検証済みなので silent」が通るのは、**無効値を何度も告知しない**理由としてだけである。設定ファイルの不在や読み取り不能の告知まで省く理由にはならない。前者は同じ値の再判定で結論が変わらないが、後者は読み取りのたびに状態が変わりうる。

### 対処

- 同じ設定値を読む箇所を全て列挙し、各箇所で helper の rc 分岐を同じ形にする: 不在 = WARNING を出して既定値で続行、読み取り不能 = ERROR で停止
- 共通 helper への置換では、caller ごとの失敗時の扱いを表にして並べる。1 か所だけ `2>/dev/null` や `|| echo <既定>` で握っていれば、それが無音経路になる
- テストは読み取り箇所ごとに WARNING / ERROR を固定する。helper 単体のテストだけでは、caller 側が stderr を捨てる退行を検出できない（[無音失敗を可視化する防御コードには、その防御コード自体を守る失敗パステストを追加する](./defensive-code-needs-its-own-failure-path-test.md)）

## 関連ページ

- [新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される](../anti-patterns/upstream-silent-path-defeats-new-logged-guard.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [SKILL.md 新規セクションでシェル変数を Bash 呼び出し間の値受け渡しに使うと dead code 化する](../anti-patterns/skill-md-shell-var-cross-bash-call-dead-code.md)

## ソース

- [片側の読み取りだけが無音で既定値へ倒れることを観測したレビュー結果](../../raw/reviews/20260924T165521Z-pr-3058.md)
- [読み取り箇所ごとに rc 分岐を揃えた fix 結果](../../raw/fixes/20260924T170034Z-pr-3058.md)
