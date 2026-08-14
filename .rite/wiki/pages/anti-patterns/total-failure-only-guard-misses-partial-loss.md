---
type: "anti-patterns"
title: "全滅形だけを想定したガード条件は部分欠損形を必ず取り逃す"
domain: "anti-patterns"
description: "検出器が無言で 0 件を返す事故を塞ぐガードは、つい「1 件も取れていないなら壊れている」という全滅条件で書きたくなる。"
created: "2026-08-01T00:21:06+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260731T005941Z-pr-2070.md"
  - type: "reviews"
    resource: "raw/reviews/20260731T072309Z-pr-2070.md"
  - type: "fixes"
    resource: "raw/fixes/20260731T010916Z-pr-2070.md"
  - type: "fixes"
    resource: "raw/fixes/20260731T080852Z-pr-2070.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-01T00:21:06+09:00" }
---

# 全滅形だけを想定したガード条件は部分欠損形を必ず取り逃す

## 概要

検出器が無言で 0 件を返す事故を塞ぐガードは、つい「1 件も取れていないなら壊れている」という全滅条件で書きたくなる。しかし現実の破損は多くが**部分欠損**（何件かは取れたあとに残りが落ちる）であり、全滅条件はそれを構造的に検出できない。さらに、全滅条件は入力側の些細な性質——配布テンプレートの前文が 1 件だけ述語に一致する、など——で恒久的に発火不能にもなる。

## 詳細

起点事例では同じガードが 2 度作り直された。

1 度目は「`parsed == 0` なら検出失敗」という行数ガードだった。ところが**配布テンプレート自身の前文が entry 述語に一致する**ため、正常系でも必ず 1 件 parse される。ガードは構造的に発火不能で、実データで一度も動かないまま「置いた」ことになっていた。発火条件を「1 件でも失敗」へ緩めるとテンプレートの前文に影響されず機能する。

2 度目は `entries == 0` を採用したが、今度は[ラッチ形式の除外が未閉鎖のまま EOF に達する](./latch-exclusion-without-eof-termination-check.md)部分欠損で破れた。「エントリを 1 件数えた後にラッチが立つ」形では entries>=1 が成立してしまう。最終的な修正は判定をラッチ変数自身に置き、全滅形と部分欠損形の両方を覆った。回帰テストでも、部分欠損形の fixture が「もっともらしい誤った修正（`entries == 0` 併用）」と正しい修正を分ける唯一の assertion になっている。

関連して、**部分欠損を stderr の WARNING だけで扱うと指標の外へ落ちる**。完了レポートの注記条件がファイル単位のカウンタでしか展開されないと、行単位の欠損は「実測済み」として通る。かといって行単位の値をファイル単位カウンタへ足すのも誤りで、`io_error` 判定が「失敗数 == 母数」の算術である場合、1 行の欠損がファイル全体の読出失敗に化ける。独立したフィールドとして出すのが正しい。

**適用条件**: silent-0 / 検出失敗 / 読出失敗を surface するガードの条件を決めるとき。条件を書く前に部分失敗の入力を 1 つ手で作り、その入力でガードが発火するかを実測する。

## 関連ページ

- [開始・終了の対で囲む除外をラッチで実装すると、未閉鎖のまま EOF に達した経路が無音で全行を落とす](./latch-exclusion-without-eof-termination-check.md)
- [ガードの precondition に代理値を使うと、守るべき経路でだけ無効化される](./guard-precondition-proxy-value-silent-where-needed.md)

## ソース

- [PR #2070 review results](../../raw/reviews/20260731T005941Z-pr-2070.md)
- [PR #2070 review results (cycle 2)](../../raw/reviews/20260731T072309Z-pr-2070.md)
- [PR #2070 fix results](../../raw/fixes/20260731T010916Z-pr-2070.md)
- [PR #2070 fix results (cycle 3)](../../raw/fixes/20260731T080852Z-pr-2070.md)
