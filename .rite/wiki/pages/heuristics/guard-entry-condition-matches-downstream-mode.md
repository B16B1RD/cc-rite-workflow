---
type: "heuristics"
title: "fail-loud ガードの入口判定は、下流が実際に扱う範囲と同じ判定モードにそろえる"
domain: "heuristics"
description: "「下流の処理が何も生まなければ停止する」ガードは、入口の判定（変更あり）と下流が実際に扱う範囲がずれていると正常系を止める。ずれを直すときはガードを弱めず、入口の判定を下流が内部で使う判定モードそのものにそろえ、欠陥クラスの隣のメンバーまで塞ぐ。"
created: "2026-09-28T01:02:34Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T01:02:34Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260928T003328Z-pr-3363.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T003626Z-pr-3363.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T004428Z-pr-3363.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T004629Z-pr-3363.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T005244Z-pr-3363.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T005445Z-pr-3363.md"
tags: ["fail-loud", "git-stash", "submodule", "mutation"]
confidence: high
---

# fail-loud ガードの入口判定は、下流が実際に扱う範囲と同じ判定モードにそろえる

## 概要

「下流の処理が何も生まなければ停止する」ガードは、入口の判定（変更あり）と下流が実際に扱う範囲がずれていると正常系を止める。ずれを直すときはガードを弱めず、入口の判定を下流が内部で使う判定モードそのものにそろえ、欠陥クラスの隣のメンバーまで塞ぐ。

## 詳細

観測された形: 「変更があれば `git stash push -u` で退避し、新しい stash entry が作られなければ停止する」という fail-loud ガードを足したところ、submodule の中身だけが dirty な作業ツリーで正常系が止まった。入口の `git diff` は submodule の中身の dirty を変更ありと数えるが、`git stash push` はそれを保存しないため entry が作られない。ガード自体は正しく、ずれていたのは入口の判定の範囲である。

直し方の順序:

- ガードを弱めて（停止をやめて）通すのではなく、入口の判定を下流が保存する範囲にそろえる。
- そろえるときは、目の前の 1 形だけを外すオプションで済ませない。`--ignore-submodules=dirty` は中身の dirty しか外さず、gitlink の移動（submodule の commit が進んだ状態）が同じ経路で残った。下流（git stash）が内部で使う判定と同じ `--ignore-submodules`（all）を選ぶと、欠陥クラス全体が塞がる。
- 欠陥クラスのメンバー（dirty / moved / moved かつ dirty）をパラメータ化したテストで固定し、部分的なオプションへ戻す変異で moved 系が落ちることを実測する。

判定を複数の行（作業ツリー側と index 側など）で変えた場合は、片側だけを元に戻す変異がそれぞれ落ちるテストを置く。index 側の変更は staged な gitlink の形でしか観測できないため、その形で後段が git 自身の理由付きで止まり、退避した raw を戻して index をそのまま残すことを固定する。

新設した分岐（例: stash の SHA が引けないときは pop しない）も、それを通るケースが無ければ退行を検出できない。ガードと同時に、その分岐を通す fixture を用意する。

## 関連ページ

- [失敗経路の後始末で stash pop の後に index を reset すると、ユーザーが staged にしていた変更まで外れる](../anti-patterns/index-cleanup-after-stash-pop-unstages-user-staging.md)
- [fail-loud ガードは同じ帰結を持つ全出口に張る（症状側から出口を網羅する）](./fail-loud-guard-covers-all-sibling-exits.md)
- [追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない](../patterns/mutation-prove-new-pin.md)

## ソース

- [レビュー結果](../../raw/reviews/20260928T003328Z-pr-3363.md)
- [fix 結果](../../raw/fixes/20260928T003626Z-pr-3363.md)
- [レビュー結果](../../raw/reviews/20260928T004428Z-pr-3363.md)
- [fix 結果](../../raw/fixes/20260928T004629Z-pr-3363.md)
- [レビュー結果](../../raw/reviews/20260928T005244Z-pr-3363.md)
- [fix 結果](../../raw/fixes/20260928T005445Z-pr-3363.md)
