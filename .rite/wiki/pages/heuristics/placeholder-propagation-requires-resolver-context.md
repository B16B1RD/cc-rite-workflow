---
type: "heuristics"
title: "placeholder 伝播は実行主体の解決経路を確認してから適用する"
domain: "heuristics"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/heuristics/placeholder-propagation-requires-resolver-context.md"
description: "`{plugin_root}` / `{owner_repo}` のような literal substitution 方式の placeholder を新しいファイルへ展開する際は、「そのファイルを読んで実行する主体が、placeholder を解決する手段を持つか」を先に確認する。"
created: "2026-07-20T01:15:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260719T154814Z-pr-1919-c3.md"
  - type: "fixes"
    resource: "raw/fixes/20260719T154952Z-pr-1919-c3.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T163426Z-pr-3058.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T164422Z-pr-3058.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-24T17:20:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-24T17:20:00Z" }
---

# placeholder 伝播は実行主体の解決経路を確認してから適用する

## 概要

`{plugin_root}` / `{owner_repo}` のような literal substitution 方式の placeholder を新しいファイルへ展開する際は、「そのファイルを読んで実行する主体が、placeholder を解決する手段を持つか」を先に確認する。解決経路のないコンテキストへ伝播すると、placeholder が literal のまま実行され、伝播前より悪い無条件失敗（回帰）を生む。

## 詳細

`-R {owner_repo}` 伝播スイープで reviewer agent 定義（`agents/tech-writer-reviewer.md`）にも伝播したところ、spawn される reviewer subagent は user prompt に diff / spec / shared principles しか受け取らず、`{owner_repo}` の Legend も `{plugin_root}`（canonical 解決スニペットの実行に必須）も持たないため、literal `{owner_repo}` のまま gh が実行され `expected the "[HOST/]OWNER/REPO" format` で必ず失敗する状態になった。伝播前は gh の remote 推論で（alias 環境以外では）動いていたため、全環境で壊す回帰だった。

- ファイル種別ごとに実行主体と解決経路が異なる: SKILL.md（orchestrator LLM、Legend + canonical スニペットあり）/ references（SKILL.md 経由で参照、注記で解決）/ agent 定義（subagent の system prompt、解決経路なし）
- 差し戻す場合は、canonical 文書の適用除外リストに理由付きで追記して再発を防ぐ（「reviewer agent 定義は {plugin_root}/{owner_repo} 未解決コンテキスト」）
- 同名の識別子でも形式が違うものが近接すると誤置換を誘発する（shell 変数 `$owner_repo` = TAB 区切り vs placeholder `{owner_repo}` = slash 形式）。新設 placeholder は既存 shell 変数と全域 grep で衝突確認する

### 同じ手順書の中でも「解決より前の使用」は未解決のまま実行される

解決手段を持つ主体（SKILL.md を読む orchestrator）の中でも、解決の**順序**が問題になる。共通 helper への一括置換で、ある手順書の早い段の fenced bash に `{plugin_root}` を新しく持ち込んだところ、その手順書では `{plugin_root}` を解決する手順が後段にしか無かった。手順どおり上から実行すると、最初の使用時点では値が決まっておらず、placeholder が literal のまま helper パスに渡る。同じ置換を受けた別の手順書では解決手順が先にあったため問題にならず、手順書ごとに結果が割れた。

- 依存を増やす置換（インライン処理を helper 呼び出しへ置き換える等）では、**手順書ごとに**「解決手順が最初の使用より前にあるか」を確認する。置換対象の全 caller を一律に扱わない
- 解決手順が後段にしか無い手順書では、同じ bash block の中で先に解決する（解決スニペットを使用箇所の直前へ持ってくる）
- 「解決手段があるか」（本ページ冒頭の論点）と「解決が使用より先か」は別の検査で、前者を満たしても後者で落ちる

## 関連ページ

- [スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md)
- [機械的スイープでは挿入先コンテキストを検証してから変更を適用する](../patterns/mechanical-sweep-insertion-context-verification.md)
- [同じ設定値を独立した bash 呼び出しで複数回読むなら、不在・読み取り不能の扱いを読み取り箇所ごとに揃える](./config-read-sites-each-handle-absence-and-unreadable.md)

## ソース

- [レビュー結果](../../raw/reviews/20260719T154814Z-pr-1919-c3.md)
- [fix 結果](../../raw/fixes/20260719T154952Z-pr-1919-c3.md)
- [レビュー結果](../../raw/reviews/20260924T163426Z-pr-3058.md)
- [fix 結果](../../raw/fixes/20260924T164422Z-pr-3058.md)
