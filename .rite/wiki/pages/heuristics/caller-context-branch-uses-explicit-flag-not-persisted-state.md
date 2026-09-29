---
type: "heuristics"
title: "呼び出し元で挙動を分ける規則は、永続状態から推定せず呼び出し元が渡す明示の引数で分ける"
domain: "heuristics"
promote: rite-plugin
description: "「誰が呼んだか」で分岐する規則を flow-state の phase や active から推定すると、直前の別コマンドや自分自身が同じ状態を書くため単独実行と区別できない。呼び出し元に明示の引数を渡させ、欠落は安全側に倒し、invoke するすべての分岐と継続 handoff に同じ引数を付ける。"
created: "2026-09-29T16:54:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T16:54:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T134642Z-pr-3452.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T141430Z-pr-3452.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T140253Z-pr-3452.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T143234Z-pr-3452.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T144856Z-pr-3452.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T151059Z-pr-3452.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T153014Z-pr-3452.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T154417Z-pr-3452.md"
tags: ["caller-flag", "invariant", "handoff", "fail-loud"]
confidence: high
---

# 呼び出し元で挙動を分ける規則は、永続状態から推定せず呼び出し元が渡す明示の引数で分ける

## 概要

「誰が呼んだか」で分岐する規則を flow-state の phase や active から推定すると、直前の別コマンドや自分自身が同じ状態を書くため単独実行と区別できない。呼び出し元に明示の引数を渡させ、欠落は安全側に倒し、invoke するすべての分岐と継続 handoff に同じ引数を付ける。

## 詳細

レビューの採否の処分を状態ファイルへ登録し、後に続く工程が読んで使い回す変更で、「登録してよいのは読む工程が後に続く経路だけ」という規則が 6 cycle にわたって指摘を生んだ。指摘は次の順に移っていった。

### 経路の性質は経路の信号で分ける

最初は登録の可否を結果（レビュー結果のデータ）だけで決めていたため、読み手の無い経路（単独実行）でも登録され、後で cleanup が hold ファイルの有無しか見ずに登録を消すと、hold に倒さず登録で決着させた候補が無言で消えた。読み手の有無は呼び出し経路の性質なので、経路の信号で分け、読み手の無い経路では hold に倒して fail-loud を保つ。

### 永続状態から推定しない

次に経路の区別を既存の状態検出（phase / active）で代用したところ、単独実行の直前に open や前回の review が同じ状態を書き残すため、単独実行でも内側と判定された。経路の区別には呼び出し元が明示的に渡す引数を使い、引数が無いときは安全側（hold）に倒す。

### invoke するすべての分岐と handoff に付ける

引数を導入した後も、同じ呼び出しを別の条件で行う分岐（lost 修復・再試行）が引数ブロックの条件から外れて引数を失った。再注入された継続 handoff も引数を持たないと、内側の呼び出しが外側扱いになる。invoke を定義する箇所（通常経路・修復経路・再試行・handoff）を列挙し、別の invoke を定義する行には引数を名指しする。同じ invoke の再試行は元の invoke を参照していれば足りる。値を変えた handoff は、値を記述する仕様書の欄とコード内コメントも同時にそろえる。

### 既存の不変条件との衝突は 1 か所で例外を明記する

「呼び出し元の文脈で処分を変えない」という既存の不変条件と、新しい引数は衝突しやすい。判定をデータで決める形に直せるなら不変条件を保てる。例外が避けられないときは、不変条件の文に例外を 1 か所だけ明記し、同じ不変条件を述べるヘッダコメント・SKILL・rationale・計画書を grep でそろえ、例外の文も契約テストで固定する。

### テストの固定の仕方

新しい引数の値検査（許される値以外は exit 2）は未置換 placeholder を fail-loud にする唯一の経路なので、回帰テストで固定する。引数の除去を固定するテストは部分一致ではなく行全体・固定文字列の完全一致で置き、除去処理を消す変異で落ちることを確かめる。

## 関連ページ

- [汎用契約の表に経路固有の詳細を書かず下位節へ委譲する。ただし委譲は委譲先の網羅性を load-bearing にする](./generic-contract-table-delegates-path-specific-detail.md)
- [PR 起因と判定した非 blocking の候補は、同じ PR の fix の計画に入れて直す](./pr-origin-nonblocking-fixed-in-same-pr-plan.md)

## ソース

- [不変条件との衝突を指摘したレビュー結果](../../raw/reviews/20260929T134642Z-pr-3452.md)
- [不変条件の例外を 1 か所に明記した fix 結果](../../raw/fixes/20260929T141430Z-pr-3452.md)
- [読み手の無い経路で登録が消えることを指摘したレビュー結果](../../raw/reviews/20260929T140253Z-pr-3452.md)
- [永続状態からの推定を指摘したレビュー結果](../../raw/reviews/20260929T143234Z-pr-3452.md)
- [明示の引数に切り替えた fix 結果](../../raw/fixes/20260929T144856Z-pr-3452.md)
- [修復・再試行の分岐が引数を失うことを指摘したレビュー結果](../../raw/reviews/20260929T151059Z-pr-3452.md)
- [invoke するすべての分岐で引数を名指しした fix 結果](../../raw/fixes/20260929T153014Z-pr-3452.md)
- [invoke の列挙と完全一致の pin を確かめたレビュー結果](../../raw/reviews/20260929T154417Z-pr-3452.md)
