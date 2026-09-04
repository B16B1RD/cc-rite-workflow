---
type: "anti-patterns"
title: "bash 数値 env override 検証と算術評価の基数不一致（先頭ゼロの8進誤解釈）"
domain: "anti-patterns"
description: "運用者が上書き可能な数値 env var（例: `RITE_SESSION_LIVENESS_TTL_HOURS`）を `[[ \"$VAR\" =~ ^[0-9]+$ ]]` のような「10進数として妥当か」で検証しても、その値を後段で `$(( VAR * 3600 ))` のような bash 算術式にそのまま渡すと、先頭ゼロを含む値（`\"010\"` 等）は bash 算術の規則で **8進数として再解釈** される。"
created: "2026-07-20T05:14:41+00:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260720T051441Z-pr-1924.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-20T05:14:41+00:00" }
---

# bash 数値 env override 検証と算術評価の基数不一致（先頭ゼロの8進誤解釈）

## 概要

運用者が上書き可能な数値 env var（例: `RITE_SESSION_LIVENESS_TTL_HOURS`）を `[[ "$VAR" =~ ^[0-9]+$ ]]` のような「10進数として妥当か」で検証しても、その値を後段で `$(( VAR * 3600 ))` のような bash 算術式にそのまま渡すと、先頭ゼロを含む値（`"010"` 等）は bash 算術の規則で **8進数として再解釈** される。検証は10進、評価は文脈依存の基数、という不一致が原因。

## 詳細

worktree liveness guard へ TTL を導入した際、`RITE_SESSION_LIVENESS_TTL_HOURS` の検証が `^[0-9]+$ && -gt 0` だった時点で、code-quality-reviewer と error-handling-reviewer が cycle 3 で**独立に**同一バグを実機検証で発見した:

- `RITE_SESSION_LIVENESS_TTL_HOURS="010"`（運用者は10hのつもり）→ 検証は通過 → `$(( 010 * 3600 ))` は bash 算術で `010` を8進数として解釈し `8 * 3600` = 8h相当に silent 変換。9h前の生存 holder が誤って reap される（本 Issue が防ごうとしていた誤 reap をまさに再導入する）。
- `RITE_SESSION_LIVENESS_TTL_HOURS="08"` / `"09"`（8進として無効な桁）→ 検証は通過 → `$(( 08 * 3600 ))` は `08: 基底の値が大きすぎます` という生の bash エラーで即死。検証コメントが明言する「an invalid value must not silently corrupt the arithmetic with a raw bash error」という契約自体を破る。

**根本原因**: 「数値として妥当か」の検証（regex）と「その値をどう解釈して評価するか」（bash 算術の基数規則）が別の関心事であるにもかかわらず、前者を「10進の正の整数」のつもりで書きながら実際には「先頭ゼロを許す `^[0-9]+$`」という緩い pattern を使ってしまい、両者の暗黙の前提がずれていた。

**修正**: 正規表現を `^[1-9][0-9]*$` に変更する。先頭桁を `[1-9]` に限定することで「先頭ゼロを含む値」を構造的に拒否でき、生き残る値は常に bash 算術がそのまま10進として解釈する形になる。副次効果として、正の整数であることを保証するため `-gt 0` の追加チェックが完全に冗長になり削除できる（1条件に単純化）。

**教訓（汎用化）**: env var や外部入力を数値として bash 算術に渡す設計では、検証 regex は「後段の評価コンテキストが要求する厳密なフォーマット」に一致させる必要がある。`^[0-9]+$` は一見「数値」を検証しているようで、実際には「文字として数字の並び」を検証しているに過ぎず、bash 算術の基数規則（先頭 `0` = 8進、`0x` = 16進）という評価側の暗黙ルールとは独立している。この種の不一致は、デフォルト値や通常の運用値（先頭ゼロなし）では発火せず、**特定の誤設定形状（先頭ゼロ）でのみ顕在化する**ため、レビューでの実機検証（実際に値を入れて実行する）が静的読解より有効だった。

## 関連ページ

- [入力注入経路のない静的文字列処理連鎖は関数抽出 + 境界行 extract で非 vacuous unit テスト化する](../patterns/static-input-chain-function-extraction-non-vacuous-test.md)

## ソース

- [fix 結果](../../raw/fixes/20260720T051441Z-pr-1924.md)
