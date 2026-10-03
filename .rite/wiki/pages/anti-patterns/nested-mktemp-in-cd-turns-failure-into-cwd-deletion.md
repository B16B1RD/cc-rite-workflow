---
type: "anti-patterns"
title: "cd の中に mktemp -d を入れ子にすると失敗時に cwd が一時ディレクトリ扱いになり trap の rm -rf が作業ツリーを消す"
domain: "anti-patterns"
description: "TEST_ROOT=$(cd \"$(mktemp -d)\" && pwd -P) は mktemp が失敗しても失敗せず、cd に空文字が渡って rc 0 のまま cwd に留まる。EXIT trap が rm -rf で TEST_ROOT を消すテストでは、checkout や未コミット変更ごと失う。mktemp と cd を 2 ステップに分けて失敗をその場で止める。"
created: "2026-10-03T10:15:00+09:00"
generated: { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-10-03T01:15:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20261003T004841Z-pr-3635.md"
  - type: "reviews"
    resource: "raw/reviews/20261003T004319Z-pr-3635.md"
tags: ["bash", "mktemp", "trap", "set-e", "fail-loud", "test-quality"]
confidence: high
---

# cd の中に mktemp -d を入れ子にすると失敗時に cwd が一時ディレクトリ扱いになり trap の rm -rf が作業ツリーを消す

## 概要

macOS の `/var` と `/private/var` の差を吸収するために `TEST_ROOT=$(cd "$(mktemp -d)" && pwd -P)` と書くと、`mktemp` が失敗したときに失敗が伝わらない。`cd ""` は cwd を変えずに終了コード 0 を返し、`set -e` も入れ子の command substitution の失敗を拾わない。`TEST_ROOT` が cwd（CI では checkout、手元では未コミット変更を含む作業ツリー）になり、直後に `trap 'rm -rf "$TEST_ROOT"' EXIT` を張っていると、テスト終了時にそれを丸ごと削除する。

## 詳細

### 起きる条件

`TMPDIR` の誤設定や一時領域の枯渇という通常の操作ミスで起きる。敵対者を前提にした問題ではなく、単一ユーザーの開発機でも未コミット作業を失う。

### 是正

`mktemp` と `cd` を 2 ステップに分け、`mktemp` の失敗をその場で止める。

```bash
TEST_ROOT=$(mktemp -d) || exit 1
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P) || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT
```

`trap` は 2 つの代入より後ろに置く。代入が失敗した時点では `trap` が未登録なので、空や cwd を指した `rm -rf` が走る経路が無い。新しい guard や fallback は足さず、既存の入れ子を単純化するだけで足りる。

### 検証のしかた

修正前のコードに対して、`trap` を含む本体を実行して確かめてはならない。実行すると実際に cwd を消す。同じ代入式だけを含み `trap` を `echo` に差し替えた使い捨てスクリプトを `TMPDIR` を存在しないパスにして実行し、`TEST_ROOT` が cwd と一致することを観測する。修正後は本体を `TMPDIR` を存在しないパスにして実行し、`mktemp` のエラーと非ゼロ終了を確認する。

### 再発の見つけ方

新規に書いたテストが兄弟テストの既存の修正を知らずに同じ入れ子を再導入することがある。既存テストに同じ理由を述べたコメントがあれば、同じ形を使う。

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](../patterns/trap-register-before-mktemp.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)

## ソース

- [修正結果](../../raw/fixes/20261003T004841Z-pr-3635.md)
- [レビュー結果](../../raw/reviews/20261003T004319Z-pr-3635.md)
