---
type: "heuristics"
title: "CI 設定を grep で検査するときは matrix の行だけでなく job が実際に走る条件も固定する"
domain: "heuristics"
description: "ジョブが両 OS で走ることを静的検査で守るとき、matrix 行と continue-on-error の不在だけを見ると、runs-on の固定化や job の if: false で片方の OS が消えても検査を通る。runs-on が matrix 値を参照することと、job 直下に実行条件が無いことも固定する。"
created: "2026-10-03T10:15:00+09:00"
generated: { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-10-03T01:15:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261003T004319Z-pr-3635.md"
  - type: "reviews"
    resource: "raw/reviews/20261003T005948Z-pr-3635-c2.md"
tags: ["ci", "github-actions", "test-quality", "mutation-check"]
confidence: medium
---

# CI 設定を grep で検査するときは matrix の行だけでなく job が実際に走る条件も固定する

## 概要

テストから ci.yml を grep して「両 OS のジョブがあり、blocking である」ことを守るとき、`matrix.os` の値の行と `continue-on-error` の不在だけを検査すると、契約が求める「両 OS の leg が実際に走る」ことは守れない。`runs-on` を `ubuntu-latest` に固定すれば matrix に macOS が残るだけで macOS の leg は消え、job に `if: false` を足せば job 全体が走らなくなる。どちらも検査は通り続ける。

## 詳細

### 変異で確かめる

検査の強さは、契約を壊す最も単純な変更を加えたコピーに対してテストを走らせて確かめる。`continue-on-error` の追加は検出されるのに、`runs-on` の固定化と `if: false` が素通りするなら、検査は契約の一部しか守っていない。

### 固定する項目

- `runs-on` が `${{ matrix.os }}` であること
- job 直下（step ではなく job の階層）に `if` が無いこと
- matrix の `os` が期待した 2 値だけであること
- `continue-on-error` が job にも step にも無いこと

ジョブを切り出す抽出は、次のジョブ名の行で止めて、検査対象を当該ジョブのブロックに限る。

### blocking の範囲

ci.yml 上の検査が保証するのは「ジョブが失敗扱いになる」ことまでで、マージを実際に止めるかどうかは branch protection の必須チェックというリポジトリ設定で決まる。検査の定義を ci.yml 上の性質に限り、必須チェックの登録は別の設定として扱う。

## 関連ページ

- [assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる — positive control を対で置く](../anti-patterns/assert-not-grep-vacuous-without-fixture-scope.md)

## ソース

- [レビュー結果](../../raw/reviews/20261003T004319Z-pr-3635.md)
- [再レビュー結果](../../raw/reviews/20261003T005948Z-pr-3635-c2.md)
