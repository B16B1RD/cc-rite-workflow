---
type: "heuristics"
title: "静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く"
domain: "heuristics"
description: "静的 pin（ソースの文字列を grep して構造を固定するテスト）を「この表記が出現しないこと」として書くと、**同じ意味を持つ別表記が pin を素通りする**。"
created: "2026-08-05T05:30:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260805T043752Z-pr-2112.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T050456Z-pr-2112.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T040912Z-pr-2715.md"
tags: ["test", "static-pin", "allowlist", "mutation", "bash"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-12T04:13:09Z" }
verified:
  - { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-12T04:13:09Z" }
---

# 静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く

## 概要

静的 pin（ソースの文字列を grep して構造を固定するテスト）を「この表記が出現しないこと」として書くと、**同じ意味を持つ別表記が pin を素通りする**。守っているのは性質ではなく、たまたま今そこにある書き方でしかない。

pin は「成立させたい性質」の側から書く。等価な代替構文を allowlist として並べるか、より強く位置不変条件（定義がどこにあるか）で固定する。

## 詳細

### 実測された症状（cycle 3）

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

### 禁止文を含む本文への negative pin は、禁止文を除外してから照合する

契約文書の退路パラグラフに「迂回を許す語彙が出現しないこと」を pin する場面で、本文には既に「helper 内の cd や main checkout への退避で拒否を迂回する経路ではない」という**禁止文そのもの**が含まれていた。禁止文は否定形で許可語彙を名指しするため、本文全体に negative grep を当てると禁止文自身に当たって偽陽性になる。

対処は、禁止文を `sed` で除いた別変数に対して照合し、元の変数と既存の存在 pin は触らないこと。除外が本文全体を消していないことも同時に pin する（除外後に残るべき文言の存在確認）。除外を怠ると negative pin はそもそも置けず、「存在 pin だけで対の負側が無い」状態に戻る。

この場面でも denylist が言い換えを素通りする性質は変わらない。レビューでは「迂回しても構わない」「main checkout 側で実行し直す」といった言い換えが green のまま生存することが実測された。契約側が denylist 方式と限界のコメント化を明示的に要求している場合はそのまま可としつつ、言い換えが実際に混入した時点で語彙を足すのではなく、退路で許容する行動（停止・復旧案内・承認手順）を allowlist として pin する方向へ切り替える。

## 関連ページ

- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](./fixture-mutation-isolates-invariants.md)
- [静的ガードを新設したら、走査面の限界と現存する未カバーサイトをテスト本体のコメントに書く](./static-guard-declare-scan-scope-limits.md)
- [pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する](../patterns/pin-literal-uniqueness-verified-by-mutation.md)

## ソース

- [`declare` / `typeset` で pin を素通りできることを検出](../../raw/reviews/20260805T043752Z-pr-2112.md)
- [静的 pin を allowlist へ反転](../../raw/fixes/20260805T050456Z-pr-2112.md)
- [退路本文への negative pin で禁止文を除外してから照合したレビュー結果](../../raw/reviews/20260912T040912Z-pr-2715.md)
