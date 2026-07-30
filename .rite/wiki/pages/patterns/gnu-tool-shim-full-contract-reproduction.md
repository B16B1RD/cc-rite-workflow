---
type: "patterns"
title: "GNU ツールの代替 shim は exit code だけでなく期限・シグナル範囲まで契約を全部再現する"
domain: "patterns"
description: "GNU timeout 等の代替 shim を書くとき、exit code 契約の一部だけを再現すると呼び出し側の fail-open イディオム（`[ \"$rc\" != \"124\" ] && pass`）と組み合わさって、shim のあらゆる故障が「合格」に化ける。(a) 全 exit code 契約、(b) 依存コマンドの command -v ガードと不在時の明示 fail、(c) fallback 分岐を強制実行する自己テスト、の 3 点セットに加え、docstring が「full contract」を謳うなら保証軸（exit code / 期限 / stdin 継承）を個別に列挙する。"
created: "2026-07-25T07:05:21Z"
updated: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T175144Z-pr-2013.md"
  - type: "reviews"
    ref: "raw/reviews/20260725T032345Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T180733Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T193804Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260725T033607Z-pr-2013.md"
tags: ["shim", "portability", "gnu-bsd", "timeout", "fail-open", "exit-code-contract"]
confidence: high
---

# GNU ツールの代替 shim は exit code だけでなく期限・シグナル範囲まで契約を全部再現する

## 概要

macOS/BSD で GNU ツール（`timeout` 等）が無い環境向けに shim を書くとき、**契約の一部だけを再現すると fail-open になる**。呼び出し側の hang 検出イディオムは典型的に `[ "$rc" != "124" ] && pass` という fail-open 形なので、shim のあらゆる故障（perl 不在の rc 127、シグナル死の rc 0、`die` の rc 255）がすべて「合格」に化ける。起点事例では perl 製 `_timeout` shim について、exit code・整数切り捨て・シグナル範囲・拒否コードの 4 軸すべてで実問題が出た。

## 詳細

### 罠 1: シグナル死を exit 0 に写像する

```perl
exit($? >> 8);   # ← シグナル死が exit 0 になる（GNU は 128+N）
```

`$? >> 8` は正常終了の exit code しか取り出さない。シグナルで死んだ場合 `$?` の下位 8 bit にシグナル番号が入るため、`>> 8` の結果は 0 になる。GNU `timeout` は 128+N を返す契約なので、この写像は「異常終了を正常終了として報告する」。

### 罠 2: 期限（deadline）がプロセスグループに及ばない

`_timeout` の docstring は「reproduces timeout(1)'s full exit-code contract」と宣言していたが、**保証されるのは exit code だけで期限は保証されていなかった**。GNU `timeout` は子を独自プロセスグループに置いてグループへシグナルを送るが、perl シムは直接の子にしか送らないため、**孤児が捕捉パイプを保持すると 1s 期限に対し 30s ブロックする**（実測: GNU 3s vs シム 30s）。ランナーが `$( )` 捕捉に変わったことで、この差が CI job timeout に直結する構造になっていた。

```perl
setpgrp(0, 0);          # 子を独自プロセスグループに置く
kill "TERM", -$pid;     # グループ全体に送る（GNU と同じ範囲）
```

> **規則**: 契約を謳う docstring は、保証する軸（exit code / 期限 / stdin 継承）を **個別に列挙する**。「full contract」と書くなら、契約違反時に何がどこまで壊れるかを実測してから書く。

### 罠 3: 非整数の alarm がタイムアウトを無効化する

perl の `alarm` は整数に切り捨てる。小数秒を渡すと `alarm 0` = **タイムアウト無効**になり、`waitpid` が CI の job 上限までブロックする。非整数は明示的に拒否する。

### 罠 4: 「拒否した」exit code が caller に「成功」と読まれる

perl の `die` は 255 を返す。`_timeout` の caller は全員「124 でない = hang なし」と読む契約なので、`die` による拒否はそのまま silent pass になる。

> **規則**: 拒否・エラーを追加するときは、その exit code が **既存 caller の判定表でどこに落ちるか** を確認し、テスト対象外の専用コード（125 等）を選ぶ。

### canonical な 3 点セット

shim を書くときに必要なのは以下の 3 点で、どれが欠けても fail-open になる:

1. **全 exit code 契約の再現** — 正常・タイムアウト・シグナル死・実行不能の 4 系統すべて
2. **依存コマンドの `command -v` ガードと不在時の明示 abort** — 暗黙の rc 127 に頼らない
3. **shim 自身の自己テストで fallback 分岐を強制実行** — PATH に primary を含めない fixture ディレクトリを作る

特に 3 が決定的なのは、**fallback が blocking CI leg で一度も実行されない**（primary が存在する環境でしか CI が回らない）ためで、テストを書かないと死にコードと同じになる。

### 複製コピーがあるなら drift テストをセットで入れる

`_timeout` は 6 ファイルに inline 複製されていた（5 ファイルが helper を source できない構造）。シグナル契約の修正を 1 コピーだけ直す事故が現実的リスクだったため、関数本体を awk で抽出して byte 一致を assert する drift TC を同じ PR で入れた。対象ファイル一覧は **ハードコードせず** `grep -rl '<定義行>'` による discovery に置換し、「発見件数の下限」と「reference が発見集合に含まれること」も併せて assert する（discovery 自体の破損で vacuous green になるのを防ぐ）。

あわせて、**機械的検査が「複数箇所の同時変更」を要求するなら、その要求を文書に書く**。CONTRIBUTING が「`_test-helpers.sh` が提供し source 時に abort する」としか書いていないと、文書だけを読んで本体を直したコントリビューターが drift TC で落ちる。floor 値のハードコード位置（統合時に触る場所）も含めて書く。

## 関連ページ

- [新設した検証機構が、その機構自身の目的を局所的に打ち消す](../anti-patterns/self-defeating-guard-local-purpose-negation.md)
- [degrade する対象をテストするときは判別子を probe と連動させる](../heuristics/degrade-discriminator-switched-by-probe.md)
- [Canonical helper bypass: 既存集約 helper を bypass して inline 再実装する](../anti-patterns/canonical-helper-bypass.md)

## ソース

- [PR #2013 review cycle 1 — shim の exit code 契約が呼び出し側の fail-open と結合する構造](../../raw/reviews/20260724T175144Z-pr-2013.md)
- [PR #2013 review cycle 3 — deadline がプロセスグループに及ばない問題を実測](../../raw/reviews/20260725T032345Z-pr-2013.md)
- [PR #2013 fix results — shim 3 点セットと複製 drift テスト](../../raw/fixes/20260724T180733Z-pr-2013.md)
- [PR #2013 fix results (cycle 3) — perl alarm の整数切り捨て](../../raw/fixes/20260724T193804Z-pr-2013.md)
- [PR #2013 fix results (cycle 3, 後半) — setpgrp + グループ kill で GNU と同じ範囲にする](../../raw/fixes/20260725T033607Z-pr-2013.md)
