---
type: "anti-patterns"
title: "集合一致 assert の抽出を固定 whitelist にすると「whitelist ∩ 各サイト」しか測れない"
domain: "anti-patterns"
description: "複数箇所が同一の変数集合を指すことを検証する assert で、集合の抽出側を固定 whitelist の alternation で書くと、測っているのは whitelist と各サイトの積集合の一致でしかない。whitelist 外の名前を 1 箇所にだけ足す変異が全 assert を素通りする。"
created: "2026-08-30T15:15:33Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-10-06T16:50:00+09:00" }
verified:
  - { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-10-06T16:50:00+09:00" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260830T140538Z-pr-2489.md"
  - type: "reviews"
    resource: "raw/reviews/20261006T071032Z-pr-3690.md"
  - type: "fixes"
    resource: "raw/fixes/20261006T071445Z-pr-3690.md"
  - type: "reviews"
    resource: "raw/reviews/20261006T072544Z-pr-3690.md"
  - type: "fixes"
    resource: "raw/fixes/20261006T073134Z-pr-3690.md"
  - type: "reviews"
    resource: "raw/reviews/20261006T073828Z-pr-3690-c3.md"
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

### 同じ型は「走査の対象」と「検査入力」にも現れる

手順書に書かれた抽出パターン（`- **ラベル**[:：] ?(...)` のような式）が全角・半角の両方に一致することを検査するテストで、同じ型が 3 段階で出た。

| 段階 | 空洞化の形 | 直し方 |
|---|---|---|
| 対象の列挙 | 対象ラベルと対象ファイルを固定列挙した。同じ表の隣の行や、同じ表を持つ別スキルが半角専用のまま取り残されても検出できない | 「抽出パターンを書く行すべて」を glob で走査して洗い出し、「半角のみの表記が 0 件」を 1 つの述語で pin する |
| 検査入力 | 検査入力を、検査対象のパターン自身の取り出し部から機械生成した。パターンの前置部（`#` など）を壊しても入力側も同じく壊れるため必ず一致し、変異が素通りした | 入力はラベルごとの固定の現実的な値（番号は `#123`、ブランチは `feat/x` など）で対象と独立に用意し、期待値と比べる。辞書に無いラベルは ng に積んで fail-loud にする |
| 検出条件と下限 | 抽出パターンと数える正規表現の区切りを厳密な 2 形に限り、検出行数の下限を実測に 1 行の余裕を持たせて置いた。`:\s*(.+)` のような半角専用の別表記は走査から無音で落ち、下限も通った | 区切りの表記を問わず `- **ラベル**` で始まる式を拾い、許容形以外を ng にする。バッククォート式だけでなく、raw 文字列で書かれた手本も対象に入れる。下限は実測の件数に合わせる |

前置部を丸ごと削った式は走査が拾えなくなるため ng ではなく行数の下限で検出される。下限は「落ちたら気づく」ための最後の網であり、パターンを足す変更が下限の更新を負う運用で設計意図に沿う。

### 検証手順

集合一致 assert を書いたら、**whitelist 外・列挙外の名前を 1 箇所にだけ足す変異**を注入して赤くなることを確認する。赤くならないなら、その assert は集合一致ではなく部分集合一致を測っている。

走査を一般化した修正の最後にも、前置部の欠落・別表記・半角専用化・手本の半角化・行の削除の変異をコピー先で当て、すべて赤くなることを実測する。静的 pin と行動検証は別々に書かず、同じ走査で「許容形以外が 0 件」と「両字形・空白の有無で同じ値を返す」を一緒に検証すると、パターンの追加に追従できる。実装が受理する形を変えたときは、その形を述べる reference の「この形のみ」という記述も同時に直す。

## 関連ページ

- [転記の網羅性は件数一致ではなく集合一致で検証する（件数一致は漏れと余剰が相殺して通る）](../heuristics/transcription-completeness-verified-by-set-equality.md)
- [静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く](../heuristics/static-pin-semantic-allowlist-not-notation-denylist.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)

## ソース

- [whitelist 抽出が集合一致 assert を空洞化する](../../raw/fixes/20260830T140538Z-pr-2489.md)
- [ラベル行の抽出パターン走査：レビュー結果](../../raw/reviews/20261006T071032Z-pr-3690.md)
- [ラベル行の抽出パターン走査：fix 結果](../../raw/fixes/20261006T071445Z-pr-3690.md)
- [検査入力の独立化と検出条件の一般化：レビュー結果](../../raw/reviews/20261006T072544Z-pr-3690.md)
- [検査入力の独立化と検出条件の一般化：fix 結果](../../raw/fixes/20261006T073134Z-pr-3690.md)
- [走査の再レビュー結果](../../raw/reviews/20261006T073828Z-pr-3690-c3.md)
