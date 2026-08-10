---
title: "gh api graphql は HTTP 200 + .errors[] で partial failure を返す (exit code では検知できない)"
domain: "anti-patterns"
description: "`gh api graphql` は GraphQL レベルのエラーが起きても HTTP 200 (= `gh` の exit 0) を返し、レスポンス body に `.data` と `.errors[]` を**併存**させることがある。"
promote: rite-plugin
created: "2026-05-29T04:21:34+00:00"
updated: "2026-05-29T04:21:34+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260529T040843Z-pr-1185.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T041436Z-pr-1185.md"
tags: ["gh-cli", "graphql", "silent-failure", "error-handling"]
confidence: medium
---

# gh api graphql は HTTP 200 + .errors[] で partial failure を返す (exit code では検知できない)

## 概要

`gh api graphql` は GraphQL レベルのエラーが起きても HTTP 200 (= `gh` の exit 0) を返し、レスポンス body に `.data` と `.errors[]` を**併存**させることがある。そのため `|| { ok=0; break; }` のような exit-code ベースの guard は発火せず、`jq -e '.data.node.items'` のように「目的フィールドの存在」だけを検査すると partial response を完全データとして握り潰し、欠損したデータを権威データとして提示してしまう。canonical 対策は、items guard の**前**に `.errors[]` を検査し、非空なら fail-fast で fallback に倒すこと。

## 詳細

起点事例 (`/rite:issue:list` Phase 4.2 の GraphQL cursor paging 化) の review-fix loop で、`gh api graphql` を扱う埋め込み bash スクリプトに対し HIGH 2 件を含む 4 件の finding が surface した。中核は `gh api graphql` 特有の 2 つの落とし穴である。

### 落とし穴 1: `.errors[]` 非検査による partial response の握り潰し (HIGH)

`gh api graphql` は GraphQL の partial failure を以下の形で返す:

- HTTP ステータスは **200** (`gh` の exit code は **0**) — `cmd || { ok=0; break; }` の `||` 分岐は発火しない
- body には `.data.node.items` 等の目的フィールドが (truncate された / 部分的な内容で) 存在しつつ、`.errors[]` にエラーメッセージが併存する

したがって `echo "$page" | jq -e '.data.node.items'` のように「目的フィールドの存在」だけを guard にすると、partial data を「全データ」として後続処理に流す silent failure になる。cursor paging のように複数ページを跨ぐ処理では、途中ページの partial response が status map の取りこぼしを生む。

**canonical 対策** (items guard の前に `.errors[]` を検査して fail-fast):

```bash
gqe=$(echo "$page" | jq -r '.errors // [] | map(.message) | join("; ")' 2>/dev/null)
if [ -n "$gqe" ]; then ok=0; fail_reason="graphql errors: $gqe"; break; fi
echo "$page" | jq -e '.data.node.items' >/dev/null 2>&1 || { ok=0; fail_reason="missing .data.node.items (possible partial response)"; break; }
```

同一 codebase の `link-sub-issue.sh` は HTTP 200 + `.errors[]` の contract を承知して `.errors` を明示検査する確立慣習を持つ。`gh api graphql` を新規に書く際は exit code だけに頼らず sibling スクリプトの errors 検査慣習に揃える。

### 落とし穴 2: opaque string 変数への `-F` (typed coercion) 誤用 (LOW-MEDIUM)

`gh api graphql` の field flag は 2 種類ある:

- `-F` / `--field`: **typed coercion** あり (`true`/`false`/`null`/integer に見える値を対応する JSON 型へ変換)
- `-f` / `--raw-field`: 常に string

GraphQL の `ID!` (node id = `PVT_...` 等の base64 opaque 文字列) や `String!` (cursor = base64 opaque 文字列) のような **opaque string 変数には `-f` を使う**。`-F` を使うと、値が偶発的に integer / boolean 様の文字列だった場合に誤って型変換され、silent な型エラー (= `[projects:fetch-failed]` 等の fallback) を招く潜在リスクがある。同一ファイル内の既存規約 (例: Phase 5 系の `-f projectId=` / `-f iterationId=`) と統一すること。真の `Int!` 変数 (例: `-F number=123`) にのみ `-F` を使う。

### 同時に surface した関連 finding (本ページの主題外、参考)

- **`2>/dev/null` による gh stderr 全捨て (HIGH)**: 失敗 reason が固定文字列に潰れ真因を診断不能にする silent failure。`2>"$err"` で tempfile に退避し reason に実 stderr を埋め込む。これは stderr 処理一般の経験則であり [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md) の適用例。なお bash の `>` リダイレクトは open ごとに truncate するため、while ループ内で同一 `err` tempfile を複数の gh 呼び出しで共有しても stale 値を拾わない。
- **CRITICAL「verbatim 実行」警告と `{placeholder}` 置換必須の矛盾 (MEDIUM)**: LLM が実行するコマンド定義 `.md` で「スクリプトを一字一句 verbatim 実行・どの行も変更するな」と指示しつつ `{project_number}` / `{owner}` の placeholder 置換を必須とすると矛盾する。verbatim ブロック直前に「placeholder のみ置換可、query/jq 本文は変更不可」の carve-out を明記する (close.md / cleanup.md の確立パターン)。

## 関連ページ

- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [PR #1185 review results](../../raw/reviews/20260529T040843Z-pr-1185.md)
- [PR #1185 fix results](../../raw/fixes/20260529T041436Z-pr-1185.md)
