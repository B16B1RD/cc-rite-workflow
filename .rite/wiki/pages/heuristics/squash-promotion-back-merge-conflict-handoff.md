---
type: "heuristics"
title: "squash 昇格後の back-merge は衝突を前提に、復旧手順の衝突分岐を人間への引き渡し経路として書く"
domain: "heuristics"
description: "develop→main の昇格を squash でマージすると次の back-merge は merge-base が前回リリース前まで後退し、develop 側でリリース範囲の行を再編集していると 3-way merge が衝突する。ツリー不変の合流は ours 戦略でしか作れず GitHub の PR マージでは生成できないため、復旧手順は衝突分岐を『本手順では復旧できない理由と人間が選ぶ選択肢』として明記し、PR 経由で条件を満たすという主張は衝突しない場合に限定する。"
created: "2026-09-12T03:16:24Z"
generated: { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-12T03:16:24Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260912T030029Z-pr-2712.md"
  - type: "fixes"
    resource: "raw/fixes/20260912T030431Z-pr-2712-fix1.md"
tags: []
confidence: high
---

# squash 昇格後の back-merge は衝突を前提に、復旧手順の衝突分岐を人間への引き渡し経路として書く

## 概要

develop→main の昇格を squash でマージすると次の back-merge は merge-base が前回リリース前まで後退し、develop 側でリリース範囲の行を再編集していると 3-way merge が衝突する。ツリー不変の合流は ours 戦略でしか作れず GitHub の PR マージでは生成できないため、復旧手順は衝突分岐を「本手順では復旧できない理由と人間が選ぶ選択肢」として明記し、PR 経由で条件を満たすという主張は衝突しない場合に限定する。

## 詳細

- **衝突が通常形になる理由**: squash 昇格は develop の各コミットを main の祖先にしない。次に main を develop へ戻すとき、merge-base は前回リリース前の develop まで後退し、ours（develop）と theirs（squash 1 コミット）が同じファイル群を別内容で変更した形になる。毎サイクル同じ手順書やドキュメントを編集するリポジトリではほぼ常に衝突する。このリポジトリ自身の履歴で dry-run すると、想定タイミングでも実際の復旧時点でも衝突し、`git write-tree` は index が unmerged のため失敗した。
- **正しい合流結果は分かっているのに作れない**: 事前検証で main のツリーが develop の過去コミットのツリーと一致していれば、合流結果は develop のツリーそのものと確定している。それを作れるのは `git merge -s ours` だけだが、GitHub の PR マージは戦略を指定できず、ローカルで作ったマージコミットを PR 経由で取り込むと「昇格差分の各コミットが merged PR の merge commit であること」を要求するゲートが拒否する。squash-only の検証条件を緩めない限り、衝突ケースは自動手順では復旧できない。
- **手順書の書き方**: 衝突分岐を ERROR で止めるだけにすると、停止 → 復旧不能 → リリース不能の閉路になる。分岐表に衝突を明示の値として載せ、「なぜ本手順では復旧できないか」と「人間が選ぶ 2 択（検証条件に狭い例外を設ける契約を別に起こす / 乖離を次回昇格まで持ち越す）」を書く。楽観的な主張（「PR 経由のマージコミットなら条件を満たす」）は成立条件付きに限定する。
- **dry-run の検証述語**: `git merge --no-commit` は HEAD を動かさないため、abort の成否を「HEAD が動いていないか」で検証しても原理的に発火しない。abort の終了コードと MERGE_HEAD の不在を直接検査する。merge 失敗の stderr を捨てると dirty tree 等の別原因が「衝突」に丸められるので、stderr は残し、`--abort` は MERGE_HEAD がある場合だけ実行する。
- **診断コメントの罠**: 「main 側にしか無いコミットが 1 件だけなら健全」のように件数を健全性の判定材料にすると、マージコミット方式の昇格を back-merge なしで続けた正常形（2 件以上）で偽陽性になる。判定は祖先関係で行い、件数は表示に留める。

## 関連ページ

- [worktree 運用の git 状態検出は .git 直書きせず git rev-parse --git-path で解決する](../patterns/worktree-aware-git-state-detection.md)

## ソース

- [昇格履歴の乖離検出に対するレビュー結果](../../raw/reviews/20260912T030029Z-pr-2712.md)
- [昇格履歴の乖離検出の fix 結果](../../raw/fixes/20260912T030431Z-pr-2712-fix1.md)
