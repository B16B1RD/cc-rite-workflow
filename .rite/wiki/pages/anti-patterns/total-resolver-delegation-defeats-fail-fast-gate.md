---
title: "全域で成功する resolver への委譲が既存 fail-fast ガードを silent success 化する"
domain: "anti-patterns"
created: "2026-07-13T07:40:00Z"
updated: "2026-07-13T07:40:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260712T223319Z-pr-1839.md"
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

## 检出のポイント

- 委譲先 helper の「失敗時挙動」を読む: exit code だけでなく「失敗を成功として degrade する」経路 (fallback 内蔵) の有無
- 委譲後に、旧実装で到達可能だった ERROR / exit 非 0 経路が到達可能なまま残っているかを revert test で比較する (旧版と新版を同条件で実行し rc を突合)

## 関連

- [[path-basis-change-observation-surface-sweep]] — 同 PR の総括 heuristic
- [[fix-activates-dormant-no-op-path-reveals-latent-bug]] — 修正が潜在経路を活性化する近縁パターン
