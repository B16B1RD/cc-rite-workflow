---
title: "future-note Issue は実装前に前提の現在性を再検証する"
domain: "heuristics"
description: "「将来 X が起きたら留意」型 Issue は起票から実装までに前提が変わりうる。実装前に前提コード状態を Read/Grep で現 HEAD と突合し、変わっていれば記録に現在の事実 (準拠例) を織り込む。過去のレビュー事例 / 関連する課題 (起票翌日の 過去のレビューで逆方向解消、変更ゼロ close) の 2 例で実測。"
promote: rite-plugin
created: "2026-06-09T19:45:00+00:00"
updated: "2026-06-09T19:56:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260609T193647Z-pr-1326.md"
  - type: "retrospectives"
    ref: "raw/retrospectives/20260609T195524Z-issue-1211.md"
tags: []
confidence: medium
---

# future-note Issue は実装前に前提の現在性を再検証する

## 概要

「将来 X が起きたら留意」型の future-note Issue は、起票から実装までの間にコードベースが進み前提が変わっていることがある。実装前に前提（本件: 「TC-H7 が最後の TC」）を再検証すると、記録コメントが実際の参照対象を持つ形で書け、レビューでの正確性検証も一発で通る。

## 詳細

flow-state.test.sh TC-H7 へ corrupt state_file の sandbox 隔離留意コメントを追加した PR (+4/-0) で実測:

- **前提変化の検出**: Issue 起票時は TC-H7 がファイル末尾の最後の TC で「将来 TC を追加する場合の留意」だったが、実装時点では TC-23 が既に TC-H7 の後ろに追加済みだった（TC-23 は new_sandbox を正しく取得しており実害なし）。実装前の対象ファイル Read でこれを検出し、コメントに「直後の TC-23 は準拠済み」という現在性のある参照を含められた。
- **レビュー観点**: コメントのみの追加 PR では、コメントの全主張（corrupt file 残置 / new_sandbox の隔離効果 / TC-23 の準拠）を実コード Read で突合する Comment Rot 検査がレビューの中心になる。主張を実装前に実機検証しておけば 1 cycle で 0 findings mergeable に収束する。
- **記録形式**: symbolic anchor（TC-H7 / TC-23）は行番号参照と異なり refactor 耐性があり、comment quality gate（no_line_or_cycle_reference）を通過する記録形式として有効。

適用指針: future-note 系 Issue（「現状問題なし、将来の留意点として記録」）に着手するときは、(1) Issue が前提とするコード状態（位置・件数・最終要素）を Read/Grep で現在の HEAD と突合し、(2) 前提が変わっていれば記録内容に現在の事実（準拠例・違反例）を織り込む。

**2 例目（起票翌日に前提失効）**: 「usage 文言が実挙動 (未指定 → io_error 降格) と乖離」を前提に文言緩和を提案した Issue が、起票翌日の別 PR で逆方向 (実挙動を文言に合わせて runtime enforce) により解消済みだった。提案どおり文言を緩和すると事実誤認を導入するところで、対象行の現 HEAD Read + `git log -S "<guard 文言>"` による enforcement 追加日と起票日の突合が決定打となり、変更ゼロで close した。「文言 vs 実挙動の乖離」系 Issue は文言側・挙動側のどちらでも解消しうるため、着手時に両方向の解消有無を確認する。

## 関連ページ

- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)
- [Design doc は現 HEAD の SoT (registration / writer-reader grep) を verify してから書く](./design-doc-current-head-verification.md)

## ソース

- [PR #1326 review results](../../raw/reviews/20260609T193647Z-pr-1326.md)
- [Issue #1211 close retrospective](../../raw/retrospectives/20260609T195524Z-issue-1211.md)
