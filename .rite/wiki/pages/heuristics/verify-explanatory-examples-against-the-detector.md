---
type: "heuristics"
title: "限界を説明する例は検出器に食わせ、「〜としてのみ使う」型の断定は grep で数えてから書く"
domain: "heuristics"
description: "コメントやドキュメントで機構の限界を説明するとき、添える具体例を実際にその検出器へ食わせて挙動を確かめる。主張自体が正しくても、それを説明する例が主張を否定していることがある。同様に「X としてのみ使う」型の消費経路の断定は grep で数えてから書く。どちらも実行・検索で機械的に裏取りできるのに、散文だから頭の中で書けてしまう点が共通の落とし穴。"
created: "2026-08-01T17:45:00+09:00"
updated: "2026-08-01T17:45:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260801T080814Z-pr-2080.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T081201Z-pr-2080.md"
tags: [comment-accuracy, documentation, empirical-verification, grep-verification, example-validation]
confidence: medium
---

# 限界を説明する例は検出器に食わせ、「〜としてのみ使う」型の断定は grep で数えてから書く

## 概要

コメントやドキュメントで機構の限界・用途を説明するとき、**主張は頭の中で検証できるが、それを支える具体例と数え方は実行しないと逆を書く**。限界説明に添える例はその検出器へ実際に食わせ、消費経路の列挙は grep で数える。どちらも数十秒で機械的に裏取りできる。

## 詳細

- **例が主張を否定する**（PR #2080 cycle 2）: 静的ガードの限界として「検出器は `mktemp` とテンプレートが同一行にある場合しか見ない」と書き、例に `tpl="foo-XXXXXX.md"; mktemp "$tpl"` を挙げた。この例は同一行なので**実際には検出される**。主張（同一行のみ）は正しいのに、それを説明するはずの例が主張を否定していた。レビュアーはこの例を検出器に食わせて反証した。修正では差し替えた 2 例（2 行形 = 非検出、行末コメント形 = 検出）を両方とも検出器に通してからコミットした。

- **「〜としてのみ」は数えてから書く**（同 cycle 2）: tempfile の消費経路を「awk の出力先と `gh pr comment --body-file` の引数**としてのみ**使う」と書いたが、同ファイル内の 2 箇所で post-condition の awk が同じ tempfile を**入力**としても読んでおり、実際は 4 用途だった。結論（「拡張子は不要」）は 4 用途すべてで成立するため実害はないが、列挙の取りこぼしは「この値は誰が読むのか」を後から判断する読み手を誤らせる。test / error-handling の 2 レビュアーが独立に同じ箇所を指摘した。

- **共通する落とし穴**: どちらも「散文だから書けてしまう」。限界の主張・用途の要約は思考だけで書けるが、その具体例と件数は実行・検索の結果でしか確定しない。**検出器が動く／grep が使える対象について書くときは、書いた内容をその場で通す**。

- **前 cycle の修正が次 cycle の指摘対象になる構造**: cycle 1 の指摘を直したコメントが cycle 2 で 2 件指摘された。コメントを書き足すたびに新たなレビュー対象面が増えるため、追加した記述こそ実測で裏取りする必要がある。

- **scope=nit-noted でも、受け流しの記録が残らない構成なら同 cycle で直す**: rite の reviewer は subagent で PR に inline comment を投稿しないため、nit reply の投稿先 thread が存在しない。つまり「nit として認知した」痕跡が PR 上に残らない。1 語で直る不正確さをこの状態で受け流すと、記録も修正も残らないまま次 cycle の再指摘リスクだけが残る。reply 経路が実在する構成とは判断が変わる。

## 関連ページ

- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](./empirical-reproduction-over-invariant-reasoning.md)
- [静的ガードを新設したら、走査面の限界と現存する未カバーサイトをテスト本体のコメントに書く](./static-guard-declare-scan-scope-limits.md)

## ソース

- [PR #2080 review results (cycle 2)](../../raw/reviews/20260801T080814Z-pr-2080.md)
- [PR #2080 fix results (cycle 2)](../../raw/fixes/20260801T081201Z-pr-2080.md)
