---
type: "anti-patterns"
title: "advisory データの欠陥検証を hard fail にすると primary データごと失われる"
domain: "anti-patterns"
description: "advisory（補助的）なデータの欠落・破損を検出する gate を hard fail にすると、保存処理そのものが中止され、同じファイルに載っていた primary（本体）データまで失われる。救おうとした対象より大きなものを落とす fail-unsafe。あわせて型 check を id/内容 gate の後ろに置くと、非配列でも length が非 0 になる値が件数を水増しし、非ブロッキングと明記した契約が型によって hard fail に化ける。gate の順序は「型 → 内容」。"
created: "2026-07-27T17:54:54+09:00"
updated: "2026-07-27T17:54:54+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260727T084223Z-pr-2036.md"
tags: []
confidence: high
---

# advisory データの欠陥検証を hard fail にすると primary データごと失われる

## 概要

起点事例で 2 サイクル連続して踏んだ fail-unsafe。「記録の欠落を検出する gate」を追加したところ、記録が欠落しているという理由で**保存そのものが中止**され、同じファイルに載っていた blocking findings（primary データ）まで失われた。既存テスト 5 件の失敗で発覚した。

## 詳細

**症状 1 — 欠落検出の hard fail が primary を巻き添えにする**

新設した advisory 配列 `non_blocking_findings[]` のキー欠落を `LOCAL_SAVE_FAILED` として扱った実装では、キーが無いだけで JSON ファイル全体が保存されない。守ろうとしたのは「降格記録が消えないこと」だったのに、実際に消えたのは blocking findings を含むファイル全体だった。

修正は、hard fail を **primary 側（`findings[]`）の id 欠陥に限定**し、advisory 側の欠陥は非ブロッキングな marker（`NON_BLOCKING_FINDINGS_KEY_MISSING` / `NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION`）として stderr に surface するだけに留めること。

**症状 2 — gate の順序が「内容 → 型」だと型崩れが内容の欠陥として誤診断される**

型 check を id gate の**後ろ**に置いたため、非配列で `length` が非 0 を返す値（`"abc"`→3 / `3`→3 / `{"a":1}`→1）が和集合の件数を水増しし、要素を返さない配列展開との arity 不一致で hard fail した。「この配列の欠陥は非ブロッキング」と 3 箇所（script コメント / skill / schema）に明記した契約が、**型によって破れていた**。

修正は型 check を id gate の**前**に移し、和集合検証の入力を `if type=="array" then . else [] end` で正規化すること。非配列 5 型 + キー欠落のすべてが保存継続 + marker になることを実測で確認した。

**規則**:

1. **advisory なデータの欠陥で primary なデータを巻き添えにしない**。hard fail の対象は primary 側の欠陥に限定する。
2. **gate の順序は「型 → 内容」**。型崩れを内容の欠陥として誤診断させない。
3. **「非ブロッキング」と書いた契約は、型・欠落・空・旧形式のすべてで実測する**。同一コミット内の 20 行離れた箇所で設計原則に自己矛盾していたケースなので、宣言だけでは守られない。

## 関連ページ

- [「破棄しない」を保証する記録先は永続チャネルに置き、除外契約と保存先をセットで規定する](../patterns/durable-channel-for-no-discard-guarantee.md)
- [gate を守る対象の内側に置くと、守るべき唯一の failure mode で gate も一緒に skip される](./gate-placed-inside-guarded-scope.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](../heuristics/empirical-reproduction-over-invariant-reasoning.md)

## ソース

- [PR #2036 review results (cycle 5, mergeable)](../../raw/reviews/20260727T084223Z-pr-2036.md)
