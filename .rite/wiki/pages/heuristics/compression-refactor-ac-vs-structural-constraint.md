---
title: "圧縮 refactor の AC は protected 区域 + scope 制約から逆算して決める"
domain: "heuristics"
description: "Markdown / Code 大規模圧縮 refactor で行数 AC を野心目標で決め打ちすると、protected 区域 (機械検証必須項目 / Pre-flight bash block / Return Output 等) と SPEC-OUT-OF-SCOPE 制約 (新規 references 作成禁止 / references 側 modify 禁止) の組み合わせで構造的に達成困難になり、user 介入による緩和が cycle 中盤で必要になる。"
promote: rite-plugin
created: "2026-05-04T09:50:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260504T090515Z-pr-809.md"
  - type: "reviews"
    resource: "raw/reviews/20260707T005014Z-pr-1774.md"
  - type: "reviews"
    resource: "raw/reviews/20260812T180508Z-pr-2278.md"
tags: ["refactor", "compression", "acceptance-criteria", "scope", "trade-off"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-12T18:34:40Z" }
---

# 圧縮 refactor の AC は protected 区域 + scope 制約から逆算して決める

## 概要

Markdown / Code 大規模圧縮 refactor で行数 AC を野心目標で決め打ちすると、protected 区域 (機械検証必須項目 / Pre-flight bash block / Return Output 等) と SPEC-OUT-OF-SCOPE 制約 (新規 references 作成禁止 / references 側 modify 禁止) の組み合わせで構造的に達成困難になり、user 介入による緩和が cycle 中盤で必要になる。AC は protected 行数 + scope 内圧縮可能行数から逆算で決めるのが正しい。

## 詳細

### 観測

`commands/issue/create-interview.md` の本体スリム化 PR で:

- 当初 AC: ≤200 行 (511 → 200、-61% を目標)
- protected 区域: Pre-flight bash block (41 行) + Return Output (67 行) = **約 100 行は削減不可**
- SPEC-OUT-OF-SCOPE: 新規 references 作成 / references 側 modify 禁止のため、本ファイル内圧縮のみが許される
- 結果: 構造的に ≤200 達成困難 → user 承認のもと **≤350 に緩和**、331 行で着地 (-35%)

兄弟 PR (create.md: 734 → 334 行、-55%) は Moved blockquote 4 箇所が圧縮対象に含まれたため絶対削減量が大きかったが、本 PR は protected の比率が高く同水準は不可能だった。

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

### 追加観測: AC 数値目標と原則ベース基準の乖離時は cap 達成側を採用する

review/fix SKILL.md（各 4,040 行）のコンテキストダイエット PR で、AC-1（25% 削減）に対し実績 fix 8.2% / review 13.1% と未達だったが、本体の 48% が AC-2（bash 非コメント行 diff ゼロ）で不変義務のある bash フェンスであり、残余も reason 表・分岐表・sentinel 表など実行時必須情報が大半で、忠実に narration のみを退避する限り 25% は構造的に届かないことが示された。rationale 退避で削れる余地の枯渇を根拠に、数値目標側ではなく原則ベース基準（実測に基づく 4,000 行 cap）の達成側を採用する判断が承認された。逆算手順 3 の「野心目標と現実着地点の併記 + 緩和手順の合意」が protected 比率の高い skill ファイルでも再現することを追検証した事例。

### 関連する周辺観測

1. **NFR-2 protected 機械検証の有効性**: `4-site-symmetry.test.sh` のような自動 test が pass する限り、reviewer は protected 区域の意味論等価性を信頼指標として扱える。test がない protected 区域は reviewer 全員に semantic 等価性チェックを要求し verification cost が膨らむ → AC 緩和議論の遅延要因にもなる。protected 区域には機械検証 test を必ず併設する（複数 PR で共通）
2. **Sole reviewer guard の有効性**: 1 reviewer のみの選定だった場合でも sole reviewer guard で異種 reviewer を追加すると、prompt-engineer (structure 妥当性) + code-quality (cross-file 完全性) のような相補的視点で 0 findings 確信度が向上する。AC 緩和判断の sign-off にも reviewer 多様性が寄与
3. **Compression による narrative 弱化**: 圧縮された narrative は意味論等価性を保つが、grep target としての rule label 喪失や相対参照の曖昧化を伴う (LOW level 推奨事項として典型的に出現)。AC 緩和を許容しても narrative の grep traceability は維持する方針が必要

### 行数は散文削減の指標として弱い — 主指標は散文バイト数にする（実測）

圧縮 refactor の AC を総行数で決めると、削減の実態を大きく見誤る。SKILL.md の散文ダイエットで実測した内訳:

| 指標 | before | after | 差 |
|---|---|---|---|
| 総行数 | 642 | 615 | -4.2% |
| 散文行数 | 136 | 112 | -17.6% |
| **散文バイト数** | 19,238 | 12,359 | **-35.8%** |
| 機械レール バイト数 | 15,465 | 15,465 | ±0（逐語一致） |

総行数の 8 割が機械レール 305 行 + 空行 158 行 + 見出し 40 行で占められ、そもそも散文は 136 行しかない。加えて日本語散文は 1 行が長い（削減前 141 B/行）ため、行数で測ると効果が縮んで見える。

削減作業を diff の hunk 単位で機械分類すると、**退避**（rationale を references へ移し 1 行ポインタ化）が 12 hunk で -3,766 B、**圧縮**（行動列挙・ナレーション・反復 MUST をその場で再構成）が 36 hunk で -3,116 B だった。退避は hunk あたりの効きが圧縮の数倍で、かつ判断をほとんど伴わないため、**削減の過半は安価なホストへ回せる**。

> **規則**: 散文削減の AC は散文バイト数を主指標にする。行数目標を置くなら、機械レール・空行・見出しを除いた散文行のみを対象にする。見せかけの行数調整で数字を作るより、指標を実態に合わせて報告し直す方が正しい。

## 関連ページ

- [Markdown 大規模圧縮 refactor 時の heading hierarchy skip](../anti-patterns/heading-hierarchy-skip-on-large-markdown-compression.md)
- [PR シリーズ間で stub 残置 markdown formatting を踏襲する](../patterns/pr-series-stub-format-consistency.md)

## ソース

- [PR #809 review findings: 0 findings, 5 recommendations (-35% slimdown)](../../raw/reviews/20260504T090515Z-pr-809.md)
- [PR #1774 review results](../../raw/reviews/20260707T005014Z-pr-1774.md)
- [PR #2278 review results (cycle 5) — 行数 vs 散文バイトの実測と退避/圧縮の hunk 別内訳](../../raw/reviews/20260812T180508Z-pr-2278.md)
