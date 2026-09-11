---
type: "heuristics"
title: "実測ゲートで降格した文書指摘でも、grep で確認できる事実誤りはリリース転記前に修正で消化する"
domain: "heuristics"
promote: rite-plugin
description: "実測必須ゲートが non-blocking へ降格した文書指摘のうち、reviewer が Grep で裏取りした事実誤り（機能の帰属先ファイルの取り違え等）は、記録台帳へ載せて次サイクルの再報告を抑止するのではなく、その場で修正して消化する。記録に回すと CHANGELOG の誤記述がそのまま GitHub Release へ転記され、後から修正する経路が無い。"
created: "2026-09-11T15:07:49Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-11T15:07:49Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260911T124654Z-pr-2686.md"
tags: ["release", "changelog", "non-blocking", "measured-gate"]
confidence: medium
---

# 実測ゲートで降格した文書指摘でも、grep で確認できる事実誤りはリリース転記前に修正で消化する

## 概要

実測必須ゲートが non-blocking へ降格した文書指摘のうち、reviewer が Grep で裏取りした事実誤り（機能の帰属先ファイルの取り違え等）は、記録台帳へ載せて次サイクルの再報告を抑止するのではなく、その場で修正して消化する。記録に回すと CHANGELOG の誤記述がそのまま GitHub Release へ転記され、後から修正する経路が無い。

## 詳細

実測必須ゲートは「runtime で観測できない指摘は merge を止めない」という規則であり、散文の事実誤りは挙動的帰結を持たないため構造的に non-blocking へ落ちる。降格自体は正しいが、降格先の既定処理（関連 Issue の記録コメントへ pointer を残し、却下台帳で以降の再報告を抑止する）は「後で人間が拾い直す」前提に立っている。

リリース準備 PR の CHANGELOG はこの前提が崩れる。マージ後に release skill がエントリを GitHub Release 本文へ転記するため、記録に回した誤りは公開物へそのまま流れ、次サイクルの reviewer は台帳を見て再報告しない。降格した指摘のうち次の 2 条件を満たすものは、記録ではなく修正で消化する:

- reviewer が Grep / Read で誤りを裏取りしている（推測ではなく、帰属先ファイルの実体と食い違う等の確認済み事実）
- 転記先（Release ノート・公開 docs）があり、マージ後に同じ経路で直せない

判定は「blocking か否か」ではなく「記録に回して失われる情報か否か」で行う。修正は differential scope の fix cycle で 1 行の書き換えに収まることが多く、記録 + 台帳更新より小さい。

## 関連ページ

- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](./prose-cited-implementation-behavioral-verification.md)
- [bilingual CHANGELOG は PR 単位で同期し、バージョン見出しは英語、本文には Issue 番号を書いてよい](../patterns/bilingual-changelog-sync-conventions.md)

## ソース

- [レビュー結果](../../raw/reviews/20260911T124654Z-pr-2686.md)
