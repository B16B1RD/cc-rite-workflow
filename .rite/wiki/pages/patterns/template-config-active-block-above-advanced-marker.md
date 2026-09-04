---
title: "config テンプレートの default-on 設定は Advanced マーカーより上に配置する"
domain: "patterns"
description: "`templates/config/rite-config.yml` のある設定を「新規プロジェクトでデフォルト ON」にしたいなら、その active ブロックを `# --- Advanced (below this line) ---` マーカーより **上** に置く。"
promote: rite-plugin
created: "2026-06-11T00:57:13+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260610T155713Z-pr-1392.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-11T00:57:13+09:00" }
---

# config テンプレートの default-on 設定は Advanced マーカーより上に配置する

## 概要

`templates/config/rite-config.yml` のある設定を「新規プロジェクトでデフォルト ON」にしたいなら、その active ブロックを `# --- Advanced (below this line) ---` マーカーより **上** に置く。`/rite:init` の新規生成（`init.md` Step 2 / Phase 4.1.2 Step 2）はマーカー以降を omit するため、マーカーより下で active 化しても新規 config に emit されず、`pr:open` の parse fallback で意図と逆の値（例: `false`）に落ちる。

## 詳細

起点事例（`multi_session.enabled` を default off→on 化）で実測。AC は「テンプレートで `multi_session:` ブロックをコメントアウト解除し `enabled: true` にする」だったため、ブロックをその場（マーカー下）で active 化した。機械チェック・YAML・1 回目レビューはすべて通過したが、cycle 2 で code-quality reviewer が HIGH を検出: マーカー下の active ブロックは新規生成で omit され、新規プロジェクトは `multi_session:` ブロック不在 → parser の `*) ms_enabled=false` fallback で `false` に落ちる。結果「新規プロジェクトは default on を得る」という PR の中核主張が実挙動と全面矛盾していた。

**SoT となる先例**: `wiki:` セクションは先行 PR でまさに同じ問題を避けるため、コメント形式・マーカー下から active・マーカー上へ移動された（`flow_state:` も同様にマーカー上の active ブロック）。default-on にしたい設定は「wiki / flow_state と同じ列」に並べる、が判断基準。

**修正の全体像**（cycle 2）:
1. テンプレート: active ブロックをマーカー上（`flow_state:` 直後）へ移動。マーカー下の重複は削除。
2. `init.md` Step 4 の `--upgrade` 分類: 既存プロジェクトの後方互換（「既存 config は不変」）を保つため、当該キーを generic な "Missing section → Add active" から **除外** する専用行を追加（wiki は upgrade で back-add するが、このケースは back-add しない＝非対称。両者を分類表に明示）。

**検証手段**（机上 grep を信用せず実機で確認する）: `sed '/# --- Advanced/Q' template | grep '^{key}:'` で新規生成範囲に含まれるか、`pr:open` の parse ロジックを抽出済み config に対して実行して期待値（`true`）になるかをシミュレートする。

**周辺で同時に観測した関連 failure（同 PR）**:
- 設計思想転換（opt-in→default on）系 PR では、残存矛盾記述の grep が **語順違い**（`false (default)` / `false（デフォルト）`）で見逃されやすい。複数語順を網羅した grep が必要。
- CHANGELOG の「影響ファイル」列挙は fix サイクルで新規に変更したファイル（後続 cycle で触った `workflow.md` / `init.md`）の追記漏れが起き、同種 MEDIUM が複数 cycle で再発する。fix で新ファイルを触ったら CHANGELOG 列挙も更新する。

## 関連ページ

- （関連ページなし）

## ソース

- [レビュー結果](../../raw/reviews/20260610T155713Z-pr-1392.md)
