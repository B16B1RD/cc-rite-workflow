---
type: "heuristics"
title: "新規テストは、それが実際に生成している出力のうち契約が不変と規定するものを行まるごと固定する"
domain: "heuristics"
promote: rite-plugin
description: "end-to-end で対象を走らせる新規テストは契約出力を既に生成しているので、その場で固定できる。新機能が動いたことだけを assert して不変と規定された既存出力を素通しすると、変異が生存し「テストを足したから網羅した」という誤読が残る。"
created: "2026-08-10T05:20:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260810T040721Z-pr-2227.md"
  - type: "reviews"
    resource: "raw/reviews/20260810T035844Z-pr-2227.md"
  - type: "reviews"
    resource: "raw/reviews/20260810T045310Z-pr-2227.md"
  - type: "reviews"
    resource: "raw/reviews/20260825T111042Z-pr-2357.md"
  - type: "fixes"
    resource: "raw/fixes/20260825T112921Z-pr-2357.md"
  - type: "reviews"
    resource: "raw/reviews/20260826T125608Z-pr-2383.md"
  - type: "fixes"
    resource: "raw/fixes/20260826T131353Z-pr-2383.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-26T22:40:00+09:00" }
verified:
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-25T21:06:14+09:00" }
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-26T22:40:00+09:00" }
---

# 新規テストは、それが実際に生成している出力のうち契約が不変と規定するものを行まるごと固定する

## 概要

end-to-end で対象を走らせる新規テストは契約出力を既に生成しているので、その場で固定できる。新機能が動いたことだけを assert して不変と規定された既存出力を素通しすると、変異が生存し「テストを足したから網羅した」という誤読が残る。固定の範囲は「契約に現れる出力」に限る — 契約に現れない文言まで pin すると、次の正当な言い換えのたびにテストが落ちる。

## 詳細

### 事象

検出条件を変更する PR で、新しい条件が効くことを end-to-end に確かめるテストを追加した。stdout に対する assert は「新しく検出されるようになった件が検出されている」ことを示す 1 本だけだった。

その PR の Issue は、CLI インターフェースと stdout の findings 行形式・件数 sentinel を「不変」と明示していた。新規テストはその出力を実際に生成していたが、assert していなかった。隔離 worktree で findings 行形式と件数 sentinel をそれぞれ壊す 2 変異を入れて走らせたところ、**2 変異とも生存**した。テストは増えていたが、Issue が MUST として名指しした契約は 1 つも守られていなかった。

### なぜこの形で漏れるか

新規テストを書く動機は「新しい振る舞いを確かめる」ことなので、assert の視線は差分側にしか向かない。一方、end-to-end テストは対象を丸ごと走らせるため、**契約出力も同時に生成している**。生成しているのに assert しない、という非対称がここで生まれる。

「テストを足した」という事実が「網羅した」と読める場所は他にもあるが、この形が特に厄介なのは追加コストがほぼゼロな点にある。既に手元にある stdout に対して assert を 1 本足すだけで済むのに、視線が向かないだけで漏れる。逆に言えば、気づけば assert 本数を増やさずに検証力を上げられる — 部分一致の assert を行まるごとの固定へ置き換えるだけでよい。

### 固定する範囲の切り分け

同じ PR で、診断メッセージのラベルがテストに 1 つも pin されない状態で 2 度書き換わり、そのつどスイートは全 green のままだった。文字列は無音で書き換わる。

ではすべての文言を pin すればよいかというと、そうではない。契約（Issue の MUST / 受入基準の Then）に現れない文言まで固定すると、次の正当な言い換えのたびにテストが落ちる。切り分けは次のとおり。

| 出力 | 扱い |
|---|---|
| 契約が「不変」と名指しした出力（findings 行形式・件数 sentinel・CLI の受理する引数） | 行まるごと固定する |
| 契約に現れない診断文言・ラベル | pin しない。網羅的 pin 強化として記録に残し、必要になったときに判断する |

この切り分けを明示的に置いたことで、「無音で書き換わるのは事実だが、それを全部 pin するのが答えではない」という判断が review-fix ループの中で発散しなかった。

### 実行時の確認

追加した新規テストが契約出力を固定できているかは、対象を壊す変異を入れて走らせれば決まる。契約が名指しした出力ごとに 1 変異を作り、全変異が kill されることを確かめる。生存した変異は、そのままテストの穴の座標になる。

なお `--quiet` 付きでしか走らないテストばかりだと、非 quiet の stderr 経路が一度も踏まれない。失敗経路のテストを足すときに `--quiet` を外すと、この穴も同時に埋まる。

### 成功 echo と失敗 WARNING も契約出力である

契約テストが「分岐や見出しが存在すること」だけを grep し、成功時の echo 形状と失敗時の WARNING 全文を pin しないと、それらの行を削除してもスイートは green のまま残る。新規テストは対象を走らせた時点でその出力を既に生成している。契約が不変と規定した成功/失敗の文言は、差分側の assert とは別に行まるごと固定する。

### スタブが本番 CLI と同じ入力軸を区別しないと、実行テストも変異を殺さない

helper の投稿先を PR コメントから関連 Issue コメントへ移す変更で、実行テストは「Issue へ `issue comment` した」ことだけを assert していた。`gh` スタブは lookup URL も `--jq` も無視して同じ JSON を返したため、lookup を PR 番号へ戻す変異・closed Issue の state 判定を無効化する変異が、スイート green のまま生存した。無投稿経路では `pr comment` 否定が落ちていても、0 件 skip で PR へ投稿する変異は検出されなかった。

スタブは本番と同じ入力軸（URL・`--jq`）を区別し、契約が不変と規定したコマンド行は肯定と否定の両方を固定する。静的 grep だけでは closed skip や番号取り違えの回帰を止められない。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [無音失敗を可視化する防御コードには、その防御コード自体を守る失敗パステストを追加する](./defensive-code-needs-its-own-failure-path-test.md)

## ソース

- [PR #2227 fix results](../../raw/fixes/20260810T040721Z-pr-2227.md)
- [PR #2227 review results](../../raw/reviews/20260810T035844Z-pr-2227.md)
- [PR #2227 review results (cycle 3, mergeable)](../../raw/reviews/20260810T045310Z-pr-2227.md)
- [PR #2357 review results](../../raw/reviews/20260825T111042Z-pr-2357.md)
- [PR #2357 fix results](../../raw/fixes/20260825T112921Z-pr-2357.md)
- [PR #2383 review results](../../raw/reviews/20260826T125608Z-pr-2383.md)
- [PR #2383 fix results](../../raw/fixes/20260826T131353Z-pr-2383.md)
