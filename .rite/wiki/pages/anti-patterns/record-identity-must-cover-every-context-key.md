---
type: "anti-patterns"
title: "記録の同定キーが文脈の一部しか含まないと、同じ HEAD の再実行で前回の記録を今回のものと誤認する"
domain: "anti-patterns"
description: "追記した記録を後で「今回の分がある」と確認する仕組みで、同定キーが run と commit だけなど文脈キーの一部しか持たないと、同じ HEAD を再レビューしたとき前 cycle の記録が一致して完了扱いになる。同定キーは記録を生んだ文脈の全キー（cycle を含む）で一意にし、確認は再取得の失敗と記録不在を別分岐にする。"
promote: rite-plugin
created: "2026-09-27T11:30:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T11:30:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T111430Z-pr-3267.md"
tags: ["identity", "idempotency", "fail-loud", "review-record"]
confidence: high
---

# 記録の同定キーが文脈の一部しか含まないと、同じ HEAD の再実行で前回の記録を今回のものと誤認する

## 概要

追記した記録を後で「今回の分がある」と確認する仕組みで、同定キーが run と commit だけなど文脈キーの一部しか持たないと、同じ HEAD を再レビューしたとき前 cycle の記録が一致して完了扱いになる。同定キーは記録を生んだ文脈の全キー（cycle を含む）で一意にし、確認は再取得の失敗と記録不在を別分岐にする。

## 詳細

レビューの記録を作業メモリへ追記し、完了判定の前に「今回の記録が残っているか」を marker で確認する設計で起きた。marker が run と commit しか持たなかったため、fix を挟まずに同じ HEAD をもう一度レビューすると、前 cycle が残した marker が今回の確認に一致した。今回の記録が書けていなくても完了扱いになる。2 名のレビュアーが独立にこの経路を実測している。

同定キーの設計では、「この記録を生んだ操作を他と区別する軸」をすべて列挙してからキーに入れる。run・commit・cycle のように、同じ run の中でも繰り返しうる軸を落とすと、再実行のたびに古い記録が新しい確認を満たしてしまう。とくに HEAD が変わらない再実行は、commit を軸に含めていても区別できない。

確認側にも同じ種類の罠がある。追記後に記録を読み直す手順で「再取得に失敗した」と「読み直せたが記録が無い」を 1 つの分岐にまとめると、終了コードで止めること自体は正しくても、案内する復旧手順を取り違える。前者は通信や権限の問題で、再試行が正しい。後者は書き込みの問題で、追記のやり直しが要る。失敗の出どころを分けて報告しないと、利用者は効かない復旧手順を踏む。

## 関連ページ

- [外部コマンド (gh) 失敗時に not-found と一時障害を区別せず別経路へ落とすのは silent failure](./external-command-failure-origin-distinction.md)
- [同定に使う needle は位置まで固定し、人間が複製できる文字列を使わない](./identity-needle-position-and-machine-only-sentinel.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T111430Z-pr-3267.md)
