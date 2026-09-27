---
type: "anti-patterns"
title: "並行セッションの別 Issue ブランチ作成が post-review state verify の branch_list drift を誤検出させる"
domain: "anti-patterns"
description: "レビュー前後の branch 一覧ハッシュを比較して reviewer の READ-ONLY 違反を検出する仕組みは、別の並行セッションが同時に別 Issue 用のブランチを作成/削除しただけでも drift を報告する。検出対象（このレビューの reviewer）と観測対象（リポジトリ全体の branch 一覧）が一致していないための false positive。観測を絞る判別子は「自セッションに帰属するもの」ではなく「他セッションの worktree で checkout 中の branch」という除外すべき集合で定義しないと、reviewer 自身の違反まで検出から消える。"
created: "2026-09-26T07:00:00+00:00"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T04:58:44Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T062846Z-pr-3117.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T093831Z-pr-3139.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T035253Z-pr-3207.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T040118Z-pr-3207.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T041714Z-pr-3207.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T042336Z-pr-3207.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T043431Z-pr-3207.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T044244Z-pr-3207.md"
tags: ["multi-session", "false-positive", "branch-list-hash", "post-review-state-verify", "concurrent-session"]
confidence: medium
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T04:45:00Z" }
---

# 並行セッションの別 Issue ブランチ作成が post-review state verify の branch_list drift を誤検出させる

## 概要

reviewer の READ-ONLY enforcement を検証する post-review state verify は、レビュー開始前後の `git branch --list` ハッシュを比較して drift を検出する。この検出範囲はリポジトリ全体の branch 一覧であり、レビュー中の reviewer 自身の操作に限定されていない。マルチセッション環境で別のセッションが同時に別 Issue のセッション worktree ブランチを作成・削除すると、当該レビューの reviewer は何も変更していないにもかかわらず drift として報告される。

観測を絞る判別子を入れるなら、「自セッションに帰属するもの」ではなく「他セッションの worktree で checkout 中の branch」という除外すべき集合で定義する。帰属で定義すると、reviewer 自身の違反まで検出から消える。

## 詳細

判別子を持たない検出ロジックは「レビュー開始時の branch 一覧のハッシュ」と「レビュー終了時の branch 一覧のハッシュ」を比較するだけで、変更した主体を区別しない。これは単一セッション・単一ユーザーの前提では正しく機能するが、`/rite:batch-run` のように複数セッションが同一リポジトリで並行に別 Issue を処理する運用では、以下が起こる:

1. セッション A がレビュー対象 PR の reviewer を起動（branch 一覧のハッシュを記録）
2. セッション B が別 Issue のセッション worktree 用ブランチを作成（リポジトリ全体の branch 一覧が変化）
3. セッション A の reviewer が完了（branch 一覧のハッシュを再取得 → 不一致 → drift 報告）

drift の原因は reviewer の READ-ONLY 違反ではなく、無関係な並行セッションの正常な操作である。

### 判別子は「除外すべき集合」で定義する

この false positive を消すために共有 ref（`refs/heads` と `refs/stash`）の観測を絞る判別子を入れるとき、最初に思いつくのは「自 worktree に帰属するものだけを数える」という定義である。これは検出を壊す。reviewer 自身が `git worktree add -b` で別の worktree と branch を作った場合、その branch は自 worktree に帰属しないので数えられず、改修前には検出できていた違反が見えなくなる。stash も同じで、件数を「元 branch の件名を持つ stash」だけに絞ると、reviewer が別 branch へ切り替えて stash してから元に戻る操作が消える。

修正は、判別子を逆向きに定義することだった。除外する集合を「他セッションの worktree で checkout 中の branch」と明示し、branch 一覧からはその branch を、stash からは件名の branch がそれに当たるものを除く。reviewer が実験用に作る worktree の名前空間は他セッションに数えない。「残すもの」で定義すると、定義者が想定しなかった操作は黙って除外側に落ちる。「除外すべきもの」で定義すると、想定外の操作は数えられ続け、検出側に残る。

絞り込みを入れた後は、改修前の helper と同じ操作列（別 worktree での branch 作成、別 branch 経由の stash など）を両方に流し、改修前に検出できていた違反が改修後も検出されることを比べて確かめる。並列セッションの除外が効いたことだけを確かめても、検出の喪失は見えない。

### 除外は位置だけでなく名前でも判定する

「他セッションの worktree で checkout 中の branch」を worktree の位置だけで判定すると、reviewer が既定の名前空間の外に作った branch まで他セッション扱いになり、検出から消える。branch 名は規約上 reviewer 由来と分かる場合がある。回収側（cleanup）が「reviewer の漏出」として回収する名前の定義を、検出側の除外判定にもそのまま使い、位置と名前の両方の手掛かりで判定する。回収側と検出側で「漏出名」の前提を別々に書くと、片方だけが更新されて同じ食い違いが再発する。

### 手で写した定義は、両側から値の集合を取り出して一致をテストで固定する

検出側の漏出名の正規表現は、回収側（`pr-cycle-cleanup.sh`）の定義を写したものである。定義を共有する代わりに両ファイルから選択肢の集合を取り出し、一致を assert するテストを置くと、片方だけの変更がテストで止まる。比べるのは意図して揃える部分（選択肢の集合）に限る。意図的に差を残す要素（検出側が含めない orchestrator 由来の名前）は両側から除いて比べる。判別子に条件を足したら、その条件を説明する rationale 文書すべてに同じ条件を書く。

## 関連ページ

- [sandbox のバインドマウントで raw git status が常時 dirty になる](../anti-patterns/sandbox-bind-mount-makes-raw-git-status-always-dirty.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T062846Z-pr-3117.md)
- [レビュー結果](../../raw/reviews/20260926T093831Z-pr-3139.md)
- [判別子の定義を指摘したレビュー結果](../../raw/reviews/20260927T035253Z-pr-3207.md)
- [判別子を除外すべき集合で定義し直した fix 結果](../../raw/fixes/20260927T040118Z-pr-3207.md)
- [名前空間外の漏出名が除外されたままと指摘したレビュー結果](../../raw/reviews/20260927T041714Z-pr-3207.md)
- [位置と名前の両方で判定するようにした fix 結果](../../raw/fixes/20260927T042336Z-pr-3207.md)
- [漏出名の検出が戻ったことを確認したレビュー結果](../../raw/reviews/20260927T043431Z-pr-3207.md)
- [漏出名の一致をテストで固定した fix 結果](../../raw/fixes/20260927T044244Z-pr-3207.md)
