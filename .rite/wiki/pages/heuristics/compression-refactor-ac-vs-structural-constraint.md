---
title: "圧縮 refactor の AC は protected 区域 + scope 制約から逆算して決める"
domain: "heuristics"
created: "2026-05-04T09:50:00Z"
updated: "2026-05-04T09:50:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260504T090515Z-pr-809.md"
tags: ["refactor", "compression", "acceptance-criteria", "scope", "trade-off"]
confidence: high
---

# 圧縮 refactor の AC は protected 区域 + scope 制約から逆算して決める

## 概要

Markdown / Code 大規模圧縮 refactor で行数 AC を野心目標で決め打ちすると、protected 区域 (機械検証必須項目 / Pre-flight bash block / Return Output 等) と SPEC-OUT-OF-SCOPE 制約 (新規 references 作成禁止 / references 側 modify 禁止) の組み合わせで構造的に達成困難になり、user 介入による緩和が cycle 中盤で必要になる。AC は protected 行数 + scope 内圧縮可能行数から逆算で決めるのが正しい。

## 詳細

### 観測 (PR #809 / Issue #805)

`commands/issue/create-interview.md` の本体スリム化 PR で:

- 当初 AC: ≤200 行 (511 → 200、-61% を目標)
- protected 区域: Pre-flight bash block (41 行) + Return Output (67 行) = **約 100 行は削減不可**
- SPEC-OUT-OF-SCOPE: 新規 references 作成 / references 側 modify 禁止のため、本ファイル内圧縮のみが許される
- 結果: 構造的に ≤200 達成困難 → user 承認のもと **≤350 に緩和**、331 行で着地 (-35%)

兄弟 PR #803 (create.md: 734 → 334 行、-55%) は Moved blockquote 4 箇所が圧縮対象に含まれたため絶対削減量が大きかったが、本 PR は protected の比率が高く同水準は不可能だった。

### 失敗 mode

| ステージ | 失敗 |
|---------|------|
| 計画 | 兄弟 refactor の達成率 (-55%) を盲目的に転用して野心 AC (-61%) を設定 |
| 実装 | protected 区域と scope 制約を踏まえた逆算をしないまま着手 |
| 検証 | cycle 中盤で構造的不能と判明し user 介入で AC 緩和、Issue body も更新 |

### 逆算手順 (canonical)

圧縮 refactor の AC を決める前に以下を grep evidence で確認する:

1. **protected 区域の合計行数** を `wc -l` で測る (Pre-flight bash block / Return Output / 機械検証必須 anchor / DRIFT-CHECK ANCHOR ブロック等)
2. **scope 内で削減可能な区域の上限** を見積もる (重複箇所 / references 移譲可能箇所 / blockquote stub 化可能箇所の合計行数)
3. **AC = protected + (scope 内削減後の本文)** で逆算する。野心目標を立てるなら同時に「現実着地点」を併記し、cycle 中盤で構造的不能が判明した場合の緩和手順 (Issue body update / user 承認 / AC 再設定) も合意しておく
4. **兄弟 PR の達成率は protected 比率が異なれば転用できない**: protected 区域が小さく blockquote 圧縮余地が大きい兄弟と、protected 比率が高い本 PR は別物として扱う

### 関連する周辺観測

1. **NFR-2 protected 機械検証の有効性**: `4-site-symmetry.test.sh` のような自動 test が pass する限り、reviewer は protected 区域の意味論等価性を信頼指標として扱える。test がない protected 区域は reviewer 全員に semantic 等価性チェックを要求し verification cost が膨らむ → AC 緩和議論の遅延要因にもなる。protected 区域には機械検証 test を必ず併設する (PR #803 / #809 共通)
2. **Sole reviewer guard の有効性**: 1 reviewer のみの選定だった場合でも sole reviewer guard で異種 reviewer を追加すると、prompt-engineer (structure 妥当性) + code-quality (cross-file 完全性) のような相補的視点で 0 findings 確信度が向上する。AC 緩和判断の sign-off にも reviewer 多様性が寄与
3. **Compression による narrative 弱化**: 圧縮された narrative は意味論等価性を保つが、grep target としての rule label 喪失や相対参照の曖昧化を伴う (LOW level 推奨事項として典型的に出現)。AC 緩和を許容しても narrative の grep traceability は維持する方針が必要

## 関連ページ

- [Markdown 大規模圧縮 refactor 時の heading hierarchy skip](../anti-patterns/heading-hierarchy-skip-on-large-markdown-compression.md)
- [PR シリーズ間で stub 残置 markdown formatting を踏襲する](../patterns/pr-series-stub-format-consistency.md)

## ソース

- [PR #809 review findings: 0 findings, 5 recommendations (-35% slimdown)](../../raw/reviews/20260504T090515Z-pr-809.md)
