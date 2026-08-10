---
title: "全域で成功する resolver への委譲が既存 fail-fast ガードを silent success 化する"
domain: "anti-patterns"
description: "「必ず非空値を返す」helper に値解決を委譲すると、空チェック依存の既存 ERROR ガードが dead code 化し従来エラーが silent success に変わる。委譲は helper の全域性を確認し必要なら git repo gate 等で条件化する。過去のレビュー事例 F-12 実測。判定の値域を広げる変更も同型で、2 値比較のまま残った強制述語が新状態を素通りさせる（過去のレビュー事例）。"
created: "2026-07-13T07:40:00Z"
updated: "2026-08-01T23:12:28+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260712T223319Z-pr-1839.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T112516Z-pr-2081.md"
tags: []
confidence: high
---

# 全域で成功する resolver への委譲が既存 fail-fast ガードを silent success 化する

## 概要

「入力がどうであれ必ず非空値を返す (total な)」helper に値の解決を委譲すると、その値の空チェックに依存していた既存の fail-fast ERROR ガードが到達不能な dead code になり、従来エラーだった状況が silent success に変わる。委譲するときは helper の全域性 (どの条件で何を返すか) を確認し、必要なら委譲自体を条件で gate する。

## 詳細

起点事例の F-12 の実測例: `review-schema-version-check.sh` の REPO_ROOT 解決を `state-path-resolve.sh` に委譲したところ、この resolver は**非 git cwd でも cwd を正常出力 (exit 0) として返す**設計 (hook の non-blocking 契約由来) のため、

- 旧: `git rev-parse --show-toplevel` 失敗 → REPO_ROOT 空 → `ERROR ... exit 2` (fail-fast)
- 新: resolver が cwd を返す → 空チェック通過 → `.rite/review-results` 不在 → `exit 0` clean

と、repo 外での ad-hoc 実行が「偽の clean」を返すようになった。WARNING も出ない (resolver は成功している) ため、Issue が規定する documented fallback (WARNING 付き) にも該当しない仕様外の挙動変化。

修正は委譲の gate 化: `[ -z "$REPO_ROOT" ] && git rev-parse --show-toplevel >/dev/null 2>&1` を満たす場合のみ resolver を呼び、非 git cwd では値を空のまま既存 ERROR ガードへ到達させる (fail-fast の復元)。

## 同型: 分岐を増やしたら、その分岐を強制している既存述語も見直す

委譲だけでなく **判定の値域を広げる変更** も同じ形でガードを不完全にする。判別を 2 値から 3 値へ広げた事例では、「ゲートが算出する値」に新しい状態が加わったのに、caller の契約違反を検出する述語が**2 値比較のまま**残った。新状態に対応する先書きが「矛盾なし」と読まれ、強制層を素通りした。

**帰結自体は変更前から存在していても、それを捕まえるはずのガードが変更によって不完全になるなら、それは新しい欠陥である。** 分岐追加のレビュー観点として「**この分岐を強制 / 検証している既存述語はどれか**」を必ず引く。

あわせて、**述語の一部を別の述語から literal 複製すると、片方だけの編集で両者が食い違う**。しかもその食い違いが「集合の和は保たれるが要素の振り分けだけが変わる」形だと、和の一致を検査する不変条件では検出できない。共有できる部分は文字列連結で構造的に共有し、複製を作らない。

## 检出のポイント

- 委譲先 helper の「失敗時挙動」を読む: exit code だけでなく「失敗を成功として degrade する」経路 (fallback 内蔵) の有無
- 委譲後に、旧実装で到達可能だった ERROR / exit 非 0 経路が到達可能なまま残っているかを revert test で比較する (旧版と新版を同条件で実行し rc を突合)
- 値域を広げる変更では、その値を比較している既存述語 (契約違反検出・整合性チェック) を grep し、新しい値に対応しているか確認する

## 関連

- [[path-basis-change-observation-surface-sweep]] — 同 PR の総括 heuristic
- [[fix-activates-dormant-no-op-path-reveals-latent-bug]] — 修正が潜在経路を活性化する近縁パターン
- [[dual-language-predicate-divergence]] — 同じ述語を複製すると受理集合が割れる

## ソース

- [PR #1839 review results](../../raw/reviews/20260712T223319Z-pr-1839.md)
- [PR #2081 fix results (cycle 2)](../../raw/fixes/20260801T112516Z-pr-2081.md)
