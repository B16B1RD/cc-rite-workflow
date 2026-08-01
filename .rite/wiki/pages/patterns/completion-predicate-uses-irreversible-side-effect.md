---
type: "patterns"
title: "中断されうる処理の完了判定は、完了した処理だけが持つ不可逆な副作用を述語にする"
domain: "patterns"
description: "成果物の存在検査は「処理が始まった」ことしか示さない。中断された cross-device mv は宛先に断片を残すため [ -e \"$dst\" ] は真になる。完了判定には rename でも copy+unlink でも成立する不可逆な副作用（source が消える = [ ! -e \"$src\" ]）を使う。bash の trap は foreground コマンド完了まで遅延するため「成功 → フラグ代入」の窓は代入位置を動かしても閉じず、フラグではなく成果物側の性質を見る必要がある。"
created: "2026-08-01T05:40:00Z"
updated: "2026-08-01T05:40:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260801T030530Z-pr-2078.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T032503Z-pr-2078.md"
  - type: "reviews"
    ref: "raw/reviews/20260801T021633Z-pr-2078.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T022733Z-pr-2078.md"
tags: []
confidence: high
---

# 中断されうる処理の完了判定は、完了した処理だけが持つ不可逆な副作用を述語にする

## 概要

signal で中断されうる処理について「完了したか」を判定するとき、成果物の**存在**（`[ -e "$dst" ]`）を証拠に使ってはならない。存在は「処理が始まった」ことしか示さない。中断された cross-device mv は copy 途中で殺されると宛先に壊れた断片を残すため、存在検査は断片に対しても真を返す。

完了の証拠には **完了した処理だけが持つ不可逆な副作用**を使う。mv の場合、rename でも copy+unlink でも「完了したなら source が消えている」が成立し、殺された copy では source が残る。したがって `[ ! -e "$src" ]` が正しい述語になる。

## 詳細

### 存在検査が誤判定する具体形

レビュー結果保存 helper の signal handler で、保存済み判定に `[ -e "$json_path" ]` を使っていた経路が実測で誤判定した。中断された cross-device mv が宛先に 10 バイトの断片を残すと、handler は「JSON は保存済みです」と報告し、下流のレビュー結果提示層が存在しない完全ファイルを参照する。

同 PR のテストは 3 つの中断窓を別々のケースで固定している。

| ケース | 中断位置 | 期待 |
|---|---|---|
| mv 完了後 | mv-err の rm 中 | 保存済み（失敗を宣言しない） |
| mv 完了直後・フラグ代入前 | results-dir 宛 mv の直後 | 保存済み |
| mv 中断・宛先に断片 | 断片を書いて source を残す | 保存失敗を宣言する |
| mv 未実行・宛先が既存 | 同一秒衝突で宛先が先に実在 | 保存失敗を宣言する |

最後の 2 つが、存在検査だけでは区別できない組。

### bash の trap 遅延がフラグ方式を壊す

bash の trap は **foreground コマンドの完了まで遅延する**。したがって

```bash
if mv "$src" "$dst"; then
  json_saved="true"   # ← ここへ来る前に handler が走る窓がある
```

には必ず窓が残る。`json_saved="true"` を then 節の先頭へ動かしても閉じない（trap は then 節のどの文よりも前に走る）。**フラグの代入位置を動かす修正は無効**で、フラグではなく成果物側の性質を見るか、実行の事実を別フラグ（`mv_attempted`）で持って AND を取る必要がある。

収束後の最終形は 3 条件 AND になった。

```
mv_attempted = true   ∧   [ -e "$dst" ]   ∧   [ ! -e "$src" ]
```

`mv_attempted` が要るのは、同一秒衝突で collision 解決を諦めた経路では mv せずに宛先が実在しうるため。この項を落とすと、宛先が先に存在する cycle が「保存済み」と誤報告し、保存されなかった cycle が silent に通る。

### 述語を直したら、その判定を読む下流を全部辿る

同 PR の cycle 5 で、3 条件 AND は正しく判定していたのに**その結論を `json_saved` へ書き戻していなかった**ため、同じ trap が `saved=false` / `JSON_SAVED=false` を emit していた。述語の正しさと sentinel の正しさは別の性質で、後者は「その値を読む consumer が何を案内するか」まで確認しないと検証できない。

### 適用条件

- 対象処理が signal / タイムアウト / プロセス kill で中断されうる
- 中断が部分的な成果物（断片・空ファイル・古い版）を残しうる
- 完了判定の結果を下流が「やり直すか / 失敗を報告するか」の分岐に使う

この 3 つが揃うとき、存在検査は fail-open する。

### AND の項ごとに mutation で pin する

3 条件 AND のうち 1 項を落とす変異が全 assertion を素通りするなら、その項は pin されていない。load-bearing な conjunct は、**その項だけを外すと red になるケース**を専用に用意する。条件 N を pin する fixture は、条件 N 以外をすべて通過する形にする（1 つの fixture で 3 条件を試すと、どれを弱化しても他の条件が拾ってしまい変異が検出できない）。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)
- [Race window probe の identification power: outcome classification で test の真正性を担保する](../patterns/race-window-probe-identification-power.md)

## ソース

- [PR #2078 review results (cycle 4)](../../raw/reviews/20260801T030530Z-pr-2078.md)
- [PR #2078 fix results (cycle 4)](../../raw/fixes/20260801T032503Z-pr-2078.md)
