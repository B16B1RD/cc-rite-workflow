---
type: "heuristics"
title: "skill の手順に実行ブロックを足すときは、その skill のシェルブロックの形の契約に合わせ、検証に形を検査する hooks のスイートを含める"
domain: "heuristics"
promote: rite-plugin
description: "手順書に複合コマンドを直接書くと、形の契約（helper を介した top-level の単一 bash 呼び出し）を検査するテストと CI が落ち、worktree 隔離のセッションではホストのガードに拒否される。本体は helper のサブコマンドへ置き、外部への書き込みは成功と失敗の印を対で出して判定表の fatal 行へ配線する。"
created: "2026-10-09T19:10:23Z"
generated: { by: "manual/claude-opus-5-5", at: "2026-10-10T02:51:06Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261009T171836Z-pr-3728.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T173329Z-pr-3728.md"
tags: ["skill-authoring", "shell-block-shape", "fail-loud", "marker"]
confidence: high
---

# skill の手順に実行ブロックを足すときは、その skill のシェルブロックの形の契約に合わせ、検証に形を検査する hooks のスイートを含める

## 概要

手順書に複合コマンドを直接書くと、形の契約（helper を介した top-level の単一 bash 呼び出し）を検査するテストと CI が落ち、worktree 隔離のセッションではホストのガードに拒否される。本体は helper のサブコマンドへ置き、外部への書き込みは成功と失敗の印を対で出して判定表の fatal 行へ配線する。

## 詳細

### 起きたこと

PR 本文の行を修正側で直す経路を skill に足した修正で、手順書に複合コマンドの実行ブロックを書いた。fix 側のローカル検証は scripts のテストだけで hooks のテストを含まなかったため、形の契約違反は CI で初めて見つかった（HIGH 1 件）。

### 書き方

- 実行ブロックの本体は helper のサブコマンドへ置き、手順書には helper を通した top-level の単一 bash 呼び出しだけを書く
- 手順書を変える修正では、その skill の形を検査するテストを含む hooks のスイートも検証に入れる
- `cmd && echo marker` のように成功時だけ印を出す形は、失敗時に何も残らず、後段の判定表で「何もしなかった」と区別できない。外部への書き込み（`gh pr edit` など）は helper が成功と失敗の印を対で出し、失敗の印を判定表の fatal 行（`[fix:error]`）に置く。この形にした次のレビューでは、全員が fail-loud として確認して指摘ゼロに収束した
- 判定表に条件を足したら、同じ規則を言い換えた要約の散文（handoff の文、判定のメモ、「上記 N マーカー」など）も同時に直す。既存テストが文言を固定している行の扱いは、[判定表の行に条件を足したら、否定側の行・言い換えた要約・その行を固定するテストを同じ変更で揃える](./decision-table-row-condition-moves-negation-row-summary-and-pin.md) に従い、両方の文言を固定するテストを最初から計画に入れる
- PR 本文の実装説明は、helper が実際に集める事実の範囲に合わせる。検証エージェントが手順で補う部分を helper の機能として書かない
- 新しい helper は本物の PR に対しても 1 回実行し、印が出ることを確かめる。手順書の配線と実装の両方を確認できる

## 関連ページ

- [SKILL.md のブロックを helper へ移すと、ブロック内コメントの手順情報が LLM から消える](./skill-block-to-helper-keeps-comment-guidance.md)
- [判定表の行に条件を足したら、否定側の行・言い換えた要約・その行を固定するテストを同じ変更で揃える](./decision-table-row-condition-moves-negation-row-summary-and-pin.md)

## ソース

- [レビュー結果（形の契約違反と成功時だけの印）](../../raw/reviews/20261009T171836Z-pr-3728.md)
- [fix 結果（helper のサブコマンドと対の印）](../../raw/fixes/20261009T173329Z-pr-3728.md)
