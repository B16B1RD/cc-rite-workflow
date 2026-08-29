---
type: "heuristics"
title: "全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin"
domain: "heuristics"
description: "「本経路に来るのは別 live セッション在席時のみ」「3 gates all pass のときのみ reap」のような**全称主張（排他性・網羅性）を含む散文**は、新しい到達経路やゲート例外が追加されると、**その行自体は未変更のまま偽になる**（comment rot: 周辺コードの変更が未変更行を偽化する）。"
created: "2026-07-21T18:30:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260721T173620Z-pr-1959.md"
  - type: "fixes"
    resource: "raw/fixes/20260721T173955Z-pr-1959.md"
  - type: "reviews"
    resource: "raw/reviews/20260721T175725Z-pr-1959.md"
  - type: "reviews"
    resource: "raw/reviews/20260721T181434Z-pr-1959.md"
  - type: "reviews"
    resource: "raw/reviews/20260829T113539Z-pr-2461.md"
tags: ["comment-rot", "cause-neutral", "exclusivity-claim", "doc-sync", "not-grep-pin", "quantifier-strengthening"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-29T11:40:00+09:00" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-08-29T11:40:00+09:00"
---

# 全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin

## 概要

「本経路に来るのは別 live セッション在席時のみ」「3 gates all pass のときのみ reap」のような**全称主張（排他性・網羅性）を含む散文**は、新しい到達経路やゲート例外が追加されると、**その行自体は未変更のまま偽になる**（comment rot: 周辺コードの変更が未変更行を偽化する）。起点事例では sandbox マスク skip という第 2 の deferral ルート追加により、emit 文面・checkbox ロジックを直した後も、説明散文・定義グロス・経路注記・overview 要約（SPEC.md）の計 5 箇所に旧排他帰属が 3 cycle にわたり残存した。

## 詳細

### 修正の全数洗い手順

1. **同じ marker / 概念を説明する箇所を旧文面 grep で全数列挙する**: emit 文面（WARNING / echo）だけでなく、(a) bash block 冒頭の説明コメント、(b) marker の定義グロス（「XXX=1（〜のケース）」）、(c) 経路注記（in_main 等の分岐説明）、(d) overview 文書の要約行（SPEC の absolute 主張）まで対象にする
2. **帰属が確定している箇所は触らない**: marker 由来で原因が確定する分岐（live-cwd 検知の「別セッション使用中」）は正しい帰属であり、中立化の対象外。確定帰属と原因不定を区別して直す
3. **原因中立文面に倒す**: 「まだ削除されていない作業ツリーで使用中のため」のように原因を断定しない文面は、将来の第 3 のルート追加にも耐える
4. **assert_not_grep pin で再発遮断**: 旧文面の識別トークンを not_grep pin にして、コピペ由来の復活を機械検出する

### 量化子を強める編集そのものも同じ失敗を起こす

偽化の契機は経路追加だけではない。**列挙を足す編集が量化子を変える**場合、その編集自体が同じ失敗を作る。`Everything else (A, B)` を `Every other reader (e.g. A, B, C, D)` へ変える修正は、表面上は「例を 2 つ足した」だけに見えるが、実際には「名指し 3 件への言明」から「全 reader への全称」への強化にあたる。この形では**追加した 2 例だけでなく、既存 3 例も新しい量化子の下で成立するか**を実測し直す必要がある。追加分だけを検証して通すと、強化された主張が既存メンバーで偽のまま残る。

同じ文書内で閉じた列挙と開いた例示を併置するときは、どちらであるかを表記で区別する。網羅性が主張の核（例:「legacy を書きうる経路は 2 つだけ」）なら閉じたまま書き、将来増えうる側（例:「legacy へ倒れない reader の例」）には `e.g.` を付ける。この書き分けがあると、読み手が列挙の性質を取り違えず、後続の編集者も「ここへ足してよいか」を判断できる。

### 管轄が別 Issue の Non-Target ドキュメント

drift 先が Issue の Non-Target（別 Issue の管轄と明記）である場合は、本 PR で触らず**管轄 Issue へコメントで申し送りを配線**する。新規起票は重複になる。握り潰しにならないよう、完了報告にも明示する。

## 関連ページ

- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)
- [Documentation review は対応する実装側の grep verify を必須 step とする](../heuristics/docs-review-implementation-grep-verification.md)
- [新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される](../anti-patterns/upstream-silent-path-defeats-new-logged-guard.md)

## ソース

- [PR #1959 review cycle 2 (説明散文の排他性残存を検出)](../../raw/reviews/20260721T173620Z-pr-1959.md)
- [PR #1959 fix cycle 2 (中立化 + not_grep pin)](../../raw/fixes/20260721T173955Z-pr-1959.md)
- [PR #1959 review cycle 3 (overview 要約 SPEC.md の absolute 主張 drift)](../../raw/reviews/20260721T175725Z-pr-1959.md)
- [PR #1959 review cycle 4 (残存 0 確認 + Non-Target doc の管轄 Issue 配線)](../../raw/reviews/20260721T181434Z-pr-1959.md)
- [PR #2461 review cycle 2 (量化子を強める編集が既存メンバーの再検証を要求する)](../../raw/reviews/20260829T113539Z-pr-2461.md)
