---
type: "heuristics"
title: "bash の signal 挙動は「誰が送るか」「何をしている最中か」で反転する — 条件を揃えない実測は正しい記述を誤りと判定する"
domain: "heuristics"
description: "signal 経路の cleanup を検証・記述するとき、**条件を揃えないまま計測すると結論が反転する**。bash の EXIT trap は untrapped signal で死ぬときも走るため rc と副作用だけを見る assertion は signal handler の有無を判別できず、`kill -SIG $$` と「foreground child 待ちの親へ外部から」では同じ trap 構成でも挙動が変わる。起点事例 ではこの 2 つが順に踏まれ、テストは signal handler 削除 mutant を通し、reviewer は正しい記述を誤りと指摘して次 cycle で撤回した。"
created: "2026-08-06T22:40:00+09:00"
updated: "2026-08-06T22:40:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260806T053845Z-pr-2124.md"
  - type: "fixes"
    ref: "raw/fixes/20260806T055534Z-pr-2124.md"
  - type: "reviews"
    ref: "raw/reviews/20260806T120815Z-pr-2124.md"
  - type: "fixes"
    ref: "raw/fixes/20260806T121439Z-pr-2124.md"
tags: []
confidence: high
---

# bash の signal 挙動は「誰が送るか」「何をしている最中か」で反転する — 条件を揃えない実測は正しい記述を誤りと判定する

## 概要

signal 経路の cleanup を検証・記述するとき、**条件を揃えないまま計測すると結論が反転する**。bash の EXIT trap は untrapped signal で死ぬときも走るため rc と副作用だけを見る assertion は signal handler の有無を判別できず、`kill -SIG $$` と「foreground child 待ちの親へ外部から」では同じ trap 構成でも挙動が変わる。PR #2124 ではこの 2 つが順に踏まれ、テストは signal handler 削除 mutant を通し、reviewer は正しい記述を誤りと指摘して次 cycle で撤回した。

## 詳細

### 落とし穴 1: EXIT trap が signal handler の不在を隠す

bash は untrapped な INT/TERM/HUP で死ぬときも **EXIT trap を実行し、終了コードも 128+signum を返す**。したがって次の assertion は EXIT trap 1 本だけで両方満たされる。

```
INT を送る → rc=130 であること かつ tempfile が消えていること
```

PR #2124 では lib から signal trap 3 行（INT/TERM/HUP）を削除した mutant に対して、テストが**全件 green のまま**通った。

**対処**（どちらか、または両方）:

- child 側で `trap - EXIT` してから `kill -INT $$` する（EXIT trap が効かない状態を作ってから signal を送る）
- `trap -p INT` の出力に cleanup 関数名が現れることを直接 assert する

### 落とし穴 2: 送り手と受け手の状態で結果が反転する

条件を分ける軸は 2 つ。

| 軸 | 選択肢 |
|---|---|
| 誰が送るか | 自プロセスへ `kill -SIG $$` / 外部から親プロセスへ |
| 受けたとき何をしているか | 自身がコマンドを実行中 / foreground child でブロック中 |

`kill -INT $$` を**スクリプト自身が実行する**と bash の default disposition が即座に殺すため rc=130 になる。一方、**foreground child でブロック中に外部から SIGINT が届く**形（hook が `gh api` の応答待ちのときの Ctrl-C）では、EXIT-only の trap 構成は rc=0 を返し**後続命令まで継続実行する**。

PR #2124 cycle 3 で error-handling reviewer は前者だけで計測し「EXIT のみの trap でも中断時に成功を返さない」と主張して正しい記述を誤りだと指摘、cycle 4 で計測方法の誤りに気付いて自ら撤回した。同 cycle に security reviewer が逆方向から「TERM/HUP では EXIT-only でも 143/129 を返すので 3 signal 一括の主張は過度な一般化」と指摘し、**2 人の実測は矛盾せず「主張を SIGINT に限定すれば真」**という形で解決した。

### 再現できる計測手順

cycle 4 の fix が採った形。

1. victim を **background** で起動する
2. victim が `sleep` に入ったことを **marker ファイル**で確認する
3. **外部から** `kill -SIG` を送る
4. `wait` で rc を取る
5. 後続命令が実行されたかを marker で見る

この形で `TERM=143 / HUP=129 / INT=0 かつ INT のみ後続実行` が再現した。片方の条件だけの計測は、正しい記述を誤りと判定させる（cycle 3）か、誤った一般化を見逃す（cycle 1-3）かのどちらかになる。

### 散文側への含意

signal の挙動を主張する散文は、3 signal を一括で述べたくなるが、**成立する範囲は signal ごとに違う**。「中断された run が成功として報告される」は SIGINT に限れば真、TERM/HUP では偽だった。条件を揃えた実測で裏を取ってから限定句を付ける。

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](../patterns/trap-register-before-mktemp.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [一般化した断定は、実装が特殊化されている限り必ず偽になる — 同じ契約を書く複数サイトは最も限定的な表現に揃える](./generalized-claim-false-while-implementation-specialized.md)

## ソース

- [PR #2124 review results](../../raw/reviews/20260806T053845Z-pr-2124.md)
- [PR #2124 fix results](../../raw/fixes/20260806T055534Z-pr-2124.md)
- [PR #2124 review results (cycle 4)](../../raw/reviews/20260806T120815Z-pr-2124.md)
- [PR #2124 fix results (cycle 4)](../../raw/fixes/20260806T121439Z-pr-2124.md)
