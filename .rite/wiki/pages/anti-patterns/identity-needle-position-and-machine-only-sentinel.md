---
type: "anti-patterns"
title: "同定に使う needle は位置まで固定し、人間が複製できる文字列を使わない"
domain: "anti-patterns"
description: "「この文書は自分が生成したものか」を本文の文字列で判定する場面（update-in-place する PR コメント、生成物の再認識など）では、**needle の一致方法**が破壊的操作の安全性を直接決める。"
created: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260728T090203Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T082625Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T070208Z-pr-2038.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-28T21:30:00+09:00" }
---

# 同定に使う needle は位置まで固定し、人間が複製できる文字列を使わない

## 概要

「この文書は自分が生成したものか」を本文の文字列で判定する場面（update-in-place する PR コメント、生成物の再認識など）では、**needle の一致方法**が破壊的操作の安全性を直接決める。段階的に強化しても、それぞれに固有の抜け道がある。

| 一致方法 | 抜け道 |
|---|---|
| `contains(needle)` | 位置非依存。needle を引用しただけの人間コメントに一致する |
| `endswith(needle)` | **本文全体**の suffix。行頭の `> ` 等の接頭辞を吸収する |
| 最終行の**等値** | 接頭辞を排除できる。ただし verbatim 複製は依然一致する |

`endswith` は「末尾で一致」の実装として自然に見えるが、**suffix 検査と行等値は別物**で、前者は引用・インデント・任意の接頭辞をすべて通す。

## 詳細

### suffix 検査が接頭辞を吸収する

```
$ jq -rn '"## 見出し\n\n> <!-- rite:nbr:v1 -->" | endswith("<!-- rite:nbr:v1 -->")'
true       ← 引用接頭辞 "> " が付いていても true
```

「Quote reply で元コメントを引用した人間のコメント」がこれに該当する。一致すると `PATCH` で人間の本文を丸ごと上書きする。

意図が「最終**行**が X と等しい」なら、行に分割してから等値比較する。

```
split("\n") | map(sub("\r$"; "")) | map(select(test("[^[:space:]]"))) | last
```

末尾の空行は整形で増減しうるので「最終**非空**行」を採るのが実用的。

### needle は機械専用にする

needle が人間可視の文字列（見出しやラベル）だと、手書きのコメントが偶然一致する。**rendered view に現れない機械専用 sentinel**（HTML コメント等）を使うと、意図せぬ一致が構造的に減る。

```
<!-- rite:nbr:v1 -->
```

ただし sentinel を使っても、needle だけでは**同一 author が投稿した文書**を除外できない。author 条件と併せて連言にする。

### 残る限界（本文照合の原理的な天井）

3 条件（author ∧ 1 行目の接頭一致 ∧ 最終非空行の等値）まで強化しても、**記録の raw markdown を verbatim に複製した人間コメント**は一致する。Edit view や API から本文はコピーできるので「人間が書き写す経路が存在しない」とは言えない。

**本文文字列で同定する限り、この残余は消えない。** 消すには同定手段そのものを変える（文書 ID を durable な場所に保持して第一候補にする等）必要がある。needle をさらに厳しくする方向は、起点事例で 4 回試みて毎回別の抜け道が見つかった。

### 併せて起きること: 述語変更は既存データを孤児化する

同定条件を変えると、**旧条件で作られた既存データが silent に対象外になる**。起点事例では sentinel 導入前の記録コメントが孤児化し、新規作成へ縮退して 2 件並ぶ状態になった。

- **migration は述語変更の一部**として設計する
- 孤児化を検出したら observability marker で可視化する。ただし「原因が違えば marker も分ける」— 「旧形式の孤児」と「過去の縮退が生んだ重複」は復旧手順（どちらを消すか）が違うので、件数を合算すると operator を誤った削除対象へ誘導する

## 関連ページ

- [同じ述語を 2 言語で並行実装すると受理集合が環境で割れる](./dual-language-predicate-divergence.md)
- [glob で集合を指すと、集合の増減に silent に追随しない](./glob-set-membership-silent-drift.md)
- [cycle が進んでも findings が減らないときは点修正をやめて構造を疑う](../heuristics/non-converging-review-loop-suspect-structure.md)

## ソース

- [PR #2038 fix results (cycle 3)](../../raw/fixes/20260728T090203Z-pr-2038.md)
- [PR #2038 fix results (cycle 2)](../../raw/fixes/20260728T082625Z-pr-2038.md)
- [PR #2038 fix results](../../raw/fixes/20260728T070208Z-pr-2038.md)
