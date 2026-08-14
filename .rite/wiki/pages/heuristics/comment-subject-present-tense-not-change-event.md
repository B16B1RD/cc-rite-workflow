---
type: "heuristics"
title: "コメントの主語は「変更イベント」ではなく「コードの現在の性質」に置く — lint が緑でも規約違反は成立する"
domain: "heuristics"
description: "判定形式を変えたとき、その理由を「旧形式は X を受け入れていた」と書くと、コメントの**主語が変更イベント（過去の行為）**になる。"
created: "2026-07-26T01:35:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260725T160402Z-pr-2020.md"
  - type: "fixes"
    resource: "raw/fixes/20260725T160545Z-pr-2020.md"
  - type: "fixes"
    resource: "raw/fixes/20260725T154630Z-pr-2020.md"
tags: ["comment", "journal-comment", "review", "lint", "verification"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-26T01:35:00+09:00" }
---

# コメントの主語は「変更イベント」ではなく「コードの現在の性質」に置く — lint が緑でも規約違反は成立する

## 概要

判定形式を変えたとき、その理由を「旧形式は X を受け入れていた」と書くと、コメントの**主語が変更イベント（過去の行為）**になる。これは変更履歴をコードに残す禁止パターンで、受け皿は commit message body 側にある。同じ情報は現在形の制約文で完全に保持でき、退行防止の価値は落ちない。

さらに、規約が「このサブ分類は regex で機械検出できない」と自ら定めている場合、**lint が 0 件であることは適合の証拠にならない**。機械検出と LLM 判定の分担を規約から読み取らないと、緑を根拠に違反を通してしまう。

## 詳細

### 書き換えの型

```bash
# ❌ 主語が「削除した旧実装」（過去形・変更イベント）
# The old `!= "deny"` form accepted a crash, a timeout, and every output shape
# the hook was never meant to produce, because all of them left the extracted
# decision empty.

# ✅ 主語が「ある書き方が持つ性質」（現在形・条件法）
# A bare `!= "deny"` test cannot express this contract: a crash, a timeout, and
# every output shape the hook never emits all leave the extracted decision empty,
# so they would all pass.
```

失敗クラスの列挙（クラッシュ / タイムアウト / 想定外形式）と機序（抽出値が空になる）は保存され、帰結節 `so they would all pass` が加わって情報量はむしろ増える。語尾だけの言い換えではなく、主語の付け替えが実質になっている。

### 削除したコードを定冠詞で指さない

```
❌ so the substring test is as strict as **the parse** was
✅ so the substring test is as strict as **a `permissionDecision` parse** would be
```

`the parse` は削除済みの抽出処理を指すため、差分を見ない未来の読み手には指示対象が存在しない。**不定冠詞 + 仮定法**に移すと自己完結し、比較対象のフィールド名を明示した分だけ具体的にもなる。

### 判定軸

「コメントの主語が**変更イベント（過去の行為）**か、**コードの現在の性質・制約**か」の一点で判定する。番号・cycle 参照・旧版表現を伴う場合は禁止句リスト由来の機械検出が先に適用され、それらを伴わない散文だけがこの LLM 判定の対象になる（二重 flag はしない）。

### lint 緑は適合の証拠にならない

規約が「本サブ分類は regex で機械検出できないため禁止句リストには含めず、reviewer の LLM 判定（severity MEDIUM）で扱う」と明記している場合、対応する checker の 0 件出力は**設計どおり**であって適合を意味しない。レビュー側は追加コメントを 1 行ずつ主語判定する必要があり、機械検出の結果を根拠に省略できない。

逆に言えば、この種の指摘は「lint に引っかからないから軽微」ではなく、**規約が LLM 判定に委ねた領域そのもの**として扱う。

### 到達不能な例で存在理由を説明しない

コメントに書く「これが無いと何が起きるか」の例が、実際には到達不能なことがある。ある positive control の説明で「不正な入力 JSON が正しい permit と読める」と書いたが、その入力ファイルは直前の生成処理が作っており、失敗すれば errexit で control 到達前に落ちる経路だった。

到達不能な例で存在理由を説明すると、次に読む人が control の役割を誤解し、削除しても安全だと判断しかねない。**実際に捕捉する劣化を mutation testing で確定させてから**コメントに書く。

### コメントのみの変更は md5 で機械証明する

```bash
for rev in HEAD~1 HEAD; do
  git cat-file blob "$rev:$file" | grep -vE '^[[:space:]]*#' | md5sum
done
```

非コメント行の md5 が一致すれば、過去サイクルで承認済みの検証（変異テスト等）をやり直さずに済む。ただし行頭コメントしか除去しないため**行末コメントの変更は取りこぼす**。実 diff の目視確認と併用して初めて bit-exact の証明になる。レビュー側の検証コストが大きく下がるので、コメントのみの変更では commit 前に自分で回しておく。

## 関連ページ

- [状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)](../anti-patterns/stale-historical-comment-after-state-change.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)
- [否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す](../patterns/negative-assertion-positive-control.md)

## ソース

- [PR #2020 review cycle 3 — 旧版表現の検出と lint 緑の非証拠性](../../raw/reviews/20260725T160402Z-pr-2020.md)
- [PR #2020 fix results (cycle 3) — 現在形の制約文への書き換え](../../raw/fixes/20260725T160545Z-pr-2020.md)
- [PR #2020 fix results (cycle 2) — 到達不能な例示の置換と md5 機械証明](../../raw/fixes/20260725T154630Z-pr-2020.md)
