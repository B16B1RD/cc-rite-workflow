---
type: "heuristics"
title: "実測ゲートで降格した文書指摘でも、grep で確認できる事実誤りはリリース転記前に修正で消化する"
domain: "heuristics"
promote: rite-plugin
description: "実測必須ゲートが non-blocking へ降格した文書指摘のうち、reviewer が Grep で裏取りした事実誤り（機能の帰属先ファイルの取り違え等）は、記録台帳へ載せて次サイクルの再報告を抑止するのではなく、その場で修正して消化する。記録に回すと CHANGELOG の誤記述がそのまま GitHub Release へ転記され、後から修正する経路が無い。"
created: "2026-09-11T15:07:49Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-01T11:30:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-17T06:16:56Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-01T11:30:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20261001T105449Z-pr-3596.md"
  - type: "reviews"
    resource: "raw/reviews/20261001T104845Z-pr-3596.md"
  - type: "reviews"
    resource: "raw/reviews/20261001T111805Z-pr-3596.md"
  - type: "reviews"
    resource: "raw/reviews/20260911T124654Z-pr-2686.md"
  - type: "reviews"
    resource: "raw/reviews/20260917T054339Z-pr-2924.md"
  - type: "reviews"
    resource: "raw/reviews/20260917T060028Z-pr-2924-c2.md"
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

### 補強: リリースノートを PR 本文から要約したときに生じる事実誤りの型

リリース準備 PR の CHANGELOG を多数の PR 本文から要約して書くと、reviewer が Grep で裏取りできる事実誤りが次の 3 つの型で入り込みやすい。いずれも挙動的帰結を持たないため実測ゲートで non-blocking へ降格するが、公開される Release 本文なので上記の判定基準どおり修正で消化する。

- **test-only の変更を挙動変更として書く**: テストの pin 対象を変えただけのコミット（変更ファイルがテストのみ）を、本体 hook が「WARNING だけ出す → 照合を skip する」ように変わったかのように記述する。`git show --stat` で変更ファイルがテストだけなら、書くべきは「テストが何を固定するようになったか」であって挙動の変化ではない。
- **翻訳で否定の係り先がずれる**: 「A と同一視せず回収を見送る」を「A と同じ扱いで回収せず」と訳すと、実装と逆の意味（失敗を A と同一視する）に読める。原文の否定が係る語を訳文でも同じ語に係らせているかを、英日で並べて確認する。
- **数値の記述が現行設定と食い違う**: 「15 分の上限を下回った」のような数値は、同じ変更でその設定値自体（`timeout-minutes`）が別の値に更新されていることがある。数値を書く前に現行の設定ファイルを Read し、「実測 N 分、上限 M 分」のように現在形の事実へ揃える。

修正後の差分スコープ再レビューは、前回指摘の FIXED 判定と修正 3 文の実装照合だけで済み、記録に回すより短い。

### 補強: 承認済み草案でも同じ扱いにし、追加の型が 2 つある

リリース担当が文言を承認した草案であっても、実装と食い違う記述は公開前に直す。承認は文意の承認であって実装との照合ではないため、承認済みを理由に記録へ回すと誤りがそのまま公開される。直す範囲は食い違った語句だけに絞り、それ以外の承認済み文言には触れない。差分スコープの再レビューで「指示した箇所以外の行が変わっていない」ことを diff の行数で確かめると、過剰修正も同時に防げる。

- **対象スキル名を総称で書く**: 「review」のような総称は、隣に並ぶ他の項目が slash コマンド名で書かれていると特定のスキル（`/rite:pr-review`）と読まれる。入口処理を呼ぶスキルを grep で列挙し、実際の呼び出し元の名前で書く。処理が同じセッションに限られるような適用条件も、実装の契約文から拾って添える。
- **英語の単数・複数がファイル数と食い違う**: 実装が 2 つのファイルを渡すのに "a JSON file" と書くと、受け手は 1 ファイルだと読む。日本語は数を区別しない表記が多いので、英日の一方だけが食い違うことがあり、その場合は食い違う側だけを直す。

## 関連ページ

- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](./prose-cited-implementation-behavioral-verification.md)
- [bilingual CHANGELOG は PR 単位で同期し、バージョン見出しは英語、本文には Issue 番号を書いてよい](../patterns/bilingual-changelog-sync-conventions.md)

## ソース
- [レビュー結果](../../raw/reviews/20260917T054339Z-pr-2924.md)
- [レビュー結果](../../raw/reviews/20260917T060028Z-pr-2924-c2.md)

- [レビュー結果](../../raw/reviews/20260911T124654Z-pr-2686.md)
- [fix 結果](../../raw/fixes/20261001T105449Z-pr-3596.md)
- [レビュー結果](../../raw/reviews/20261001T104845Z-pr-3596.md)
- [レビュー結果](../../raw/reviews/20261001T111805Z-pr-3596.md)
