---
type: "anti-patterns"
title: "機械的一括置換は同一リテラルの役割差を無視すると load-bearing fixture を壊す"
domain: "anti-patterns"
promote: rite-plugin
description: "`/tmp/rite-*` → `${TMPDIR:-/tmp}/rite-*` のような一括 sed スイープは、同じ文字列でも**役割が違う出現**を巻き込むと意味論を壊す。スクラッチ置き場の mktemp は変換可だが、(1) 被テスト対象の path allowlist に一致させる load-bearing fixture、(2) `export TMPDIR` より後に評価される生成パス、(3) 文字列リテラル内部、の 3 種は変換の意味が正反対になる。起点事例で 3 reviewer が独立に同一箇所（TC-036a）を HIGH で指摘した実測。"
created: "2026-07-19T15:00:00+09:00"
updated: "2026-07-19T15:00:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260719T051605Z-pr-1910.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T051827Z-pr-1910.md"
  - type: "reviews"
    ref: "raw/reviews/20260719T053756Z-pr-1910-c2.md"
tags: []
confidence: high
---

# 機械的一括置換は同一リテラルの役割差を無視すると load-bearing fixture を壊す

## 概要

`/tmp/rite-*` → `${TMPDIR:-/tmp}/rite-*` のような一括 sed スイープは、同じ文字列でも**役割が違う出現**を巻き込むと意味論を壊す。スクラッチ置き場の mktemp は変換可だが、(1) 被テスト対象の path allowlist に一致させる load-bearing fixture、(2) `export TMPDIR` より後に評価される生成パス、(3) 文字列リテラル内部、の 3 種は変換の意味が正反対になる。起点事例で 3 reviewer が独立に同一箇所（TC-036a）を HIGH で指摘した実測。

## 詳細

起点事例（テストハーネスの mktemp TMPDIR 化）で、28 箇所の機械変換のうち 3 種の「変換してはならない出現」が混入した:

1. **load-bearing fixture**: TC-036a の content-file は被テスト hook（wiki-ingest-trigger.sh）の path-containment allowlist（`$PWD/* | /tmp/rite-* | /private/tmp/rite-*`）に一致させるための fixture。TMPDIR 化すると TMPDIR≠/tmp の環境（sandbox・macOS）で hook が**正しく拒否**して偽 FAIL し、かつ本来検証すべき `/tmp/rite-*` prefix 受容を検証しなくなる。修正は literal 復元 + 書込不可環境での writability probe → 明示 SKIP。
2. **export 後評価の生成パス**: pr-cycle-cleanup.test.sh の `make_temp_repo` は `export TMPDIR="$WORKDIR_SCAN_TMP"` より**後**に `${TMPDIR:-/tmp}` を評価するため、テスト repo が GC 走査対象 dir の**内側**に生成されるようになり、直上コメントの隔離不変条件と矛盾した（prefix 非マッチ + age guard で偶然 PASS する暗黙依存に劣化）。修正は export **前**に `HOST_TMPDIR="${TMPDIR:-/tmp}"` を退避し、生成側は HOST_TMPDIR 基準にする。
3. **文字列リテラル内部**: `echo "WARNING: ... mktemp "${TMPDIR:-/tmp}/..." failed"` — 既に quote された文字列内部への機械挿入は quote 構造を壊し、パスが非クォート展開になる。

**変換可否の判別基準**: 生成物が (a) 被テスト対象の path 検証に渡るか、(b) `export TMPDIR` 等で意味が変わる評価タイミングにあるか、(c) 文字列リテラル・コメント内か — いずれかに該当する出現は個別判断する。sed の一括適用前に、対象リテラルの各出現の「読み手」を確認する。

**mock intercept の対称原則**（正しい変換の例）: mock mktemp の intercept pattern は「mock は被テスト hook の**子プロセス**として同一 TMPDIR を継承する」性質により、`/tmp/... | "${TMPDIR:-/tmp}"/...` の両形 arm にすると TMPDIR 設定有無の両環境で正しく発火する（TMPDIR 未設定時は重複 arm となり無害）。本番側が #1902 で TMPDIR 化された後、mock 側の旧 `/tmp` 単一 arm は sandbox で intercept を取り逃し失敗分岐が未検証のまま偽 PASS していた — base で 2 FAIL → 修正後 0 FAIL を runtime 実証。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [保存パス基準の変更は観測面と全 caller 引数の同時スイープが必要](../heuristics/path-basis-change-observation-surface-sweep.md)

## ソース

- [PR #1910 review results (cycle 1)](../../raw/reviews/20260719T051605Z-pr-1910.md)
- [PR #1910 fix results (cycle 1)](../../raw/fixes/20260719T051827Z-pr-1910.md)
- [PR #1910 review results (cycle 2 mergeable)](../../raw/reviews/20260719T053756Z-pr-1910-c2.md)
