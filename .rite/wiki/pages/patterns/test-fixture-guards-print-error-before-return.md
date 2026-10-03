---
type: "patterns"
title: "テスト fixture の前提ガードは return 1 だけにせず原因を ERROR で出す"
domain: "patterns"
description: "set -e 下で fixture 構築のガードが return 1 だけで失敗すると、出力ゼロで終了し、CI の失敗サマリは原因を拾えない。各ガードを ERROR で始まる 1 行つきの失敗にすれば、サマリの grep が原因を示す。"
created: "2026-10-03T10:15:00+09:00"
generated: { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-10-03T01:15:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261003T004319Z-pr-3635.md"
tags: ["bash", "test-quality", "fail-loud", "ci-diagnostics"]
confidence: medium
---

# テスト fixture の前提ガードは return 1 だけにせず原因を ERROR で出す

## 概要

fixture を組み立てる関数の前提条件（配布物の存在、入れ子ディレクトリの不在、git toplevel の一致など）を `[ ... ] || return 1` だけで守ると、呼び出し側が `set -e` に任せている限り、失敗時に PASS 行も ERROR 行も出ずに終了する。CI の失敗サマリが `FAIL` と `^ERROR: ` だけを拾う構成では、ログが空のまま原因が追えなくなる。

## 詳細

### 何が困るか

配布物の改名や欠落は、このテストが検出すべき配布回帰そのものだが、検出した事実が何も表示されない。macOS の `/var` と `/private/var` の差を検出するガードのように、特定の環境でだけ落ちる前提ガードほど、無言の失敗は原因を追いにくい。

### 是正

各ガードを、何が壊れたかを示す 1 行を stderr に出して失敗させる形にする。

```bash
[ -f "$INSTALL_DIR/hooks/session-start.sh" ] || { echo "ERROR: session-start.sh missing from the install cache: $INSTALL_DIR" >&2; return 1; }
```

新しい helper は足さず、同じファイルの他の失敗経路が採っている ERROR の流儀に揃える。`ERROR:` 接頭辞にしておけば、既存の失敗サマリの grep がそのまま拾う。

## 関連ページ

- [cd の中に mktemp -d を入れ子にすると失敗時に cwd が一時ディレクトリ扱いになり trap の rm -rf が作業ツリーを消す](../anti-patterns/nested-mktemp-in-cd-turns-failure-into-cwd-deletion.md)

## ソース

- [レビュー結果](../../raw/reviews/20261003T004319Z-pr-3635.md)
