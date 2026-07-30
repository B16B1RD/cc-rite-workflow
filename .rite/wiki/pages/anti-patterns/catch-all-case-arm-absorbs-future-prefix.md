---
title: "prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する"
domain: "anti-patterns"
created: "2026-05-28T23:42:28Z"
updated: "2026-07-29T21:32:36+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260604T061732Z-pr-1267.md"
  - type: "reviews"
    ref: "raw/reviews/20260528T232433Z-pr-1177.md"
  - type: "fixes"
    ref: "raw/fixes/20260528T232834Z-pr-1177.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T234725Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T235426Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T004628Z-pr-2044.md"
tags: ["bash", "case-statement", "extensibility", "hook"]
confidence: high
---

# prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する

## 概要

`case "$VAR" in FINALIZE:*) ...;; *) ...;; esac` のように prefix で分岐する case 文で、`*)` catch-all に「意味のある既定動作」(例: 継続コマンド再注入) を置くと、将来 prefix 名前空間を拡張した際に**未知の新 prefix が silent に default 動作へ吸収される**。新 prefix が「継続」として扱われるため、追加した分岐が抜けていてもエラーにならず、誤動作が表面化しない設計脆さになる。

## 詳細

PR #1177 (`/rite:pr:iterate` 終了点の FINALIZE handoff backstop) で、Stop hook `stop-loop-continuation.sh` が handoff 値の prefix で reason を分岐する `case "$HANDOFF" in FINALIZE:*) ;; *) ;; esac` を実装した。`*)` arm は継続 handoff (`/rite:...`) を「次コマンド再注入」として扱う既定動作を持つ。

このとき **code-quality reviewer と error-handling reviewer が独立に同じ脆さを指摘** (high-confidence consensus): handoff prefix が将来 3 種類目に拡張されたとき、新 prefix は `FINALIZE:*` に一致せず `*)` へ落ちるため、意図せず「継続」として処理される。catch-all が error/fallback ではなく**正規の動作**を担っているため、分岐漏れが検出されない。

### canonical 対策

- prefix 名前空間が拡張前提なら、`*)` を「既知の継続 prefix の明示列挙」+「真に未知の値は WARNING/fail-loud」に分離する。catch-all に正規動作を載せない。
- 既知 prefix を allowed values として明示し、想定外値は sentinel/WARNING で可視化する ([bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す](../patterns/bash-initial-value-aligns-with-allowed-values.md) と同じ defensive 方針)。
- case dispatch は語彙を潰さず保持する ([Exit code semantic preservation: caller は case で語彙を保持する](../patterns/exit-code-semantic-preservation.md) と同根 — exit code でも prefix でも、default arm への意味集約は semantic loss を生む)。

### 併発した comment 責務分離の乖離

同 hook の説明コメントが「prefix で **block を分岐**」と書かれていたが、実装上 prefix が分岐するのは **reason** のみで、block 可否は「handoff が非空かどうか」という別軸で決まる。曖昧表現が直交する 2 軸 (block 可否 / reason 選択) を混同させ、後続編集者の誤読を招く。fix では「prefix で reason を分岐 (block 可否は別軸)」と機構の責務を明示する形に補正した。catch-all 脆さと同じく「prefix dispatch の意味を正確に書く」doctrine の一部。

### Successful application — prefix 名前空間拡張時の canonical 対策実装（0 findings）

PR #1177 が予見した「handoff prefix の 3 種類目拡張」が PR #1267 (cleanup→wiki:ingest→wiki:lint チェーンの Stop-hook 継続保証) で実際に発生し、本 canonical 対策がそのまま実装された: `WIKICHAIN:*` prefix 追加と**同時に**既知 prefix (`FINALIZE:*` / `WIKICHAIN:*` / `/rite:*`) を明示列挙し、`*)` catch-all から正規動作 (旧: 継続再注入文面) を排除して「WARNING (stderr) + verbatim 再注入」の fail-loud 経路へ変更した。block 自体は「handoff 非空」軸で維持され、未知 prefix も block はするが review↔fix loop の identity を僭称しない。runtime TC-13 が未知 prefix の WARNING surface + verbatim 再注入 + one-shot consume を機械検証する。

PR #1267 review では error-handling / code-quality / security の 3 reviewer が独立に canonical 準拠 (直交 2 軸責務分離の維持を含む) を検証し、0 findings / 1 cycle mergeable で landing。anti-pattern 記録から 1 週間以内に同一 hook の名前空間拡張で対策が再現適用された positive evidence であり、「拡張と同時に明示 arm を追加する」運用が catch-all 縮退を構造的に防ぐことを実証した。

## 関連ページ

- [bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す](../patterns/bash-initial-value-aligns-with-allowed-values.md)

## ソース

- [PR #1267 review results — 0 findings の successful application: WIKICHAIN prefix 追加と同時に既知 prefix 明示列挙 + 未知 prefix fail-loud 化を実装、3 reviewer 独立検証 + TC-13 機械検証で 1 cycle mergeable)](../../raw/reviews/20260604T061732Z-pr-1267.md)
- [PR #1177 review results](../../raw/reviews/20260528T232433Z-pr-1177.md)
- [PR #1177 fix results](../../raw/fixes/20260528T232834Z-pr-1177.md)

## 補強: enum の設計は「消費側の分岐数」と「相互非接頭辞」の 2 条件で決める

prefix 関係が `case` の catch-all を騙る問題は、**enum を設計する時点**で塞げる。PR #2044 は 2 つの条件を導出した。

### (1) 値は消費側の分岐数と 1:1 に対応させる

新設した `RESET` marker を「reset が失敗した」という**発生側の事実**で 1 値に定義したのが欠陥の根本だった。消費側（停止通知）は「即時再発火したか」で排他分岐する必要があり、1 値では両立できず、片方の状況で**事実と逆の説明**が出る（「review は 1 cycle も回っていません」という虚偽）。

値を分割し、発生側ではなく**消費側の分岐**で値を切ったことで解消した。

> **判断の型**: 新しい enum 値を足すときは「**これを読む側はいくつに分岐するか**」を先に数える。値が原因で切られているか結果で切られているかを確認する。

### (2) 値集合は相互に非接頭辞に保つ

分割の過程で `failed-refire` が `failed-refire-nodiag` の**厳密な接頭辞**になった。prose 照合（LLM の grep）が一致順で解決すると誤分岐する。

「完全一致で照合せよ」という指示で守るのは弱い。**値の集合を相互に非接頭辞に設計する**か、そもそも値を増やさない。本 PR は最終的に値を減らすことで構造的に解消した。

### 逆転を作らない

条件の移管により、**消費者を失った marker が完全な定義表を持ち、実際に条件となった marker には定義が無い**という逆転が生じた。**記述の重みは依存関係と一致させる。** また enum を分割したら、その分割を読む側が今も存在するかを定期的に確認する（消費者を失った enum は CLAUDE.md の「デッドコードを残さない」に抵触する）。

### 区別できないものは文面で認める

設計上どうしても 1 値が複数の原因を含む場合（発火済みを永続させない設計では、marker だけでは「リセット失敗による再発火」と「最終 cycle 途中の中断からの正常な発火」を原理的に区別できない）、断定的に書くと必ずどちらかで虚偽になる。**設計上の限界は、通知の文面で正直に反映する。**

## ソース（追記分）

- [PR #2044 review results — enum 値の意味の過負荷（3 レビュアーが独立検出）](../../raw/reviews/20260728T234725Z-pr-2044.md)
- [PR #2044 fix results — marker 値は消費側の分岐数と 1:1 に対応させる](../../raw/fixes/20260728T235426Z-pr-2044.md)
- [PR #2044 fix results (cycle 3) — enum の値集合を相互に非接頭辞に保つ](../../raw/fixes/20260729T004628Z-pr-2044.md)
