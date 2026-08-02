---
type: "heuristics"
title: "同一欠陥に対し reviewer の scope が割れたらユーザー判断へエスカレートする — follow-up は current-pr と同義ではない"
domain: "heuristics"
description: "形式変更 PR では「変更していない consumer」に欠陥が現れるため、Issue のファイル単位スコープと欠陥の所在がずれる。2 名が独立に同じ欠陥へ到達しながら処置が current-pr と follow-up に割れるのはこの構造による。両者を「どちらも blocking だから本 PR で直す」と読むと reviewer が deferred と明示した signal が消える。scope enum の定義を実ファイルで確認し、割れたらユーザーへ上げる。accept は無視ではなく処置を伴う deferred。"
created: "2026-08-02T22:05:00+09:00"
updated: "2026-08-02T22:05:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260802T110823Z-pr-2052.md"
tags: ["review-scope", "escalation", "producer-consumer", "deferred-treatment", "issue-scope-boundary"]
confidence: high
---

# 同一欠陥に対し reviewer の scope が割れたらユーザー判断へエスカレートする — follow-up は current-pr と同義ではない

## 概要

複数の reviewer が **独立に同じ欠陥へ到達しながら、処置の scope が割れる**ことがある。これは判定のブレではなく、**同じ問題への 2 つの正しい読み**であることが多い。scope 軸が割れたときの解決は統合ではなく、ユーザー判断へのエスカレーション。

前提として、`follow-up` は「本 PR では deferred、別 Issue として後続対応」であり `current-pr` と同義ではない。両者を「どちらも blocking だから本 PR で直す」と読むと、reviewer が deferred と明示した signal が消える。

## 詳細

### なぜ scope が割れるか — 形式変更 PR の構造

起点事例は index.md のカタログ形式を producer 側（テンプレート + ingest 指示）で確定させる PR だった。しかし consumer 側の `/rite:wiki-query` Pass 1 は箇条書き行しか解析せず、候補 0 件時に無診断で `exit 0` する。

**形式変更 PR では「変更した producer」ではなく「変更していない consumer」に欠陥が現れる。** 一方 Issue はファイル単位で Target / Non-Target を切るため、「Non-Target のファイルに blocking 欠陥がある」状態が生じる。

処置が割れた内訳:

| reviewer | scope | 論拠 |
|---|---|---|
| error-handling | `current-pr` | 診断の追加は読み手対応（別 Issue）とは独立に本 PR で閉じられる |
| tech-writer | `follow-up` | Issue が当該ファイルをコメントのみとスコープしている以上、リリース順序 gate で対処すべき |

どちらも筋が通っている。割れているのは欠陥の認識ではなく、**Issue のスコープ定義と欠陥の所在のずれをどう扱うか**である。

### scope enum の定義を実ファイルで確認する

割れを検出したら、まず enum の定義を確認する（`references/severity-levels.md` と `agents/_reviewer-base.md` の Scope Assignment）。

`follow-up` を `current-pr` と同義と読むと、reviewer が「別 Issue へ」と明示した signal が消える。定義を確認したことで、処置の割れが「同じ問題への 2 つの正しい読み」だと確定し、ユーザー判断へエスカレートする根拠になった。

### accept は「無視」ではなく「処置を伴う deferred」

起点事例では 3 件が「修正 1 / accept 2」に分かれた。accept した 2 件に対して、reviewer 自身が推奨した処置を実行している。

- Issue へ AC（リリース順序 gate）を追記
- fail-loud ガードの follow-up Issue を起票

fingerprint を永続化して次サイクルの再報告を抑止するのは、**処置を取ったうえで**のこと。**処置なしの accept は指摘の握り潰しになる。**

### 閉じる側の Issue に置いた制約は、必要になる時点には存在しない

ただしこの処置には後続サイクルで欠陥が見つかった。リリース順序 gate を起票元 Issue の AC として追記したが、その Issue は `/rite:cleanup` でマージ直後に閉じる。gate が必要になるのは**その後のリリース時点**である。

> 制約は「その時点でまだ open な側」か、その手順が実際に読む場所へ置く。

閉じる Issue に書いた制約は、発火すべき時点には存在しない。deferred の処置先を決めるときは、**その制約がいつ読まれるか**を先に決める。

### 収束しないサイクルは別 Issue のシグナル

起点事例は 3 サイクル回して blocking が 2 → 3 → 6 と**増えた**。内訳を見ると、cycle 3 の blocking 6 件のうち 4 件が「テスト / drift pin を足せ」だった。しかもそのうち 1 件は cycle 1 の修正そのものが生んだ指摘である。

**指摘の性質が「実装の誤り」から「検証資産の不足」へ移ったら、それは別 Issue のシグナル。** docs 是正 PR にテスト基盤を後付けし続けると、PR の主題から離れた作業が主になりサイクルが終わらない。

件数だけでなく内訳の性質を並べると、ループを続けても収束しないことが早期に判る。

## 関連ページ

- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](./reviewer-scope-antidegradation.md)
- [累積対策 PR の 3 cycle 収束記録: cross-validation boost + cycle 2 minor drift + cycle 3 mergeable](./accumulated-pr-three-cycle-convergence.md)
- [配布テンプレートへの内部参照流入は 1 箇所直しても閉じない — 同一配布単位の sibling を base 件数と比較する](../anti-patterns/internal-reference-leaks-into-distributed-template.md)

## ソース

- [PR #2052 review results (cycle 2)](../../raw/reviews/20260802T110823Z-pr-2052.md)
