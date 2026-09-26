---
type: "heuristics"
title: "名前順で最新を読む判定をテストする fixture は、cycle ごとに保存秒をずらして衝突を避ける"
domain: "heuristics"
description: "結果ファイルの保存時刻が秒単位で衝突すると、同秒内では乱数 suffix によって名前の並びが不定になる。名前順で「最新」を選ぶ実装を検証するテストの fixture は、cycle ごとに保存秒をずらして、この不定な並びに依存せず結果を再現可能にする。"
created: "2026-09-26T07:12:24+00:00"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T07:15:00+00:00" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260926T071224Z-pr-3120.md"
tags: []
confidence: medium
---

# 名前順で最新を読む判定をテストする fixture は、cycle ごとに保存秒をずらして衝突を避ける

## 概要

保存時刻を含むファイル名で「最新」を選ぶ実装（例: `LC_ALL=C sort` で名前順の末尾を取る）を検証するテストで、複数 cycle の結果ファイルが同じ秒に保存されると、同秒内の順序は乱数 suffix に左右され不定になる。fixture 側で cycle ごとに保存の秒をずらすことで、この不定性に依存しないテストにする。

## 詳細

再試行権を発行した run が iterate から再試行の review に進めなかった不具合の修正で追加したテストは、複数 cycle の結果ファイルを短時間に連続して保存する。保存時刻が秒単位でしか記録されないため、テスト実行が高速だと複数 cycle が同じ秒に保存され、「最新」を選ぶ実装が読む順序（同秒内は乱数 suffix 順）とテストが期待する順序（cycle の生成順）が一致しない、という非決定的な失敗が生まれる。

対処として、fixture 側で cycle ごとに保存の秒を意図的にずらす（例えば cycle 間に 1 秒以上の間隔を空けて保存する、またはタイムスタンプを明示的に指定する）ことで、名前順の判定が常に cycle の生成順と一致するようにした。これにより、実装側の「最新」選択ロジックを変更せずに、テストの再現性を確保できる。

## 関連ページ

- [「最新」を選ぶ列挙は照合順を LC_ALL=C に固定する](../patterns/latest-selection-pins-byte-collation.md)

## ソース

- [fix 結果](../../raw/fixes/20260926T071224Z-pr-3120.md)
