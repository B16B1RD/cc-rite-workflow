---
type: "heuristics"
title: "新規禁止規則を書く前に、その場所へ書き込む既存経路が書くフィールドの実体を読む"
domain: "heuristics"
description: "「ここに X を書くな」を追加する前に、その場所へ書き込む既存経路を grep で列挙し、各経路が書くフィールドの placeholder 定義文まで読む。意図（スコープ外と決めた）と実体（候補内容の要約）がずれる場合、規則は実体側で判定されるため衝突する。"
created: "2026-08-02T11:59:42+09:00"
updated: "2026-08-02T11:59:42+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260802T020939Z-pr-2084.md"
tags: [documentation, rule-design, cross-file-impact]
confidence: medium
---

# 新規禁止規則を書く前に、その場所へ書き込む既存経路が書くフィールドの実体を読む

## 概要

ドキュメントに「ここに X を書くな」型の規則を追加するとき、その場所へ**書き込む既存経路**が X の形をしたものを書いていれば規則は初日から破られる。規則側だけを見て書くと、自分のワークフローが規則違反者になる。追加前に `grep` で書き込み経路を列挙し、各経路が書く**フィールドの実体**（placeholder の定義文まで）を読む。

## 詳細

### 発生事例（PR #2084 cycle 2）

Issue テンプレート Section 9 に「作業項目を載せるな」を追加した。同時に rite 自身の `/rite:pr-review` ステップ 7.4.3 が Section 9 へ 1 行 append する経路を持っており、その挙動は 2 段で規定されていた:

- ステップ 7.2 の推奨機械決定表: Source B（推奨事項）由来および Hypothetical な Source A の候補を「Decision Log に記録」へ機械的に routing する
- ステップ 7.4.3 の placeholder 定義: `{decision}` は「候補内容の要約、1 文」

つまり append される行の `decision` 欄は **定義上 作業項目の形** で、スコープ外という含意は `{reason}` 欄にしか宿らない。規則の意図（スコープ外と決めた記録は許す）と、書き込み側が実際に生成する文字列（未修正の欠陥の要約）が食い違っていた。

### なぜ「経路の存在」だけでは足りないか

書き込み経路の存在を確認しただけでは、その経路が書く**文字列の形**は分からない。本件では 7.4.3 が Section 9 へ書くこと自体は自明だったが、`{decision}` が何を含むかは placeholder の定義文（別セクション）を読まないと分からない。規則は書かれた文字列の形で判定されるため、経路名の列挙では不十分。

### 手順

1. 規則を書く場所（本件: Issue body の Section 9）を特定する
2. `grep -rn "<その場所の見出し>"` で **書き込む側** を列挙する（読む側と区別する — 読む側は規則に影響されない）
3. 各書き込み経路について、書き込む文字列を組み立てている箇所（placeholder 定義 / テンプレート / heredoc）を読む
4. その文字列が新規則の禁止対象に該当しないかを判定する
5. 該当するなら [規則の軸を言い換える](./reframe-rule-predicate-over-carve-out.md) か、経路側を変えるかを選ぶ

### 補足: 規則が届く先を確認する

生成テンプレートでは、規則を書いた箇所が実際に読み手へ届くかも確認する。本件ではテンプレートの fence 内 HTML コメントが生成された Issue body に載り（実 Issue 58 件で実測確認）、fence 外の `**Rules**:` ブロックは生成器しか読まない。規則を fence 外だけに書くと、Section 9 へ追記する主体（生成済み Issue body を読む）には届かない。

## 関連ページ

- [禁止規則が自分のワークフローと衝突したら、例外条項を足す前に規則の軸を言い換える](./reframe-rule-predicate-over-carve-out.md)
- [state machine を 2 箇所で記述する場合は動作の文字列レベルで同期する](../patterns/state-machine-dual-location-sync.md)

## ソース

- [PR #2084 review results (cycle 2)](../../raw/reviews/20260802T020939Z-pr-2084.md)
