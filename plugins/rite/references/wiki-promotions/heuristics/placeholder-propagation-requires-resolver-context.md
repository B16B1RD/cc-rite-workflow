---
type: "heuristics"
title: "placeholder 伝播は実行主体の解決経路を確認してから適用する"
domain: "heuristics"
promote: rite-plugin
promoted_from: "wiki:/pages/heuristics/placeholder-propagation-requires-resolver-context.md"
promoted_from: "wiki:/pages/heuristics/placeholder-propagation-requires-resolver-context.md"
description: "literal substitution 方式の placeholder（{owner_repo} / {plugin_root} 等）を新しいファイルへ伝播する前に、そのファイルを読んで実行する主体が placeholder を解決する経路（Legend・canonical スニペット・注入された値）を持つかを確認する。解決経路のないコンテキスト（reviewer agent 定義等）への伝播は literal 残留の回帰を生む。"
created: "2026-07-20T01:15:00+09:00"
updated: "2026-07-20T01:15:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260719T154814Z-pr-1919-c3.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T154952Z-pr-1919-c3.md"
tags: []
confidence: high
---

# placeholder 伝播は実行主体の解決経路を確認してから適用する

## 概要

`{plugin_root}` / `{owner_repo}` のような literal substitution 方式の placeholder を新しいファイルへ展開する際は、「そのファイルを読んで実行する主体が、placeholder を解決する手段を持つか」を先に確認する。解決経路のないコンテキストへ伝播すると、placeholder が literal のまま実行され、伝播前より悪い無条件失敗（回帰）を生む。

## 詳細

`-R {owner_repo}` 伝播スイープで reviewer agent 定義（`agents/tech-writer-reviewer.md`）にも伝播したところ、spawn される reviewer subagent は user prompt に diff / spec / shared principles しか受け取らず、`{owner_repo}` の Legend も `{plugin_root}`（canonical 解決スニペットの実行に必須）も持たないため、literal `{owner_repo}` のまま gh が実行され `expected the "[HOST/]OWNER/REPO" format` で必ず失敗する状態になった。伝播前は gh の remote 推論で（alias 環境以外では）動いていたため、全環境で壊す回帰だった。

- ファイル種別ごとに実行主体と解決経路が異なる: SKILL.md（orchestrator LLM、Legend + canonical スニペットあり）/ references（SKILL.md 経由で参照、注記で解決）/ agent 定義（subagent の system prompt、解決経路なし）
- 差し戻す場合は、canonical 文書の適用除外リストに理由付きで追記して再発を防ぐ（「reviewer agent 定義は {plugin_root}/{owner_repo} 未解決コンテキスト」）
- 同名の識別子でも形式が違うものが近接すると誤置換を誘発する（shell 変数 `$owner_repo` = TAB 区切り vs placeholder `{owner_repo}` = slash 形式）。新設 placeholder は既存 shell 変数と全域 grep で衝突確認する

## 関連ページ

- [スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md)
- [機械的スイープでは挿入先コンテキストを検証してから変更を適用する](../patterns/mechanical-sweep-insertion-context-verification.md)

## ソース

- [PR #1919 review cycle 3 results](../../raw/reviews/20260719T154814Z-pr-1919-c3.md)
- [PR #1919 fix cycle 3 results](../../raw/fixes/20260719T154952Z-pr-1919-c3.md)
