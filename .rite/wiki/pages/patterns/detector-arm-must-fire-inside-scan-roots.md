---
type: "patterns"
title: "検出器に arm を足したら、走査根の中で実際に発火するかを実測で確かめる"
domain: "patterns"
description: "positive control は arm 単体との照合なので、走査根の外にしか実例が無い arm でも通る。arm を足したら修復前 tree に対する per-arm ヒット数を測り、0 なら arm を削るか走査根を届かせるかを決める。"
created: "2026-09-04T16:20:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-04T16:20:00+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260904T064259Z-pr-2548.md"
  - type: "fixes"
    resource: "raw/fixes/20260904T064911Z-pr-2548.md"
  - type: "reviews"
    resource: "raw/reviews/20260904T070318Z-pr-2548.md"
tags: []
confidence: high
---

# 検出器に arm を足したら、走査根の中で実際に発火するかを実測で確かめる

## 概要

positive control は arm 単体との照合なので、走査根の外にしか実例が無い arm でも通る。arm を足したら修復前 tree に対する per-arm ヒット数を測り、0 なら arm を削るか走査根を届かせるかを決める。

## 詳細

検出器のテストは 2 つの独立した検査を持つことが多い。1 つは arm ごとの positive control（サンプル文字列を arm 単体の正規表現に当てる）、もう 1 つは全木走査（宣言した走査根の下を検出器で舐めて 0 件を確認する）。この 2 つは同じ arm を見ているように読めるが、**前者は走査根を通らない**。

そのため「positive control は通るが、全木走査では 1 度も発火しない arm」が成立する。実例が走査根の外にあるとき、テストは green のまま arm が死ぬ。実測例では、追加した 5 arm のうち 1 本の実例が `.gitignore` にしかなく、走査根が `plugins/rite` と `docs` の 2 つだったため、その arm のヒット数は 0 だった。他の 4 arm は既存 arm が捕捉できていなかった 19 行を新規に捕捉していたのと対照的で、テスト結果からはこの非対称が読めない。

判定に使う観測値は **修復前の tree に対する per-arm ヒット数**である。走査根と同じ除外条件を適用したうえで arm を 1 本ずつ当て、件数を出す。0 なら 2 択になる。

- **arm を削る**: その残骸形が走査根の中に存在しないなら、arm は将来に備えた構造でしかない。同ファミリの別変種を既存 arm が拾えているなら特に不要。
- **走査根を届かせる**: 実例が走査根の外の特定ファイルにあり、そのファイルも保護対象なら、走査根に加える。加えたあと再度 per-arm ヒット数を測り、修復前で発火し修復後で 0 になることを両方向で確認する。

走査根を広げる側を選ぶときは、広げた根に対して**全 arm**を当て直す。1 本の arm のために根を足すと、他の arm がその根で誤検出することがある。実測例では 38 arm すべてが base 1 ヒット / HEAD 0 ヒットで、誤検出は無かった。

この検査は「検出範囲を広げる修正は上限も pin する」と対になる。上限の pin は arm が広すぎないことを守り、per-arm ヒット数は arm が届いていることを守る。どちらか一方だけでは、広すぎる arm か届かない arm のどちらかを通す。

## 関連ページ

- [検出範囲を広げる修正は「広がった」と「広がりすぎていない」を対で pin する](./detector-widening-pins-both-bounds.md)
- [検出器が「走査できなかった」を「問題なし」に畳むと、ガードが黙って無検査になる](../anti-patterns/checker-conflates-unscannable-with-clean.md)
- [静的ガードを新設したら、走査面の限界と現存する未カバーサイトをテスト本体のコメントに書く](../heuristics/static-guard-declare-scan-scope-limits.md)

## ソース

- [番号除去で壊れた文の修復と deletion-damage scanner の arm 追加（レビュー結果）](../../raw/reviews/20260904T064259Z-pr-2548.md)
