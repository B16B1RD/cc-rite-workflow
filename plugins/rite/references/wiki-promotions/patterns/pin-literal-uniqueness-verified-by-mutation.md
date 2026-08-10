---
type: "patterns"
title: "pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する"
domain: "patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/patterns/pin-literal-uniqueness-verified-by-mutation.md"
description: "静的 assert の pin literal がラベルの主張より広い文字列だと、対象行を消す変異が全緑で生存する。pin を足したら (a) 全編集を適用した後に grep -c で hit 数 1 を確認し、(b) 対象行を消す変異を注入して自分の assert がちょうど 1 件 FAIL することを実測する。計測は編集前ではなく編集後に行う — 同一コミットの別修正が literal 自体を増減させるため。marker 契約は producer と consumer を対で pin する。"
created: "2026-08-02T22:05:00+09:00"
updated: "2026-08-05T09:26:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260802T074021Z-pr-2052.md"
  - type: "reviews"
    ref: "raw/reviews/20260802T080828Z-pr-2052.md"
  - type: "fixes"
    ref: "raw/fixes/20260802T082508Z-pr-2052.md"
  - type: "fixes"
    ref: "raw/fixes/20260804T145425Z-pr-2111.md"
tags: ["pin", "mutation-testing", "static-assert", "producer-consumer-symmetry", "drift-detection"]
confidence: high
---

# pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する

## 概要

散文の実行契約を守る静的 assert（pin）は、**張っただけでは守れていない**。pin literal がラベルの主張する契約より広い文字列だと、対象行を消す変異が全緑で生存する。pin を足したときの確認手順は 2 段階あり、どちらも省略できない。

さらに、marker 契約の pin は **producer 側と consumer 側を対で**張らないと守るものが無くなる。

## 詳細

### 失敗の型 1: pin literal が対象行に固有でない

起点事例は同じ失敗を 2 サイクル連続で起こした。

| サイクル | pin literal | SKILL.md 内の hit 数 | 結果 |
|---|---|---|---|
| 4 | `WIKI_INGEST_STATS=aborted` | 2（表の行 + bash ブロック） | 対象行を消しても kill しない |
| 5 | `n_stats_abort` | 5（SKILL.md 内に分散） | 同じ理由で再発 |

`assert_grep` のラベルは「表のこの行が存在すること」を主張しているのに、pin literal は表以外にも一致する。対象行を削除する変異を注入しても、別の箇所が一致して assert は緑のまま通る。

**ラベルの文言を書き換えたら pin literal も追随させる。** ラベルと literal が指す対象がずれると、テストは「何かが存在すること」しか検証しなくなる。

### 手順: 全編集を適用してから計測する

```bash
# (a) 編集をすべて適用した後に hit 数を確認する
grep -cE '<pin literal>' plugins/rite/skills/<skill>/SKILL.md   # => 1 であること

# (b) 対象行を消す変異を注入し、自分の assert がちょうど 1 件 FAIL することを実測
```

**編集前に計測してはならない。** 同一コミット内の別修正が literal 自体を消したり増やしたりするため、数値が stale になる。起点事例では実際に、後続の修正（F-08）が先行修正（F-02）の pin 対象文字列「最後の Raw Source を処理したときにのみ実行」を消していた。

### 失敗の型 2: consumer だけ pin して producer が無 pin

marker 契約（`[CONTEXT] KEY=value` を emit する側と、それを読んで分岐する側）で、**consumer（展開表）の 2 行だけ pin し producer（emit 契約）が無 pin** という非対称が起きた。

producer が消えると、正常サイクルでも「marker なし → ⚠️ 未確認」が毎回誤発火する。consumer の pin は producer の保証なしでは守るものが無い。

**marker 契約を pin するときは emit 側と解釈側を対で pin する。**

### 失敗の型 3: cp fixture は「実体が持たない構造」を pin できない

配布物を `cp` して fixture にするテストは、**実体が変わると pin 対象も一緒に消える**。テスト総数が変わらないため差分レビューでは見えない。

起点事例で実測された例:

- テンプレートに 5 列テーブルを新設したが、テストは前文しか見ていなかった
- ヘッダー列名の改称（`サマリー` → `概要`）も、表ブロックの全削除も、suite 緑のまま通った（PASS:182 FAIL:0）

さらに悪いことに、**同じコミットが「cp fixture は持たない形式を pin できない」という原則を自ら明文化して literal fixture を 1 本追加していた**のに、その原則を自分が追加した構造には適用していなかった。

> 原則を書いた側の変更にこそ、その原則を適用したか確認する。

cp fixture（配布物の回帰検知）と literal fixture（規則そのものの pin）は目的が異なるので**併用し、TC 番号も分ける**。

### 失敗の型 4: pin されている表に行を足すときの非対称

pin 語句を壊して CI を赤にした反省から文言を復元した一方、**同じ表に新しく足した行**には pin が無かった。削除しても全 111 テストが緑のまま通ることが変異注入で実測された。「唯一の下流検出器」と自称する行が無 pin という非対称。

**pin されている表に行を足すときは、その行の pin も同時に足す。**

### fix が追加した TC 自身にも代表変異を当てる（The observed review run cycle 3 fix）

「検出力系 fix は変異の fail 化を実測してから commit する」規律を守っていても、**fix 自身が追加した TC の検出力**は検証対象から漏れやすい。起点事例では cycle 2 で追加した invocation-symmetry TC がフラグ「名」の集合突合のみで「呼び出し行の実体」を pin していない穴が cycle 3 で指摘された。以後は fix が追加した TC にも代表変異（対象行の削除・literal の置換）を当てて kill を実測してから commit する。この検証は cycle 3 fix で TC の診断行に潜んでいた set -u バグ（失敗経路でのみ発火する未エスケープ変数）まで検出した — **fix 前 mutation は修正の妥当性検証であると同時に、その修正が testable かの検証でもある**。

### 散文を書き換える前に pin 依存を全走査する

手順書の散文は実行契約であると同時にテストの検査対象でもある。段落単位で書き直すと、その段落中の文字列を pin していたテストを巻き込んで壊す。

```bash
grep -rn '<特徴的な文字列>' plugins/rite/hooks/tests/
```

起点事例では 14 文字列を事前走査して 2 件が test に依存していることを検出した。一度は事前走査を怠って `outstanding-items-contract.test.sh` の assert 語句を巻き込み削除し、CI を赤にしている。

そのとき pin されていた不変条件は新実装でも成立していたので、**直すべきはテストではなく文言側だった**。テスト側の assert を消して緑にするのは、その Issue の charter が無い限り禁じ手。

### チェックリスト

| 段階 | 確認 |
|---|---|
| pin literal 選定 | 全編集を適用後、`grep -c` で hit 数 1 |
| pin 有効性 | 対象行を消す変異を注入し、自分の assert が 1 件 FAIL |
| marker 契約 | producer（emit）と consumer（解釈）を対で pin |
| fixture 種別 | cp fixture と literal fixture を併用、TC 番号を分ける |
| 表への行追加 | 既存行に pin があるなら新規行にも pin |
| 散文の書き換え前 | 対象段落の文字列で `hooks/tests/` を grep |

## 関連ページ

- assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる — positive control を対で置く (`Wiki provenance: ../anti-patterns/assert-not-grep-vacuous-without-fixture-scope.md`)
- テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する (`Wiki provenance: ../heuristics/fixture-mutation-isolates-invariants.md`)
- 累積対策 PR の review-fix loop で fix 自体が drift を導入する (`Wiki provenance: ../anti-patterns/fix-induced-drift-in-cumulative-defense.md`)

## ソース

- The observed review run fix results (cycle 4) (`Wiki provenance: ../../raw/fixes/20260802T074021Z-pr-2052.md`)
- PR 2052 review cycle 5: pin uniqueness, marker producer/consumer symmetry, guard-induced dead code (`Wiki provenance: ../../raw/reviews/20260802T080828Z-pr-2052.md`)
- PR 2052 fix cycle 5: pin selection after edits, producer/consumer marker pins, emit-point relocation (`Wiki provenance: ../../raw/fixes/20260802T082508Z-pr-2052.md`)
- The observed review run fix results (cycle 3) (`Wiki provenance: ../../raw/fixes/20260804T145425Z-pr-2111.md`)
