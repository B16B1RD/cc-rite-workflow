---
type: "anti-patterns"
title: "同じ述語を 2 言語で並行実装すると受理集合が環境で割れる — 定義を 1 本に寄せるまで症状は再発し続ける"
domain: "anti-patterns"
promote: rite-plugin
description: "「本文の最終非空行が sentinel と一致するか」のような判定条件を、read 側（lookup の jq）と write 側（投稿前検査の shell）で**別々に実装**すると、同じ意図の述語でも受理する入力の集合が一致しない。"
created: "2026-07-28T21:30:00+09:00"
updated: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260728T093135Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T090203Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T070208Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T081222Z-pr-2038.md"
tags: []
confidence: high
---

# 同じ述語を 2 言語で並行実装すると受理集合が環境で割れる — 定義を 1 本に寄せるまで症状は再発し続ける

## 概要

「本文の最終非空行が sentinel と一致するか」のような判定条件を、read 側（lookup の jq）と write 側（投稿前検査の shell）で**別々に実装**すると、同じ意図の述語でも受理する入力の集合が一致しない。原因は 2 つの独立した軸にある。

- **正規表現エンジンの空白クラスが違う**: jq (Oniguruma) の `[[:space:]]` は locale 非依存で U+00A0 等を空白と見なすが、glibc の `grep -E` は locale と grep 実装（GNU grep / ugrep）に依存する
- **文字除去の範囲が違う**: `sub("\r$"; "")` は行末の CR を 1 個だけ落とすが、`tr -d '\r'` は全 CR を落とす

片側だけ緩いと**人間のコメントを掴んで PATCH 破壊**し、片側だけ厳しいと**次 cycle の lookup が自分の投稿を miss して記録が増殖**する。どちらに倒れても壊れ方が非対称なので、症状から原因を逆算しにくい。

決定的なのは、**コメントに「read/write を対称に保つ」と書いても対称性は一切保証されない**こと。宣言は実装ではない。

## 詳細

### 症状の再発history

述語を 4 回差し替えたが、そのたびに別の抜け道が現れた。

| cycle | 述語 | 破られ方 |
|---|---|---|
| 1 | author ∧ `startswith(marker)` | 同一 author の非引用 marker コメントを PATCH 破壊 |
| 2 | + sentinel の位置非依存 `contains` | 本文途中に sentinel を持つコメントを掴む |
| 3 | + `endswith`（本文全体の suffix） | 行頭 `> ` を吸収し、引用付き末尾 sentinel を掴む |
| 4 | + 最終非空行の等値（**両側を別実装**） | 空白クラスと CR 除去範囲で受理集合が割れる |

cycle 1〜3 は「述語をもう 1 段厳しくする」点修正で、いずれも同型の穴を残した。cycle 4 で初めて「2 実装を並行して持つ構造」が原因だと特定された。

### 実測

CR 除去範囲の乖離は環境非依存に再現する。

```
$ printf 'x\n<!-- rite:nbr:v1 -->\r\r\n' > b.md
$ jq -Rrs 'split("\n")|map(sub("\r$";""))|map(select(test("[^[:space:]]")))|last' < b.md
<!-- rite:nbr:v1 -->^M          ← read は拒否（CR が残る）
$ tr -d '\r' < b.md | grep -E '[^[:space:]]' | tail -n 1
<!-- rite:nbr:v1 -->            ← write は受理
```

write が受理して read が拒否する = helper が自分で投稿したコメントを次 cycle が見つけられない（増殖方向）。

空白クラスの乖離は grep 実装に依存する。同一マシンでも対話 shell（ugrep 7.5.0）と script 経路（GNU grep 3.11）で U+00A0 のみの行の扱いが逆転する。`LC_ALL=C` の追加は**修正にならない** — 発散する codepoint が 4 → 6 に増えて破壊方向が悪化する。

### 対処

**述語定義を 1 本に切り出し、両側がそれを評価する形にする。**

```bash
LAST_CONTENT_LINE_JQ='def last_content_line:
  (. // "") | split("\n") | map(sub("\r$"; "")) | map(select(test("[^[:space:]]"))) | last // "";'

# read (lookup)
jq -r --arg sentinel "$RECORD_SENTINEL" "$LAST_CONTENT_LINE_JQ"' ... '

# write (本文検査) — 同じ定義を評価する
_body_last_line=$(jq -Rrs "$LAST_CONTENT_LINE_JQ"' last_content_line' < "$CONTENT_FILE")
```

2 実装が存在しない以上、**同値性は検証項目ではなく構造的な帰結**になる。jq が既に hard dependency なら実装コストも増えない。

### 判断の分かれ目

「2 実装を維持して locale を固定する」は解にならない。locale 固定は乖離を縮めるだけで消せず（U+00A0 はどの locale でも一致しない）、grep 実装差という第 2 の軸が残る。同じ repo の `control-char-neutralize.sh` が「grep 実装差で検出が環境依存に silent に壊れる」ことを理由に grep の使用を明文で禁じており、その規約とも整合する。

### 一般化

- 同じ判定を 2 箇所に書くとき、**言語やツールが違うなら受理集合は原則一致しない**と考える
- 「対称に保つ」「同一述語」と書いた時点で、**それを機械で担保する層があるか**を問う。無ければコメントは願望
- 症状を潰す修正が複数 cycle 続いたら、述語を強化するのをやめて**実装が何本あるか**を数える

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [cycle が進んでも findings が減らないときは点修正をやめて構造を疑う](../heuristics/non-converging-review-loop-suspect-structure.md)
- [同定に使う needle は位置まで固定し、人間が複製できる文字列を使わない](./identity-needle-position-and-machine-only-sentinel.md)

## ソース

- [PR #2038 fix results (cycle 4)](../../raw/fixes/20260728T093135Z-pr-2038.md)
- [PR #2038 fix results (cycle 3)](../../raw/fixes/20260728T090203Z-pr-2038.md)
- [PR #2038 fix results](../../raw/fixes/20260728T070208Z-pr-2038.md)
- [PR #2038 review results (cycle 2)](../../raw/reviews/20260728T081222Z-pr-2038.md)
