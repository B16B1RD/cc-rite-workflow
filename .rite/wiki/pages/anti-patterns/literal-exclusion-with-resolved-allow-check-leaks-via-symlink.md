---
type: "anti-patterns"
title: "除外は字面で、許可判定は symlink 解決後で比べる二重基準は、symlink 経由で許可集合を広げる"
domain: "anti-patterns"
description: "検査対象からの除外を文字列一致で決め、許可判定は symlink を解決したパスで比べると、除外対象に symlink が混ざったとき解決先のツリー全体が許可集合に入る。片方の検査だけ直しても、同じ仕組みの別の検査から抜ける。"
created: "2026-09-26T08:46:38Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T08:46:38Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T083635Z-pr-3129.md"
tags: ["symlink", "path-check", "allowlist", "test-fixture"]
confidence: medium
---

# 除外は字面で、許可判定は symlink 解決後で比べる二重基準は、symlink 経由で許可集合を広げる

## 概要

検査対象からの除外を文字列一致で決め、許可判定は symlink を解決したパスで比べると、除外対象に symlink が混ざったとき解決先のツリー全体が許可集合に入る。片方の検査だけ直しても、同じ仕組みの別の検査から抜ける。

## 詳細

除外の判定と許可の判定が別のパス表現を使うと、その差が穴になる。除外側は「このパス文字列は対象外」と字面で決めるので symlink を追わない。許可側は解決後の実体で比べるので、除外されたはずの symlink が指す先を、許可されたツリーとして数えてしまう。

穴は検査ごとに塞いでも閉じない。ある検査で symlink を除外対象から戻しても、同じ許可集合を使う別の検査が同じ仕組みで抜ける。塞ぐ単位は個々の検査ではなく、「その入力が許可集合にどう寄与するか」である。除外と許可を同じ正規化（解決後のパス）で判定するか、許可集合を作る段階で symlink の寄与を止める。

分岐を分けて片側だけを除外する変更では、除外される側の挙動をテストで固定しておく。固定が無いと、逆向きの「簡約」（除外を外す、分岐を統合する）も green のまま通る。境界の両側、つまり許可される例と拒否される例を同じ fixture で pin する。

## 関連ページ

- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T083635Z-pr-3129.md)
