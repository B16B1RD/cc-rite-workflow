---
type: "anti-patterns"
title: "jq の has(\"key\") は値が null でも true を返す"
domain: "anti-patterns"
description: "jq の `has(\"key\")` はキーの有無だけを見る。値が JSON null でも true になるため、GraphQL の欠落フィールドと「型付きで読めるオブジェクト」を同じ条件で扱うと、読めない応答を unset と誤認して書き込みへ進む。"
created: "2026-09-02T09:04:13Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T09:04:13Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260902T080744Z-pr-2507.md"
  - type: "fixes"
    resource: "raw/fixes/20260902T081227Z-pr-2507.md"
tags: ["jq", "graphql", "null", "read-before-write"]
confidence: high
---

# jq の has("key") は値が null でも true を返す

## 概要

jq の `has("key")` はキーの有無だけを見る。値が JSON null でも true になるため、GraphQL の欠落フィールドと「型付きで読めるオブジェクト」を同じ条件で扱うと、読めない応答を unset と誤認して書き込みへ進む。

## 詳細

GitHub Projects の `fieldValues` のように、GraphQL は「キー欠落」「値が null」「`{nodes: [...]}` のオブジェクト」の 3 形を返しうる。read-before-write で「現在 Status が読めないなら書かない」を `has("fieldValues")` だけで判定すると、null 応答が unset（書いてよい）へ落ちる。

観測された 3 形と正しい扱い:

| 応答 | `has("fieldValues")` | 正しい分類 |
|------|----------------------|------------|
| キー欠落 | false | unset（書き込み可、または契約どおりの欠落扱い） |
| `"fieldValues": null` | **true** | 型として読めない → 書いてはならない |
| `"fieldValues": {"nodes": [...]}` | true | 読める。空 nodes / Status 無しは unset |

canonical 対策は存在検査を型まで広げる:

```bash
# NG: null を「ある」と誤認する
jq -e 'has("fieldValues")'

# OK: object かつ nodes が配列であることまで見る
jq -e '.fieldValues | type == "object" and (.nodes | type == "array")'
```

テストはキー欠落だけを pin しても null 経路は通らない。本番形 fixture に null と object の両方を載せる。GraphQL 応答そのものに `.errors[]` が付く場合は、フィールド型検査の前に fail-loud する（[gh api graphql は HTTP 200 + .errors[] で partial failure を返す](./gh-api-graphql-http200-partial-errors.md)）。

## 関連ページ

- [gh api graphql は HTTP 200 + .errors[] で partial failure を返す (exit code では検知できない)](./gh-api-graphql-http200-partial-errors.md)
- [jq -n create mode: 既存値を読み取ってから再構築する](../patterns/jq-create-mode-preserve-existing.md)

## ソース

- [レビュー結果](../../raw/reviews/20260902T080744Z-pr-2507.md)
- [fix 結果](../../raw/fixes/20260902T081227Z-pr-2507.md)
