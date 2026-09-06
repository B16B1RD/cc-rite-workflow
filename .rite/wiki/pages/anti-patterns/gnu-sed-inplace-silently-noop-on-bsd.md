---
type: "anti-patterns"
title: "GNU 形式の `sed -i '<expr>' file` は BSD sed で fixture を書き換えないまま失敗する"
domain: "anti-patterns"
description: "BSD sed は `-i` の次の引数を backup 拡張子と解釈するため、式が拡張子・ファイル名が script として扱われ parse error になる。`set -e` の無いテストでは無言で先へ進み、fixture 不変のまま突合系 assertion だけが落ちる。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-06T16:10:23Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260906T155431Z-pr-2582.md"
tags: ["portability", "sed", "bsd", "macos", "test-fixture", "awk"]
confidence: high
---

# GNU 形式の `sed -i '<expr>' file` は BSD sed で fixture を書き換えないまま失敗する

## 概要

BSD sed（macOS 既定）は `-i` の直後の引数を backup 拡張子として消費する。そのため GNU 形式の `sed -i 's/a/b/' file` は式を拡張子と解釈し、ファイル名を script として parse しようとして error になる。`set -e` の無いテストスクリプトでは無言で先へ進み、fixture が書き換わらないまま検証が続く。

## 詳細

### 失敗の署名

この壊れ方は特徴的な署名を持つ。fixture 不変 → 差分が空 → 差分と何かを突合する assertion **だけ**が落ちる。fixture 生成そのものは成功しているように見えるため、原因がテスト対象側にあると誤読しやすい。CI が allowed failure（`continue-on-error: true`）で当該ジョブを緑にしていると、この署名は長期間隠れる。

### 代替形

リポジトリ内で既定として使える形は awk の read → transform → write → `mv` である。GNU / BSD / bwk awk のいずれでも同じ動作をする。ヘルパーが複数のテストスイートに別名で複製されている場合、共通ヘルパーへの一本化が次の再発防止になる。

### 移植性修正の検証は 3 実装で行う

「直った」と言えるのは、gawk / mawk（ローカル）と bwk awk（macOS CI）で同一の結果を得たときである。加えて no-op 変異を入れて、その書き換えが load-bearing であることも確認する。1 実装で緑になっただけでは移植性の主張にならない。

## 関連ページ

- [移植性の指摘は「環境分岐を足す」より先に「その正規表現機能が本当に要るか」を疑う](../heuristics/portability-fix-questions-the-regex-feature-first.md)
- [review ループは CI の結果を実測入力に持たない](../heuristics/review-loop-has-no-ci-result-input.md)

## ソース

- [レビュー結果](../../raw/reviews/20260906T155431Z-pr-2582.md)
