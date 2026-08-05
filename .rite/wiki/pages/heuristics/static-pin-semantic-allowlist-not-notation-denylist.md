---
type: "heuristics"
title: "静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く"
domain: "heuristics"
description: "「変数が local 宣言に含まれていないこと」を pin しても、bash では declare / typeset が同じスコープを作るため、表記を替えるだけで pin を通過したまま欠陥を再導入できる。禁止したい表記を列挙するのではなく、等価な代替構文を allowlist として並べるか、より強く「定義位置が関数の外側であること」のような位置不変条件を固定する。"
created: "2026-08-05T05:30:00+00:00"
updated: "2026-08-05T05:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260805T043752Z-pr-2112.md"
  - type: "fixes"
    ref: "raw/fixes/20260805T050456Z-pr-2112.md"
tags: ["test", "static-pin", "allowlist", "mutation", "bash"]
confidence: high
---

# 静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く

## 概要

静的 pin（ソースの文字列を grep して構造を固定するテスト）を「この表記が出現しないこと」として書くと、**同じ意味を持つ別表記が pin を素通りする**。守っているのは性質ではなく、たまたま今そこにある書き方でしかない。

pin は「成立させたい性質」の側から書く。等価な代替構文を allowlist として並べるか、より強く位置不変条件（定義がどこにあるか）で固定する。

## 詳細

### 実測された症状（PR #2112 cycle 3）

signal trap で回収する tempfile 変数がグローバルであることを守るため、「変数が `local` 宣言に含まれていないこと」を assert する pin を置いた。

bash では `declare` / `typeset` も関数内で同じスコープを作る。`local _x` を `declare _x` に書き換えるだけで、**pin の両半分を通過したまま「関数ローカル化して trap が回収できない」欠陥を再導入できた**。mutation を当てて初めて生存が判明した。

pin の文面は正しく、意図も正しかった。誤っていたのは、意図（関数スコープを作らせない）を実装（`local` という 6 文字）で近似したことである。

### 書き換えの方向

| 弱い pin（denylist） | 強い pin（allowlist / 位置不変条件） |
|---|---|
| `local` を含まない | 関数スコープを作りうるキーワード全体（`local` / `declare` / `typeset`）を対象にする |
| 特定キーワードの不在 | **定義位置が関数の外側であること**を行番号比較で固定する |

位置不変条件のほうが強い。表記の集合は言語やシェルの版で増えうるが、「定義が関数の外にある」は表記に依らず成立する。

### 一般化

- 禁止事項を「今そこにある書き方」で表現した pin は、**表記の言い換えに対してゼロ識別力**になる
- allowlist で書けない（性質を直接表現できない）ときは、denylist であることを明示し、既知の代替表記を列挙したうえで**列挙が非網羅であることをコメントに書く**
- pin を足したら、その場で **表記だけを替える mutation** を当てる。落ちなければ denylist に退化している

### 併せて確認する軸

同じ cycle で、`grep -q` を pin する assertion が「値は含むが位置が違う」形の入力で落ちなかった例も出た。denylist / allowlist の軸とは別に、**位置固定（前方一致 / 最終行の等値）を持つ述語は、位置だけを崩す mutation で識別力を確認する**必要がある。

## 関連ページ

- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](./fixture-mutation-isolates-invariants.md)
- [静的ガードを新設したら、走査面の限界と現存する未カバーサイトをテスト本体のコメントに書く](./static-guard-declare-scan-scope-limits.md)
- [pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する](../patterns/pin-literal-uniqueness-verified-by-mutation.md)

## ソース

- [PR #2112 review results (cycle 3)（`declare` / `typeset` で pin を素通りできることを検出）](../../raw/reviews/20260805T043752Z-pr-2112.md)
- [PR #2112 fix results (cycle 3)（静的 pin を allowlist へ反転）](../../raw/fixes/20260805T050456Z-pr-2112.md)
