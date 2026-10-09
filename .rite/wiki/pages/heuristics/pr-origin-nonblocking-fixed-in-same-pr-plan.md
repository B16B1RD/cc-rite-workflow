---
type: "heuristics"
title: "PR 起因と判定した非 blocking の候補は、同じ PR の fix の計画に入れて直す"
domain: "heuristics"
promote: rite-plugin
description: "採否ゲートは PR 起因の候補を外部へ起票せず保留するため、非 blocking でも残すと完了やマージ後の cleanup で止まる。停滞診断の見直しを受けたら blocking と同じ PR 起因の非 blocking もまとめて計画に入れ、mergeable 後に見つかった欠陥も手で commit せず計画を通して直す。"
created: "2026-09-29T16:54:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-09T19:10:23Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-09T19:10:23Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260929T134642Z-pr-3452.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T153014Z-pr-3452.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T162319Z-pr-3728.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T164231Z-pr-3729.md"
tags: ["adoption-gate", "non-blocking", "review-loop"]
confidence: medium
---

# PR 起因と判定した非 blocking の候補は、同じ PR の fix の計画に入れて直す

## 概要

採否ゲートは PR 起因の候補を外部へ起票せず保留するため、非 blocking でも残すと完了やマージ後の cleanup で止まる。停滞診断の見直しを受けたら blocking と同じ PR 起因の非 blocking もまとめて計画に入れ、mergeable 後に見つかった欠陥も手で commit せず計画を通して直す。

## 詳細

採否ゲートの出口は、根因が PR の差分から生まれた候補（origin が PR）を採用するとき「同じ PR の中で直す」と決め、外部への起票を許さない。PR の中で直されずに残った候補は保留として扱われ、NB sweep でも、マージ後の cleanup の follow-up 判定でも先へ進めなくなる。マージ後は同じ PR で直す手段が無いため、保留は人間への報告で止まる。

このため、停滞診断の見直し（replan）を受けたら、blocking の指摘だけでなく同じ PR 起因の非 blocking もまとめて fix の計画に入れる。NB sweep の採否ゲートが PR 起因として保留した根因も同じ扱いで、同じ PR の fix の計画に入れて直す。mergeable の判定後に手で commit すると次のレビューが拒否するので、mergeable 後に CI などで見つかった PR 追加行の欠陥も、完了前確認の逸脱として記録してから fix の計画を通す。

マージ前の「起票候補 0 件」の確認は、最新のレビュー結果だけでなく、PR の全 cycle の非 blocking を対象にする。先行 cycle にだけ載った PR 起因の指摘は、最新の結果からは見えないまま cleanup で初めて表に出る。

### 停滞の見直しでは非 blocking の指摘も処置を決める

停滞診断の見直しで、非 blocking を含む全指摘の処置を計画に割り当てることが求められた。非 blocking のうち同じファイルで安く直せるもの（判定規則の順序づけ、テストの届かない経路、小さな文書の欠陥）はその cycle の計画に入れて直し、別スキルの設計に及ぶもの（PR 本文を修正側で直す経路）は返信に留めた。小さく直せる欠陥を同じ計画に入れると、後の sweep の往復が減る。

## 関連ページ

- [呼び出し元で挙動を分ける規則は、永続状態から推定せず呼び出し元が渡す明示の引数で分ける](./caller-context-branch-uses-explicit-flag-not-persisted-state.md)

## ソース

- [replan で PR 起因の非 blocking もまとめて直した fix 結果](../../raw/fixes/20260929T134642Z-pr-3452.md)
- [保留された PR 起因の根因を計画に入れた fix 結果](../../raw/fixes/20260929T153014Z-pr-3452.md)
- [fix 結果（停滞の見直しでの非 blocking の処置）](../../raw/fixes/20261009T162319Z-pr-3728.md)
- [fix 結果（停滞の見直しでの非 blocking の処置）](../../raw/fixes/20261009T164231Z-pr-3729.md)
