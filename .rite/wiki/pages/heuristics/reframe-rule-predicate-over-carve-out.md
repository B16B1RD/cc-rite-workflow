---
type: "heuristics"
title: "禁止規則が自分のワークフローと衝突したら、例外条項を足す前に規則の軸を言い換える"
domain: "heuristics"
promote: rite-plugin
description: "新設した禁止規則が既存の自動書き込み経路と衝突したとき、カーブアウト条項を足すより、禁止対象の切り出し方（モノの種類 vs 性質）を変えるほうが安い。例外リストは経路が増えるたびに育つが、述語は育たない。"
created: "2026-08-02T11:59:42+09:00"
updated: "2026-08-02T11:59:42+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260802T020939Z-pr-2084.md"
  - type: "fixes"
    ref: "raw/fixes/20260802T021249Z-pr-2084.md"
tags: [documentation, rule-design, simplification-first]
confidence: high
---

# 禁止規則が自分のワークフローと衝突したら、例外条項を足す前に規則の軸を言い換える

## 概要

「X を書くな」型の禁止規則を新設したとき、その場所へ書き込む既存経路が X の形をしたものを書いていると規則が自分のワークフローを違反者にする。ここでカーブアウト条項（「ただし経路 P の記録は除く」）を足すのが最初に思いつく解だが、**禁止対象の切り出し方そのものを疑うほうが安い**。禁止したい害と、巻き添えになっているものを分ける述語が見つかれば、例外リストは不要になる。例外リストは経路が増えるたびに育つが、述語は育たない。

## 詳細

### 発生事例（Issue テンプレートへの規則追加、cycle 2）

Issue テンプレート Section 9（Decision Log）に「作業項目を載せるな」という規則を追加したところ、rite 自身の `/rite:pr-review` ステップ 7.4.3 がスコープ外と判断した指摘を Section 9 へ自動 append しており、その `{decision}` 欄は SKILL.md が「候補内容の要約、1 文」と規定しているため **実体が作業項目の形** になっていた。スコープ外という含意は `{reason}` 欄にしか宿らない。しかも Section 9 へ書き込む主体が読むのは生成された Issue body 側の HTML コメントだけで、そこに判定材料がなかった。

両 reviewer が「L295 にカーブアウト 1 句を追加せよ」と推奨した。

### 採った解と、なぜそちらが安いか

カーブアウトではなく、規則の軸を **モノの種類（作業項目かどうか）から性質（決定かどうか）へ** 言い換えた:

- Before: `Do NOT record work items here`
- After: `A decision not to act — "out of scope", "deferred", "rejected" — is itself a scope boundary and belongs here, and so does the work item it declines. What does not belong is work you have taken on and not yet finished`

この言い換えで 7.4.3 の記録は規則の側から自然に許可され、例外条項が要らなくなった。条文はむしろ短くなり、将来 7.4.3 以外の書き込み経路が増えても壊れない。

### 判断の手順

1. 衝突を検出したら、まず **禁止したい害** を言語化する（本件: 未着手の to-do が積み上がって本物の判断が埋もれる）
2. 次に **巻き添えになっているもの** を言語化する（本件: やらないと決めたことの記録）
3. 両者を分ける述語が引けるかを試す（本件: 「決定か / 未着手の作業か」）
4. 引けるなら軸を言い換える。引けないならカーブアウトを足す

### カーブアウトが正しいケース

- 巻き添えが真に例外的で、述語では切り出せない（対象が単一の固有名でしか特定できない）
- 述語の言い換えが規則の本来の意図を歪める（禁止範囲が意図せず広がる/狭まる）

この 2 条件のどちらにも当たらないなら、述語の言い換えを先に試す。

### 副次的な学び（同 cycle）

- 許可リストに使う語が同一ファイル内の既存見出しと同名だと、同じ知識の記録先が 2 箇所に割れる（本件では `compatibility policy` が `### 3.3 Compatibility Policy` と衝突し、自分が引用している `knowledge_routing` の「同じ知識を 2 チャネルに記録しない」に反した）。許可リストの語は同一ファイルを grep して既存見出しとの衝突を確認する
- 原則ファイルを典拠として引用するときは、引用先の **全行** が主張と整合するか確認する（本件では `knowledge_routing` の 4 チャネル表が rejected alternative を code comments へ routing しており、1 行だけ逆を向いていた）。整合しない行があるなら「適用する」ではなく「同じ原理を別レイヤーへ延長したもの」と書く

## 関連ページ

- [「N 種を禁止し行き先を示す」規則は禁止列挙と行き先を 1 つの対リストに畳む](../patterns/deny-list-paired-with-destination.md)
- [新規禁止規則を書く前に、その場所へ書き込む既存経路が書くフィールドの実体を読む](./new-prohibition-verify-existing-writer-fields.md)

## ソース

- [PR #2084 review results (cycle 2)](../../raw/reviews/20260802T020939Z-pr-2084.md)
- [PR #2084 fix results (cycle 2)](../../raw/fixes/20260802T021249Z-pr-2084.md)
