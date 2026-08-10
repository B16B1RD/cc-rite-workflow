---
type: "heuristics"
title: "規約の強制度が矛盾したら、緩い側を強めるより強い側の適用範囲を絞る"
domain: "heuristics"
description: "同一ファイル内で「規則 A が記録を命じている」のに「受け皿 B の定義は optional / off by default」という強制度の矛盾が生じたとき、解き方は 2 通りある:"
created: "2026-08-03T00:55:00+09:00"
updated: "2026-08-03T00:55:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260802T143430Z-pr-2092.md"
  - type: "fixes"
    ref: "raw/fixes/20260802T143712Z-pr-2092.md"
tags: ["obligation-design", "scope-narrowing", "simplification-first", "prompt-engineering"]
confidence: high
---

# 規約の強制度が矛盾したら、緩い側を強めるより強い側の適用範囲を絞る

## 概要

同一ファイル内で「規則 A が記録を命じている」のに「受け皿 B の定義は optional / off by default」という強制度の矛盾が生じたとき、解き方は 2 通りある:

1. **緩い側（B）を強める**: `(optional, off by default)` / `SHOULD` を削除して MUST 化する
2. **強い側（A）の適用範囲を絞る**: 記録義務を A が本来対象としていた 1 ケースだけに限定する

起点事例では 1 を選んだ結果、義務が受け皿を持たないまま**全 5 カテゴリへ波及**し、次の cycle で新たな blocking 指摘を生んだ。

## 詳細

**1 が危険な理由**

矛盾の局所性を見誤る。矛盾していたのは「A が命じる特定ケース」と「B の既定値」の 1 点だけだったのに、B の緩和条件を削ると B が支配する**全ケース**に義務が及ぶ。受け皿の実体（出力テンプレート・収集・schema）がなければ、この波及は履行不能な義務の量産になる。

さらに、削除は一見「規則を短くする」ため Simplification-First の観点でも正当に見えてしまう。実際に短くなるのは B の文面だけで、**義務の総量は増えている**。

**2 が優れる理由**

- 義務対象が 1 ケースに縮むため、受け皿未定義の影響範囲も最小になる
- 元の要求（Issue の MUST）が求めていた記録範囲と一致する
- B の既定値は元のまま残るので、B が支配する他ケースの挙動は変わらない（回帰面が狭い）

**判断の目安**

矛盾を検出したら「この矛盾は何ケースについて成立しているか」を先に数える。1 ケースなら強い側を絞る。全ケースで成立しているなら緩い側を強める余地があるが、その場合も受け皿の実在確認（consumer の grep）が前提になる。

**なお 2 も万能ではない**

起点事例では範囲を絞っても受け皿がないこと自体は変わらず、次の cycle で「1 ケースでも consumer がいないなら義務は成立しない」と再指摘され、最終的に義務ごと撤回した。範囲縮小は「誰も検出できない義務違反」の件数を減らすが、「記録が人間に届かない」という性質は変えない。受け皿を用意できないなら、絞るのではなく撤回して follow-up Issue へ切り出すのが着地点になる。

## 関連ページ

- [記録義務を規約に書く前に、その記録先を読む consumer が実在するかを grep で確かめる](../patterns/obligation-requires-existing-consumer-before-writing.md)
- [同 file 内 MUST NOT vs MUST 衝突: bare form 禁止規約と bare form 出力義務の自己矛盾](../anti-patterns/same-file-must-not-vs-must-conflict.md)

## ソース

- [PR #2092 review results (cycle 2)](../../raw/reviews/20260802T143430Z-pr-2092.md)
- [PR #2092 fix results (cycle 2)](../../raw/fixes/20260802T143712Z-pr-2092.md)
