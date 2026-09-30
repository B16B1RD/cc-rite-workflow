---
type: "anti-patterns"
title: "git update-index --force-remove は対象が無くても成功を返す — 破壊的な次の手の前に index を読み直す"
domain: "anti-patterns"
description: "git update-index --force-remove は index に対象の entry が無くても終了コード 0 を返すため、終了コードだけでは entry を外せたことを確かめられない。次に取り消せない操作が続くなら、index を読み直して entry が消えたことを確認してから進む。"
created: "2026-09-30T09:18:44Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-30T09:18:44Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260930T080508Z-pr-3523.md"
  - type: "fixes"
    resource: "raw/fixes/20260930T081802Z-pr-3523.md"
tags: ["git", "exit-code", "destructive-operation", "verification"]
confidence: high
---

# git update-index --force-remove は対象が無くても成功を返す — 破壊的な次の手の前に index を読み直す

## 概要

git update-index --force-remove は index に対象の entry が無くても終了コード 0 を返すため、終了コードだけでは entry を外せたことを確かめられない。次に取り消せない操作が続くなら、index を読み直して entry が消えたことを確認してから進む。

## 詳細

### 起きること

index から entry を外し、続けて `git rm -rf` のような取り消せない操作を行う手順で、外す処理の成否を終了コードで判定していた。path の指定が実際の entry と食い違っていても（引用付きの path を渡した、など）、`git update-index --force-remove` は何も外さずに 0 を返す。手順は「外せた」と判断して次の破壊的な操作へ進む。

「対象が無くても成功を返す」コマンドは、成功が「望む状態になった」ことを意味しない。意味するのは「エラーが起きなかった」ことだけである。

### 書き方

- 外した直後に index を読み直し（`git ls-files -s -z -- <path>` など）、entry が残っていないことを確かめる
- 残っていたら、次の操作へ進まずにエラーとして止める。エラー文には残っている entry を出す
- この確認は、取り消せない操作の直前に置く。離れた場所で確認すると、間に入った処理が状態を変える

### テスト

偽の git で「外す処理は 0 を返すが entry は残る」状況を作り、手順が破壊的な操作を実行せずに止まることを検査する。読み直しを無効にする変異でこのテストが落ちることを確かめる。追加したエラー分岐は、その分岐に入るテストが無いと変異で生き残る。

### 同じ cleanup を 2 つの trap が呼ぶ場合

signal の trap と EXIT の trap が同じ cleanup 関数を呼ぶ構成では、cleanup に足した出力付きの検査が 2 回走る。1 回に限りたい処理は、実行の前に「済み」のフラグを下ろす。

## 関連ページ

- [git の index から読んだ path を別のコマンドへ渡すときは -z の NUL 区切りで読む](../patterns/git-index-paths-read-nul-delimited-before-passing-on.md)
- [jq は入力が 0 ドキュメントだとフィルタを評価せず rc=0 で終わる — 形の検証は jq -s と length == 1 で入力を 1 ドキュメントに閉じる](./jq-empty-input-skips-filter-rc-zero.md)

## ソース

- [終了コードでは外せたことを確かめられないと指摘したレビュー結果](../../raw/reviews/20260930T080508Z-pr-3523.md)
- [破壊的な操作の前に index を読み直すようにした fix 結果](../../raw/fixes/20260930T081802Z-pr-3523.md)
