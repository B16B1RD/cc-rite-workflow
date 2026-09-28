---
type: "heuristics"
title: "外部ツールの入力仕様は公式ドキュメントの原文で確かめ、テスト fixture は実際に届く形で組む"
domain: "heuristics"
description: "外部ツールの入力（hook の payload のフィールド名など）を文書へ写すとき、調査用エージェントや要約モデルの回答には実在しないフィールド名が混じることがある。公式ドキュメントの原文の入力表と例の JSON で確かめるまで契約として書かない。テスト fixture を同じ誤った前提で組むと、実装がそのフィールドを読まない限りテストは green のまま誤りを検出しない。"
created: "2026-09-28T06:02:43Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T06:02:43Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260928T053923Z-pr-3390.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T054820Z-pr-3390.md"
tags: ["external-spec", "documentation", "test-fixture", "hook", "verification"]
confidence: medium
---

# 外部ツールの入力仕様は公式ドキュメントの原文で確かめ、テスト fixture は実際に届く形で組む

## 概要

外部ツールの入力（hook の payload のフィールド名など）を文書へ写すとき、調査用エージェントや要約モデルの回答には実在しないフィールド名が混じることがある。公式ドキュメントの原文の入力表と例の JSON で確かめるまで契約として書かない。テスト fixture を同じ誤った前提で組むと、実装がそのフィールドを読まない限りテストは green のまま誤りを検出しない。

## 詳細

### 起きたこと

利用上限などで止まっていた時間を停滞診断の実作業時間から除く hook を文書化したとき、hook の payload のフィールド名を調査用の回答から転記したところ、公式ドキュメントに存在しない名前（出典では `error_type`）が入った。要約は原文の構造を保たないため、もっともらしい名前が補われても読み手には区別がつかない。

### テストが誤りを捕まえなかった理由

テスト fixture も同じ誤った名前で payload を組んでいた。実装がそのフィールドを読んでいなければ、名前が違っても結果は変わらず、テストは green のままになる。fixture が実装や文書と同じ前提から作られると、その前提の誤りはテストでは見えない。

### 直し方

- フィールド名・値・例は、公式ドキュメントの原文（raw markdown の入力表と例の JSON）を取得して確かめる。要約やエージェントの回答は探索の手がかりに留め、契約の根拠にしない
- fixture は実際に届く形の payload（原文の例）を元に組む
- 原文に書かれていない挙動は未確認として書き、実機で確かめるまで断定しない。出典の例では、hook が subagent の中でも発火し、そのとき payload に `agent_id` が付くことは原文で確かめられたが、subagent の API エラーで当該 hook が発火するかは原文に記載が無く、実機確認が要るとされた

### 同じ変更で限定した主張

他ホスト向けの制約文（未対応ホストでは停止時間を除かない）が無条件の言い切りになっていたが、recover の経路では閉じていない区間が中断として閉じられる例外があった。制約文は通常経路だけでなく、recover のような別の閉じ方の経路とも照合し、例外があれば主張を限定する。

## 関連ページ

- [外部 API の enum を散文へ写す前に値域を introspection で実測する](./external-api-enum-domain-introspect-before-prose.md)
- [セッション単位の state を読む案内は、同じ session_id で入る入口を基準に選ぶ — テストはホストの入力形で呼ぶ](./session-scoped-guidance-targets-same-session-entry.md)
- [ドキュメントが提示する解決策は上流ソース（公式ドキュメント・issue tracker）で機能を裏取りする](./documentation-remedy-upstream-verification.md)

## ソース

- [レビュー結果（要約経由で実在しないフィールド名が混入し、fixture も同じ誤りで組まれていた）](../../raw/reviews/20260928T053923Z-pr-3390.md)
- [fix 結果（公式原文で確かめ、fixture を実際に届く形で組む）](../../raw/fixes/20260928T054820Z-pr-3390.md)
