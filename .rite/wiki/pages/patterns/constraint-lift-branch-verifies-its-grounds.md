---
type: "patterns"
title: "制約を外す分岐は外す根拠を機械的に検証し、判定の基準値に既定値を持たせない"
domain: "patterns"
description: "検査の制約を外す分岐は、外してよい根拠（取り込み相手が base ブランチであること等）を機械的に確かめない限り抜け道になる。判定の基準値も既定値へ倒すと、未設定のまま制約が外れる。"
created: "2026-09-25T03:58:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-25T03:58:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260924T202641Z-pr-3060.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T212015Z-pr-3060.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T204531Z-pr-3060.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T212910Z-pr-3060.md"
tags: ["guard", "fail-loud", "base-branch", "security"]
confidence: high
---

# 制約を外す分岐は外す根拠を機械的に検証し、判定の基準値に既定値を持たせない

## 概要

検査の制約を外す分岐（例: base ブランチの取り込みで入ったファイルを Non-Target 検査から外す）は、外してよい根拠を機械的に検証して初めて安全になる。根拠を名前や慣習で信じると、任意の ref や別 worktree の commit を「取り込み」として通せてしまう。判定の基準値（base の名前など）も既定値を持たせず、未設定なら原因を名指しして止める。

## 詳細

### 抜け道になった例

base 取り込みの merge で base 側の変更ファイルを Non-Target 検査から外す処置を入れたところ、取り込み相手を base ブランチに結び付けていなかった。任意の ref を merge すれば、Issue の作業を Non-Target のファイルへ持ち込めた（一時 repo で実測）。取り込み相手を `git merge-base --is-ancestor` で remote の base に結び付けて塞いだ。

### 基準値の既定値

制約を外すかどうかの基準値を「設定が無ければ既定値」で読むと、設定が壊れていても制約が外れる方向へ倒れる。fail-loud の原則どおり、基準値が取れなければ止めて原因を出す。

### 検査を広げる変更の注意

検査の起動条件や対象サブコマンドを広げると、新たに検査対象へ入る既存の正当な呼び出し元が現れる。広げる前に skill の呼び出し元を洗い出して固定する。広げた検査が cleanup の正当な base 更新まで拒否した例がある。

## 関連ページ

- [位置決めを外部データから取る設計で「取れなかったら既定値を仮定する」と、無言の縮退になる](../anti-patterns/guessed-default-position-creates-silent-degradation.md)
- [fail-closed ガードは「異常を検出したら止める」ではなく「正常を確認できなければ止める」で書く](./fail-closed-confirms-normal-not-detects-abnormal.md)

## ソース

- [レビュー結果](../../raw/reviews/20260924T202641Z-pr-3060.md)
- [レビュー結果](../../raw/reviews/20260924T212015Z-pr-3060.md)
- [fix 結果](../../raw/fixes/20260924T204531Z-pr-3060.md)
- [fix 結果](../../raw/fixes/20260924T212910Z-pr-3060.md)
