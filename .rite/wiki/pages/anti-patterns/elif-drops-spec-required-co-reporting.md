---
type: "anti-patterns"
title: "仕様が「A のとき報告・B のとき併記」を別々に定めている箇所を elif で書くと A ∧ B で B が消える"
domain: "anti-patterns"
promote: rite-plugin
description: "2 つの述語が独立に成立しうるのに実装で elif を使うと、両方が成立する入力で後段の報告が構造的に出せなくなる。A のみ・B のみのテストは両方 green のままなので、組合せ fixture がないと検出できない。"
created: "2026-08-11T01:20:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260810T134712Z-pr-2231.md"
  - type: "fixes"
    resource: "raw/fixes/20260810T135452Z-pr-2231.md"
  - type: "fixes"
    resource: "raw/fixes/20260829T194742Z-pr-2468.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-30T05:20:00Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5"
    at: "2026-08-30T05:20:00Z"
---

# 仕様が「A のとき報告・B のとき併記」を別々に定めている箇所を elif で書くと A ∧ B で B が消える

## 概要

2 つの述語が独立に成立しうるのに実装で `elif` を使うと、両方が成立する入力で後段の報告が構造的に出せなくなる。A のみ・B のみのテストは両方 green のままなので、組合せ fixture がないと検出できない。

## 詳細

### 起点

spawn spread 検出 helper が「直列化を検出したとき WARNING」と「起動時刻が一部欠落しているとき WARNING で併記」を `if / elif` で書いた。仕様は §4.5 で「一部欠落 → 判定は実施し併記」と明記していたが、実装は 2 つの状態を排他として読んだ。直列化と欠落が同時に成立する cycle では、欠落の WARNING が出ない。

### なぜ通常のテストで落ちないか

`elif` は A のみ・B のみのケースをどちらも正しく処理する。落ちるのは A ∧ B だけで、その組合せを明示 fixture にしていなければ全ケース green になる。「3 帰結それぞれの単独ケースを固めた」という網羅の主張が、帰結を跨ぐ組合せを含まない形で成立してしまう。

### 判定基準

**仕様の文が「A のとき」「B のとき」と別々の条件節で書かれているなら、実装も独立した `if` にする。** `elif` が正しいのは、仕様自身が「A でなければ B」と排他を明示している場合だけ。

仕様側の語彙が手がかりになる:

| 仕様の書き方 | 実装 |
|---|---|
| 「A のとき X」「B のとき Y」（別条項） | 独立した `if` を 2 つ |
| 「A のとき X、そうでなく B のとき Y」 | `if / elif` |
| 「A かつ B のとき両方報告」「併記する」 | 独立した `if`。`elif` を書いた時点で違反 |

### 併記を独立させたあとに残る第二の問題

`elif` を独立 `if` に分けると、今度は**出力の順序**と**出力件数の宣言**が問題になる。同じ修正で、marker が WARNING より先に出る経路が生まれ、docstring の「WARNING 1 行」が実挙動（最大 2 行）と食い違った。

対処は分岐を増やす方向ではなく、**判定結果を変数へ畳んで最後に 1 本だけ emit する**形。これで (a) ほぼ同一の emit 行が 1 つになり、(b) marker が WARNING より先に出る経路が構造的に消え、(c) docstring が例外なしの 1 文で書ける。3 つの指摘が 1 つの単純化で同時に消えた。

```bash
# 弱い: 排他 + emit 分散
if [ "$serialized" = true ]; then
  echo "WARNING: ..." >&2
  echo "[CONTEXT] KEY=serialized" >&2
elif [ "$missing" -gt 0 ]; then
  echo "WARNING: ..." >&2          # 直列化と同時のときここへ来ない
  echo "[CONTEXT] KEY=parallel" >&2
fi

# 強い: 独立した if で WARNING を出し切り、marker は最後に 1 本
verdict=""
if [ "$serialized" = true ]; then
  echo "WARNING: 直列化..." >&2; verdict=serialized
elif [ "$missing" -gt 0 ]; then
  verdict=parallel
fi
if [ "$missing" -gt 0 ]; then
  echo "WARNING: ${missing} 名が計測不能..." >&2   # 併記が独立に出る
fi
[ -n "$verdict" ] && echo "[CONTEXT] KEY=$verdict; ..." >&2
```

### 同型: `elif` guard が兄弟ブロックごと `else` に押し込む

同じ形が**テストコード側**でも起きる。不在チェックの guard を `elif` で足したとき、後続の
検査ブロック全体が `else` 側に入っていると、その guard が発火した瞬間に**無関係な兄弟 assert が
まるごと skip される**。実測では 171 PASS が 131 PASS に落ちた。suite は赤になるので gate としては
機能するが、失われるのは診断粒度で、「どの検査が落ちたか」が見えなくなる。

このケースの根治は分岐の組み替えではなく **guard を消すこと**だった。呼び出す helper
（`assert_grep`）が既に file-not-found を fail-loud に扱っているなら、呼び出し側の不在チェックは
重複防御であり、その重複が兄弟 assert を巻き込む唯一の理由になっている。

**ヘルパー側が既に fail-loud に扱う条件を、呼び出し側で二重に guard しない。**

### テスト側の含意

**帰結を跨ぐ組合せを明示 fixture で固定する。** 3 帰結の各単独ケースを固めただけでは不足で、少なくとも「A ∧ B」と「入力の構造破壊」の 2 つは別 fixture を作る。単独ケースが全部 green であることは、組合せが正しいことの証拠にならない。

## 関連ページ

- [排他性を pin するテストは件数固定に加えて配置を両方向で固定する（在る側と無い側の 2 assert）](../patterns/placement-pin-requires-both-directions.md)
- [同じ機構への N 回目のパッチは、その機構が依拠する述語が proxy である信号](../heuristics/nth-patch-signals-proxy-predicate.md)

## ソース

- [レビュー結果](../../raw/reviews/20260810T134712Z-pr-2231.md)
- [fix 結果](../../raw/fixes/20260810T135452Z-pr-2231.md)
- [NB sweep results（テスト側の `elif` guard が兄弟 assert 40 件を skip させた同型事例）](../../raw/fixes/20260829T194742Z-pr-2468.md)
