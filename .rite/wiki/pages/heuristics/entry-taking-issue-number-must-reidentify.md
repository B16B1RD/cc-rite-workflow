---
type: "heuristics"
title: "Issue 番号を引数で受ける入口は、対象の同定をセッション前提からやり直す"
domain: "heuristics"
promote: rite-plugin
description: "対象 Issue が現在のセッションと一致する前提で書かれた参照実装を、Issue 番号を引数で受ける入口へ写すと、PR 検索・flow-state・worktree detect がいずれも対象を同定できていないまま破壊的操作へ進む。leftover の state も identity を突き合わせずに消費してはならない。"
created: "2026-09-02T00:50:00Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T00:50:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T133013Z-pr-2500.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T225105Z-pr-2503.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T134035Z-pr-2500.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T230359Z-pr-2503.md"
tags: []
confidence: high
---

# Issue 番号を引数で受ける入口は、対象の同定をセッション前提からやり直す

## 概要

対象 Issue が現在のセッションと一致する前提で書かれた参照実装を、Issue 番号を引数で受ける入口へ写すと、PR 検索・flow-state・worktree detect がいずれも対象を同定できていないまま破壊的操作へ進む。leftover の state も identity を突き合わせずに消費してはならない。

## 詳細

`/rite:cleanup` は対象 Issue == 現在のセッションが前提なので、`flow-state.sh get --field branch` が現セッションの値を返す設計で正しい。Issue 番号を引数で受ける入口ではその前提が崩れる。同じ値を読む既存入口は `issue_number` を併せて読んで束縛していた。写された 3 箇所（PR 検索・flow-state の branch 読み出し・worktree detect）がいずれも Issue 番号でスコープされておらず、同定できていないまま破壊的操作へ進む構造になっていた。

参照実装から写す前に、写す先で成り立つ前提を列挙する。「対象の同定」は入口の最初の仕事であり、安全形（`--` と quote、marker family 全体の消費、一時ファイルを worktree 削除の向こう側に置かない）も一緒に写す。

同じ欠陥クラスは leftover 消費にも出る。キューの現 Issue と leftover の flow-state Issue が両方非空で不一致なら、その leftover は別作業の残渣である。突き合わせずに routing すると、別 Issue の phase で現 Issue を進める。不一致なら case を skip し、入口の再判定へ倒す。

phase 列挙に無い終端（例: merge 後も phase が ready のまま）は、列挙を増やすより「その phase のまま観測できる事実」（MERGED）で次へ倒す。hint はスラッシュコマンド形にしない。継続指示をユーザー起動可能なコマンドに見せると、誤った入口から再実行される。

## 関連ページ

- [同定手段の取得経路を差し替えるときは、旧経路が構造的に保証していた述語を先に全部列挙する](./identity-path-swap-enumerate-old-invariants.md)
- [インライン処理の helper 抽出は「helper が起動しない」経路を新設し、marker 不在＝成功の消費規則を破る](../anti-patterns/helper-extraction-creates-unstarted-path.md)

## ソース

- [PR #2500 review results](../../raw/reviews/20260901T133013Z-pr-2500.md)
- [PR #2503 review results](../../raw/reviews/20260901T225105Z-pr-2503.md)
- [PR #2500 fix results](../../raw/fixes/20260901T134035Z-pr-2500.md)
- [PR #2503 fix results](../../raw/fixes/20260901T230359Z-pr-2503.md)
