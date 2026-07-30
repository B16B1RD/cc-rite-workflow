---
type: "heuristics"
title: "テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する"
domain: "heuristics"
description: "fixture 変異がどの不変量を発火させるかは推測せず実行で確認する。一方向差し替えは集合系不変量も同時発火するため、行内整合チェックの分離検証には均衡入替（双方向 swap）を使う。双方向チェックの reverse 方向・行フィルタ等の guard は単独で kill する明示 TC / decoy が無いと削除 mutation が生き残る。"
created: "2026-07-03T18:30:00+00:00"
updated: "2026-07-03T18:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260703T164934Z-pr-1743.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T165654Z-pr-1743.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T180609Z-pr-1743.md"
tags: ["test", "fixture", "mutation", "invariant", "coverage"]
confidence: high
---

# テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する

## 概要

複数の不変量（集合差分 I1/I2 + 行内整合 I3 等）を持つ検証スクリプトのテストでは、fixture 変異の設計を誤ると「テストは green だが特定の不変量・guard を削除しても green のまま」という vacuous coverage が生まれる。変異がどの不変量を発火させるかは推測せず実行で確認し、各不変量・guard を**単独で** kill する配置（均衡入替 / reverse 方向の明示 pin / guard 射程内への decoy 配置）を採る。

## 詳細

起点事例（reviewer-registry-drift-check.test.sh、TC-1〜TC-11）の設計・レビューで実測した 3 つの配置原則。

### 1. 行内整合の分離検証には均衡入替（双方向 swap）を使う

- 一方向差し替え（charlie 行の Agent セルだけを delta に変更）は、charlie-reviewer.md が集合から消えるため**集合系不変量（I1/I2）も同時に発火**し、行内整合チェック（I3）の固有価値を分離検証できない
- 均衡入替（charlie 行 Agent=delta かつ delta 行 Agent=charlie）なら集合が保存され、I3 のみが発火する。さらに「集合差分 finding（"only in ..."）が混入しない」ことを負の assert で確認すると真に I3-isolated になる（TC-6）
- fixture 変異のコメントに「どの不変量が発火するか」を書く場合は、実行して観測してから書く（推測コメントは cycle 1 で事実不一致 MEDIUM として検出された）

### 2. 双方向チェックの reverse 方向は明示 TC で pin する

- I1 が「agents/ ⇔ Type Identifiers 双方向」でも、テストが forward 方向（agent 追加 → 表に無い）しか無いと、reverse 方向の report_diff 呼び出しを削除しても全 TC が green のまま（未 pin）
- reverse 方向（表に行があるのに agent プロファイルが無い = 存在しない subagent を spawn する failure mode）を単独で発火させる fixture（orphan 行の挿入）+ 方向ラベルの grep assert を明示 TC として追加する（TC-9）

### 3. guard を exercise する decoy は guard の射程内に置く

- 「セクション内散文がテーブル比較へ bleed しない」ための行フィルタ（`/^\|/`）を検証するつもりの decoy を**独立セクション外**に置くと、セクション境界除外だけで decoy が落ち、行フィルタを削除する mutation が生き残る（cycle 2 レビューで検出された coverage gap）
- decoy は検証したい guard だけが除外を担う位置（= 抽出対象セクションの内側の非テーブル行）に置き、負の assert で「decoy が finding に出ない」ことを固定する

### 検証の決定打

guard・不変量の TC を追加したら、worktree-only mutation（当該 guard / report_diff 呼び出しの削除、列挿入等）を実機注入して「その TC だけが FAIL する」ことを確認する。見た目の構造同型ではなく mutation の kill 実績が non-vacuous coverage の証明になる。

## 関連ページ

- [位置依存の表パースには検査行数ガードを対にする（silent false-pass 遮断）](../patterns/positional-parse-row-count-guard.md)

## ソース

- [PR #1743 review cycle 1（一方向差し替えの不変量誤帰属 + reverse 未 pin を検出）](../../raw/reviews/20260703T164934Z-pr-1743.md)
- [PR #1743 fix cycle 1（均衡入替 TC-6 + reverse pin TC-9 を適用）](../../raw/fixes/20260703T165654Z-pr-1743.md)
- [PR #1743 review cycle 2（pipe-filter decoy 配置の coverage gap を推奨事項として検出）](../../raw/reviews/20260703T180609Z-pr-1743.md)
