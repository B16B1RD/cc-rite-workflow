---
type: "anti-patterns"
title: "集合一致 assert の抽出を固定 whitelist にすると「whitelist ∩ 各サイト」しか測れない"
domain: "anti-patterns"
description: "複数箇所が同一の変数集合を指すことを検証する assert で、集合の抽出側を固定 whitelist の alternation で書くと、測っているのは whitelist と各サイトの積集合の一致でしかない。whitelist 外の名前を 1 箇所にだけ足す変異が全 assert を素通りする。"
created: "2026-08-30T15:15:33Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-30T15:15:33Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260830T140538Z-pr-2489.md"
tags: []
confidence: high
---

# 集合一致 assert の抽出を固定 whitelist にすると「whitelist ∩ 各サイト」しか測れない

## 概要

複数箇所が同一の変数集合を指すことを検証する assert で、集合の抽出側を固定 whitelist の alternation で書くと、測っているのは whitelist と各サイトの積集合の一致でしかない。whitelist 外の名前を 1 箇所にだけ足す変異が全 assert を素通りする。

## 詳細

### 失敗の形

「散文の列挙 / bash の if 条件 / gate のループ」の 3 サイトが同一の変数集合を指すことを受入基準に据え、各サイトから変数名を抽出して集合一致を assert した。抽出を `grep -oE 'n_(contradictions|orphans|missing_concept|broken_refs)'` のような**固定 whitelist の alternation** で書いたため、実際に測っていたのは「whitelist ∩ 各サイト」の一致だった。

結果として、whitelist に無い変数名を 1 箇所にだけ足す変異が全 assert を素通りした。しかも当該変数は residue gate のループ変数リストにも無いため runtime backstop も効かず、整数比較の rc=2 が論理和に飲まれて clean 判定が silent emit される経路が残っていた。

### 直し方

抽出を**開いた regex**（`n_[a-z0-9_]+` 相当）にし、混入する別項は capture 範囲を絞って落とす。この形に変えたところ、if 条件のみ / 加算式のみ / suffix 改名の 3 変異がいずれも検出されるようになった（修正前は 3 種とも FAIL=0）。

抽出 regex を開くときは左境界と末尾の数字を両方考える。

| 考慮 | 落とすと何が起きるか |
|---|---|
| 左境界（`(^\|[^a-z0-9_])` 相当） | `min_count` のような語から `n_count` を偽収穫し、診断が原因を指さなくなる |
| 末尾の数字（`[a-z0-9_]+`） | `n_orphans2` が `n_orphans` へ丸まり、一貫改名の変異が不可視になる |

### 除去は位置ではなく名指しで

抽出結果から非項（`{n_warnings}` のような別カテゴリのトークン）を除くとき、「この区切り以降」と位置で範囲を狭めると外側が盲点になる。除去したいトークンが行内で一意なら**名指しで落とす**。whitelist の穴を塞ぐために regex を開いても、同じサイトで位置 narrowing を入れれば別の穴が空く。

### 検証手順

集合一致 assert を書いたら、**whitelist 外・列挙外の名前を 1 箇所にだけ足す変異**を注入して赤くなることを確認する。赤くならないなら、その assert は集合一致ではなく部分集合一致を測っている。

## 関連ページ

- [転記の網羅性は件数一致ではなく集合一致で検証する（件数一致は漏れと余剰が相殺して通る）](../heuristics/transcription-completeness-verified-by-set-equality.md)
- [静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く](../heuristics/static-pin-semantic-allowlist-not-notation-denylist.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)

## ソース

- [PR #2489 fix results (cycle 1) — whitelist 抽出が集合一致 assert を空洞化する](../../raw/fixes/20260830T140538Z-pr-2489.md)
