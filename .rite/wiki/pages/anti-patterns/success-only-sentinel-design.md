---
title: "Success-only Sentinel Design — sub-skill abort path sentinel 未定義"
domain: "anti-patterns"
created: "2026-05-14T05:30:00+00:00"
updated: "2026-05-14T05:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260514T043949Z-pr-951.md"
  - type: "fixes"
    ref: "raw/fixes/20260514T045140Z-pr-951.md"
tags: []
confidence: medium
---

# Success-only Sentinel Design — sub-skill abort path sentinel 未定義

## 概要

sub-skill 切出し時に success path 用 HTML sentinel (`<!-- [skill:phase:completed] -->`) のみを定義し、abort path / error path 用 sentinel を未定義のまま残す anti-pattern。caller orchestrator が success / abort / error の 3 経路を grep-able に区別できないため、abort 経路で implicit stop / 誤 routing が発生する。

## 詳細

### 観測

PR #951 (`/rite:issue:start` 再設計の PR F、Phase 5.0-5.2.1 を `start-execute.md` sub-skill に抽出) の cycle 1 で CRITICAL として検出。新規 HTML sentinel `<!-- [start:execute:completed] -->` が **success path のみ** に定義され、Phase 5.0 (Stop Hook) / Phase 5.2 (Lint) の **abort 経路に sentinel が無かった**。caller (本体 `start.md`) は sub-skill return 後に sentinel を grep して routing するため、abort 時に「sub-skill が完了したのか途中で止まったのか」を判別できず、orchestrator が implicit stop する経路が開く。

### 失敗モード

- success path sentinel 1 種類だけだと「sub-skill return = success」と「sub-skill return = abort」が同じ shape になる
- caller 側の continuation trigger (`grep -F '[skill:phase:completed]'`) が abort 経路でも match してしまい、誤って次 Phase へ遷移する
- 逆に「sentinel 未出力 = abort と判定」する hack で逃げると、success 経路で sentinel emit に失敗した transient 障害と区別できず incident detection が不正確になる

### 原則

sub-skill 設計時は **success / abort / error の 3 経路すべてに sentinel を定義** すること。最低限以下のいずれか:

| 経路 | sentinel 例 |
|------|-------------|
| success | `<!-- [skill:phase:completed] -->` |
| abort (pre-condition gate trip / explicit user abort) | `<!-- [skill:phase:aborted] -->` |
| error (uncaught exception / fail-fast) | `<!-- [skill:phase:errored] -->` |

caller 側 routing dispatcher は 3 種類の sentinel を **排他的に grep** して経路を確定させる。`phase-transition-whitelist.sh` 等の post-hoc 整合性チェックも 3 経路の sentinel を考慮した allow-list を持つこと。

### 検出パターン

- sub-skill 抽出 PR で本体側 phase 名が `phase_post_X` で終わる sentinel 1 種類しか定義されていない場合は警戒
- caller 側 routing が「sentinel あり = continue / sentinel なし = stop」の 2 値 routing になっている場合は abort 経路の sentinel 欠落の signal

### 派生 (関連経験則)

[[asymmetric-fix-transcription]] の "design path 対称性" 拡張（contract-implementation path 対称性として一般化済み）の sub-case とも言える: 「契約宣言時に section 内の全 path (normal/early-return/error/disable) が契約を満たすか verify し忘れる」失敗を sentinel design 次元で具体化したもの。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #951 fix results (10 findings, 1 cycle)](../../raw/fixes/20260514T045140Z-pr-951.md)
