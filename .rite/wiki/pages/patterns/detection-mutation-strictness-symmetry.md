---
title: "検出 grep と mutation (Edit old_string) は同一の文字列 strictness で実装する"
domain: "patterns"
created: "2026-04-19T03:30:00+00:00"
updated: "2026-04-19T03:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260419T034237Z-pr-586-cycle5.md"
tags: []
confidence: high
---

# 検出 grep と mutation (Edit old_string) は同一の文字列 strictness で実装する

## 概要

「存在 check → exact 操作」のような 2 段階処理で、検出側 (`grep -qF prefix`) と操作側 (Edit の `old_string` exact match) で文字列の strictness が異なると、「検出 OK → 操作 fail」の中途半端な状態に陥り hard fail を生む。両者で **完全に同じ exact 文字列** を使うのが canonical。

## 詳細

### 発生事例 (PR #586 cycle 5)

`/rite:wiki:init` Phase 1.3:

- Phase 1.3.1 anchor 存在 check (L142): `grep -qF prefix-only` (loose — `# <<< gitignore-wiki-section-end` までの prefix のみ)
- Phase 1.3.3 Edit ツール `old_string` (L219): `prefix + suffix` (exact — `# <<< gitignore-wiki-section-end (anchor / F-09 対応)` まで完全一致要求)

consumer が anchor の suffix 部分 (`(anchor / F-09 対応)` の文言) を独自編集している場合、Phase 1.3.1 は通過するが Phase 1.3.3 が `old_string not found` で hard fail する経路 (F-04 として cycle 5 review で MEDIUM 検出)。さらに、cycle 4 で追加した `anchor_absent` 救済経路すらこのケースでは発動しないため silent failure が拡大する。

### 失敗の構造

1. 検出側は「存在するか」だけ調べれば良いので自然と loose に書きがち (`grep -qF <短めの prefix>`)
2. 操作側は Edit ツールが exact match を要求するため strict にならざるを得ない
3. 両者を別タイミングで書いた結果、strictness の gap が生まれる
4. consumer / future-self が文字列の一部を変更すると gap に落ちる

### Canonical pattern

1. **検出と操作で同じ literal 文字列を使う**: `grep -qF "${exact_old_string}"` と `Edit old_string="${exact_old_string}"` を共通変数 / 共通定数で参照させる
2. **検出が loose 版しか書けない場合は、操作側に fallback を用意**: Edit が hard fail した際に WARNING + 末尾追記 / skip 経路を取る
3. **救済経路の前提条件を明示**: cycle 4 の `anchor_absent` 救済は「anchor が完全に無い」ケースのみを救い、「anchor prefix はあるが suffix が編集されている」ケースは救わない。前提を明示して偽の安心感を避ける

### 検出手段

- PR レビュー時に、同一 target (ファイル / 文字列) を扱う grep と Edit を `git diff` で並べて比較し、strictness が揃っているか確認する
- canonical pattern を reference 文書に明記し、将来的に `/rite:lint` で grep + Edit 対称性を機械検証する

## 関連ページ

- [自 repo 固有 anchor を Edit old_string に hardcode すると consumer project で hard fail する (dogfooding bias)](../anti-patterns/dogfooding-anchor-hardcode.md)
- [state machine を 2 箇所で記述する場合は動作の文字列レベルで同期する](./state-machine-dual-location-sync.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)

## ソース

- [PR #586 cycle 5 review (F-04 strictness 非対称検出)](../../raw/reviews/20260419T034237Z-pr-586-cycle5.md)
