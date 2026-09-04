---
type: "anti-patterns"
title: "過剰マッチ防止の精緻化修正は、実装が許容する全形状を再確認しないと過小マッチという別の欠陥を生む (振り子現象)"
domain: "anti-patterns"
promote: rite-plugin
description: "reviewer の false-positive 指摘 (「この記述は無関係な対象まで拾ってしまう」) を受けて記述を厳密化する修正は、対象実装 (正規表現・マッチングロジック等) が実際に許容する**全ての**正当な形状を再確認せずに行うと、修正前には正しくカバーできていた別の形状を取りこぼす under-match を新規に導入する。"
created: "2026-07-07T22:03:17+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260706T214706Z-pr-1773-cycle2.md"
  - type: "fixes"
    resource: "raw/fixes/20260706T214905Z-pr-1773-cycle2.md"
tags: ["docs-drift", "precision-regression", "review-fix-loop", "regex-verification"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-07T22:03:17+00:00" }
---

# 過剰マッチ防止の精緻化修正は、実装が許容する全形状を再確認しないと過小マッチという別の欠陥を生む (振り子現象)

## 概要

reviewer の false-positive 指摘 (「この記述は無関係な対象まで拾ってしまう」) を受けて記述を厳密化する修正は、対象実装 (正規表現・マッチングロジック等) が実際に許容する**全ての**正当な形状を再確認せずに行うと、修正前には正しくカバーできていた別の形状を取りこぼす under-match を新規に導入する。過剰と過小の間を往復する「振り子」のような regression パターン。

## 詳細

### 発見経緯（cycle 1→2）

cycle 1 のレビューで、アンインストール手順ドキュメント内のレガシー hook 削除ガイダンスが「`rite/hooks/` という文字列を含むパスを削除対象とする」という緩い記述になっており、`favorite/hooks/foo.sh` のような無関係なパスまで誤って対象に含めてしまう false-positive リスクを指摘された (MEDIUM)。cycle 1 の fix はこれを「command パスに `rite/hooks/` を**完全な path segment**として含む」という、より厳密な記述に書き換えて対処した。

cycle 2 のレビューで、tech-writer が cycle 1 の修正を独立に再検証した結果、この「完全な path segment」という記述が、実装 (`settings-local-rite-hook-cleanup.py:33` の正規表現 `(?:^|/)rite/(?:[^/]+/)?hooks/`) が実際に許容する形状よりも**狭い**ことを発見した。実装の正規表現は `rite/` と `hooks/` の間に任意のバージョンセグメント (`(?:[^/]+/)?`) を許容しており、marketplace キャッシュ経由のインストールで実際に発生する `.../rite/0.7.0/hooks/foo.sh` のような形状も正当にマッチさせる設計だった。cycle 1 の「完全な path segment」という表現は、連続した `rite/hooks/` のみを想定しており、バージョンセグメントを挟む正当な形状を排除してしまっていた (MEDIUM)。

つまり:
- **修正前** (cycle 0): 緩すぎる (`favorite/hooks/` を誤って含む over-match)
- **cycle 1 修正**: 厳しすぎる (`rite/0.7.0/hooks/` を誤って除外する under-match)
- **cycle 2 修正**: 実装の正規表現を独立に再導出し、バージョンセグメントを許容する記述に修正して両立

### Root cause

cycle 1 の修正は「false-positive を潰す」という指摘の症状にのみ対応し、対象実装のロジックが持つ**全ての**正当な入力形状を再検証しなかった。精度を上げる方向の修正 (過剰マッチの解消) は、その副作用として意図しない過小マッチを生みうるという非対称なリスクがあり、「一部の誤りを直した」という達成感が、「直した結果何を排除してしまったか」の検証を省略させやすい。

### 一般化した教訓

reviewer 指摘に応じてマッチング条件・記述範囲を「より厳密に」書き換える修正を行う際は:

- 修正案を確定する前に、**対象実装 (正規表現・パターンマッチ・条件分岐等) を再度 Read/Grep し、その実装が現在許容している全ての正当な入力形状を洗い出す**こと。これは cycle 1 で一度実装を参照していたとしても、修正のたびに再確認が必要
- 「これは間違って X も拾ってしまう」という over-match の指摘への対処は、単に条件を厳しくするだけでなく、「厳しくした結果、実装が許容する Y という正当な形状を排除していないか」を対称的に検証する
- 実装のテストケース (存在する場合) を修正後の記述と突き合わせ、既知の正当な入力形状 (本件ではバージョンセグメント付きパス) がすべて記述でカバーされているか確認する

本パターンは [Asymmetric Fix Transcription](./asymmetric-fix-transcription.md) が扱う「同じ修正を対称位置へ伝播し忘れる」失敗モードとは異なり、**単一箇所の修正がその精緻化の副作用として新たな欠陥を生む**という、fix cycle 内で完結する regression である点が特徴。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](../heuristics/docs-review-implementation-grep-verification.md)

## ソース

- [修正の副作用として under-match 新規導入を検出、MEDIUM](../../raw/reviews/20260706T214706Z-pr-1773-cycle2.md)
- [実装の正規表現を再導出しバージョンセグメント許容の記述へ修正](../../raw/fixes/20260706T214905Z-pr-1773-cycle2.md)
