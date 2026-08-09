---
type: "patterns"
title: "失敗状態のクリアは失敗の記録より後に置く"
domain: "patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/patterns/clear-failure-state-after-recording-it.md"
promoted_from: "wiki:/pages/patterns/clear-failure-state-after-recording-it.md"
description: "「失敗を記録する」処理と「失敗状態をクリアする」処理が別ステップにあるとき、クリアを先に置くと、その隙間で中断したケースがすべて無記録の成功に化ける。クリアを記録の後に置けば、途中で落ちても「まだ失敗状態」に留まる（停止側へ縮退する）。PR #2044 では counter リセットの導入が、意図せず既存の安全網の自己修復性を外していた。"
created: "2026-07-29T21:32:36+09:00"
updated: "2026-07-29T21:32:36+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260729T042319Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T043110Z-pr-2044.md"
tags: []
confidence: high
---

# 失敗状態のクリアは失敗の記録より後に置く

## 概要

サーキットブレーカー発火時に cycle counter を 0 へリセットする設計（「再実行でループを再開できる」ため）を入れたが、そのリセットは発火を記録する唯一の手段である sentinel emit より**手前**にあった。両者の隙間で turn が終わると、**発火が無記録のまま counter だけ 0 になる**。同じ `flow-state.sh set` が継続 handoff も消しているため Stop hook は停止を許可し、次回の recover は満額の予算でループを再開する。

## 詳細

### リセットの導入が安全網の自己修復性を外した

この欠陥の非自明な点は、**修正前のほうが安全だった**ところにある。リセットを入れる前は counter が上限のまま残るため、記録に失敗しても次回起動で即座に再発火して自己修復していた。リセットの導入がその自己修復性を意図せず取り去っている。

つまり「再開可能性を上げる修正」が「失敗の永続性」を犠牲にしていた。**状態をクリアする変更を入れるときは、そのクリアが既存のどの安全網を無効化するかを問う。**

### 判断の型

「失敗を記録する処理」と「失敗状態をクリアする処理」が別ステップにあるなら、**クリアは記録の後**に置く。理由は縮退の向きにある。

| 順序 | 隙間で中断したとき |
|---|---|
| クリア → 記録 | 失敗が消え、記録も無い → **無記録の成功**に化ける |
| 記録 → クリア | 記録は残り、失敗状態も残る → **停止側**に留まる |

縮退の向きで設計を選ぶ判断基準としてそのまま使える。

### 窓は狭められても消えないことがある

本 PR の最終的な修正はリセットを sentinel の直前へ移すもので、中断窓を「review invoke + ステップ 6 全体」から「共有前段 → sentinel 出力」へ**狭めた**が消してはいない。完全な閉塞には Stop hook 側の改修（Issue の Non-Target）が必要だった。

このとき散文を「そういう経路を持たない」と書くと嘘になる — 詳細は Scope drift fix での overclaim substitution (`Wiki provenance: ../anti-patterns/scope-drift-fix-overclaim-substitution.md`) を参照。**窓を狭めたら、残った窓の大きさと、完全閉塞に何が要るかを書く。**

### 検証は A/B 対比で示す

散文（Markdown 埋め込み bash）の修正でも A/B 対比の実測が有効だった。修正後のブロックと、修正前相当（sed で 1 行戻した版）を同じ stub 環境で走らせ、「fire → ステップ 6 未到達で中断 → resume」の 1 シナリオで両者の marker を並べて観測している。**「直った」ことの証拠は、修正後の正しい出力ではなく修正前との差分で示すほうが強い。**

## 関連ページ

- 終端状態は「到達した事実」で記録し、可変値との境界比較で代用しない (`Wiki provenance: ../heuristics/terminal-state-recorded-not-boundary-compared.md`)
- Scope drift fix での overclaim substitution (置換後に新たな過剰主張を持ち込む) (`Wiki provenance: ../anti-patterns/scope-drift-fix-overclaim-substitution.md`)
- Asymmetric Fix Transcription (対称位置への伝播漏れ) (`Wiki provenance: ../anti-patterns/asymmetric-fix-transcription.md`)

## ソース

- PR #2044 review results (cycle 2) (`Wiki provenance: ../../raw/reviews/20260729T042319Z-pr-2044.md`)
- PR #2044 fix results (cycle 2) (`Wiki provenance: ../../raw/fixes/20260729T043110Z-pr-2044.md`)
