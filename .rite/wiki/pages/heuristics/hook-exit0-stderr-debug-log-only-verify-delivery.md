---
type: "heuristics"
title: "exit 0 で終わる hook の stderr は debug ログにしか残らない — 通知の到達先を確かめてから文書に「知らせる」と書く"
domain: "heuristics"
description: "SessionStart など exit 0 で終わる Claude Code hook が stderr に書いた WARNING は debug ログにしか残らず、会話にもユーザーにも届かない。出力先を字義で指定した受入基準を満たしていても、文書が「ユーザーに知らせる」と書けば実行時に成り立たない主張になるため、到達経路を公式ドキュメントと実行で確かめてから書く。"
created: "2026-09-14T01:40:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-14T01:40:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260914T010341Z-pr-2795.md"
  - type: "fixes"
    resource: "raw/fixes/20260914T010811Z-pr-2795.md"
tags: ["hooks", "stderr", "notification", "documentation-fidelity"]
confidence: high
---

# exit 0 で終わる hook の stderr は debug ログにしか残らない — 通知の到達先を確かめてから文書に「知らせる」と書く

## 概要

SessionStart など exit 0 で終わる Claude Code hook が stderr に書いた WARNING は debug ログにしか残らず、会話にもユーザーにも届かない。出力先を字義で指定した受入基準を満たしていても、文書が「ユーザーに知らせる」と書けば実行時に成り立たない主張になるため、到達経路を公式ドキュメントと実行で確かめてから書く。

## 詳細

### 何が起きたか

git dir に残った空の lock を検知する処理を session start の hook に足し、受入基準どおり WARNING を stderr に出した。reference と仕様書には「検知して WARNING でユーザーに知らせ、削除はユーザーが行う」と書いた。レビューでは、この前提が実行時に成り立たないことが最上位の指摘になった。公式 hooks ドキュメントは「Stderr from a hook that exits 0 goes to the debug log only, never the transcript, and Claude never sees it.」と述べている。SessionStart で Claude のコンテキストに入るのは plain-text の stdout だけである。

実装は契約の字義を満たしていて、壊れていたのは「stderr に出す = 誰かが読む」という文書側の同一視だった。

### 直し方の選択

選択肢は 2 つある。

- **出力先を stdout などの見える経路へ変える**: 受入基準の Then（「stderr に出る」）を書き換えることになり、契約の変更を伴う。同じ hook の既存の stderr WARNING も同じ前提に乗っているので、1 箇所だけ変えると方針が割れる。
- **文書を実態に合わせる**: 出力先は契約どおり据え置く。文書から「知らせる」前提を外し、「debug ログにしか残らない」と書く。さらに、症状（`could not lock config file` など）に出会ったときに自分で確かめる手順を添える。判断は Issue の Decision Log に残す。

契約を字義どおり保てるのは後者で、出力経路の棚卸しは別の作業として切り出せる。

### 書く前に確かめること

- その出力を**誰が読むのか**を、hook の終了コードと出力チャネルの組み合わせで確認する。exit 0 の stderr は読まれない前提で考える。
- 「知らせる」「表面化する」と書くなら、読み手に届く経路（Claude のコンテキストに入る stdout、ユーザーに直接出る仕組み）を名指しし、宛先を主語で書く。
- 届かない経路のままにするなら、症状側から辿れる自己確認の手順を文書に置く。その手順が実行場所によって判別能力を失わないかも確かめる。

## 関連ページ

- [診断WARNINGの宛先（実行エージェント向けかユーザー向けか）を主語で明示する](./diagnostic-warning-message-audience-ambiguity.md)
- [外部依存の挙動は hedge か断定かの二択ではない — 既定形は「断定 + 出典 + 確認日 + 再検証手順」](./external-dependency-claim-hedge-vs-citation.md)
- [検証手順を書くときは処方するコマンドの判別能力そのものを実測する](./prescribed-command-discriminating-power-measured.md)

## ソース

- [stderr の到達先を指摘したレビュー結果](../../raw/reviews/20260914T010341Z-pr-2795.md)
- [文書を実態に合わせて契約を保った fix 結果](../../raw/fixes/20260914T010811Z-pr-2795.md)
