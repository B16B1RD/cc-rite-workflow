---
type: "patterns"
title: "2 つの値が一致することの assert は、その値の書式を pin しない"
domain: "patterns"
description: "「ログの `ts` と state file の `updated_at` が一致すること」だけを見る assert は、**両者が同じ変数由来である限り、書式を何に変えても通り続ける**。"
created: "2026-08-06T02:49:27Z"
updated: "2026-08-06T02:49:27Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260806T010533Z-pr-2120.md"
tags: []
confidence: high
---

# 2 つの値が一致することの assert は、その値の書式を pin しない

## 概要

「ログの `ts` と state file の `updated_at` が一致すること」だけを見る assert は、**両者が同じ変数由来である限り、書式を何に変えても通り続ける**。PR #2120 cycle 3 で、ログの唯一の想定 consumer が時刻を parse する予定であるにもかかわらず、書式を epoch 秒へ変える mutation が全 assert を素通りした。一致は provenance（同じ供給元から来たこと）を示すが、形式を保証しない。

## 詳細

### なぜ通ってしまうのか

相互一致 assert が実際に検証しているのは「2 箇所が同じ供給元から書かれた」という provenance だけである。供給元を 1 箇所変えれば両側が同時に変わるため、一致は維持される。

```
✗ assert_equal "$log_ts" "$state_updated_at"
   → date の書式を +%s に変えても両方 epoch になり PASS
✓ assert_match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$log_ts"
   + assert_equal "$log_ts" "$state_updated_at"
   → provenance と書式の両方を pin する
```

**契約が 2 つある（provenance と形式）なら assert も 2 つ要る。** 片方の assert がもう片方を含意すると考えるのは、供給元が共通である限り成り立たない。

### 判別手順

新しい assert を書いたら、**その assert を通したまま壊せる実装変異が存在するか**を問う。存在するなら、その変異が壊す性質は別途 pin されていない。

本ケースの判別は「日付書式を変える mutation」1 回で済んだ。書式に依存する consumer が存在する（または将来存在する）ことが分かっているなら、その依存を直接 assert に落とす。

### 同型の失敗 — 恒真になる「前提条件の確認」assert

同 PR の cycle 2 では、「分岐が実際に走ったことの確認」assert が **いかなる実装変異でも FAIL しない恒真式**だった。前提（占有ファイルの存在）を作るのがテスト自身だったためである。しかも付随コメントが「これがないと上の assert が vacuous になる」と主張していたので、読み手には vacuity guard に見えた。実際の vacuity リスク（state root が別ディレクトリへ解決する）ではこの assert は PASS のままで、検知していたのは隣の assert だった。

**「前提が成立していること」を assert に書く前に、その前提を壊す実装変異が存在するかを問う。** 存在しないなら恒真であり、assert ではなくコメントで足りる。存在するなら、その変異を実際に当てて FAIL することを確認する。

恒真 assert の害は単に無駄なことではなく、**「網羅性の外観」を作る**ことにある。テストファイルを読むと該当セクションが充実して見えるため、本物の穴が隠れる。

### 一般形

| assert の形 | 実際に pin しているもの | 追加で必要な assert |
|---|---|---|
| 2 値の一致 | provenance（共通の供給元） | 形式・値域そのもの |
| 前提条件の成立 | （前提をテストが作るなら）何も pin しない | 前提を壊す変異が存在するなら、その変異での FAIL |
| 出力に X が含まれない | grep が読める範囲での不在 | ロケール・エンコードを跨いだ不在 |

いずれも共通の判定法は同じ: **新規 assert を書いたら対応する mutation を当て、その assert だけが FAIL することを確認する。** 落ちなければ pin ではなく装飾である。

## 関連ページ

- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [否定アサーションは前提条件の床がないと vacuous になる](../anti-patterns/negative-assertion-vacuous-without-precondition-floor.md)

## ソース

- [PR #2120 fix results (cycle 3)](../../raw/fixes/20260806T010533Z-pr-2120.md)
