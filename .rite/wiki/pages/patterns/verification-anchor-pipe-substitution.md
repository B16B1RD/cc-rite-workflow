---
type: "patterns"
title: "実測アンカーの repro に書くパイプは U+00A6 へ置換する"
domain: "patterns"
description: "実測必須ゲートは、レビュー指摘が blocking であるために `Verification:` アンカー付きの再現手順を要求する。"
created: "2026-08-01T00:21:06+09:00"
updated: "2026-08-01T00:21:06+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260731T060239Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260731T060927Z-pr-2070.md"
tags: []
confidence: high
---

# 実測アンカーの repro に書くパイプは U+00A6 へ置換する

## 概要

実測必須ゲートは、レビュー指摘が blocking であるために `Verification:` アンカー付きの再現手順を要求する。このアンカーは Markdown テーブルのセル内に置かれるため、検出側の正規表現はセル境界を守る `[^|]` を含む。repro に raw pipe（`|`）を書くと full match が成立せず、**実測を伴う指摘が「非実測」として non-blocking へ無音で降格する**。

## 詳細

起点事例では test reviewer が変異注入で実測済みだったにもかかわらず、repro に awk の regex 由来の `\|` が残ったためアンカー検出を通らず降格した。markdown のエスケープ `\|` は表のレンダリングには効くが、**検出側の `[^|]` はエスケープを解釈しない**ので通らない。

対処は `¦`（U+00A6 BROKEN BAR）への置換である。視覚的にパイプと判別でき、検出 regex のセル境界判定にも干渉しない。bash / jq 中心のリポジトリでは repro にパイプが入るのが常態であるため、この降格は運用上頻発しうる。

この事象は「機械化は依存を消さず依存先を移す」の具体例でもある（[強制層の機械化は裁量を消すが依存を消さない](../heuristics/mechanization-moves-dependency-not-removes-it.md)）。分類を regex full match へ委ねた瞬間、判定は reviewer の記述忠実性に依存するようになった。実測必須ゲートを helper へ機械化した後続の作業では同種の摩擦がさらに先鋭化し、**アンカー書式そのものについての repro を書くのに hex escape が必要**になっている。書式契約を扱う指摘が、その書式契約の中では表現できないという状況であり、契約の厳しさの傍証になる。

**適用条件**: `Verification:` アンカー付きのレビュー指摘を書くとき。repro にパイプ・改行タグを含める必要がある場合は、パイプを `¦` へ、改行を `<br>` のまま（日本語句点へ潰さない）保つ。

## 関連ページ

- [強制層の機械化は裁量を消すが依存を消さない](../heuristics/mechanization-moves-dependency-not-removes-it.md)
- [緩い検出述語の出力を停止条件へ昇格させてはならない](../anti-patterns/loose-detector-predicate-promoted-to-stop-condition.md)

## ソース

- [PR #2070 review results](../../raw/reviews/20260731T060239Z-pr-2070.md)
- [PR #2070 fix results](../../raw/fixes/20260731T060927Z-pr-2070.md)
