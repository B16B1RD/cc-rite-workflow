---
type: "patterns"
title: "LLM が読む出力ストリームで marker を契約にするには prefix・行頭・デリミタ・識別子スコープの 4 条件すべてが要る"
domain: "patterns"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/patterns/llm-read-marker-contract-four-conditions.md"
description: "SKILL.md の bash ブロックが `[CONTEXT] X=1` 形式の marker を stdout/stderr に出し、同ファイルの散文（完了報告の判定ルール）を LLM が読んで分岐する設計は rite の基本構造である。"
created: "2026-07-26T10:05:51Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260726T055002Z-pr-2022.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T033136Z-pr-2022.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T042425Z-pr-2022.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T031335Z-pr-2022.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T024606Z-pr-2022.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T001219Z-pr-2022.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T004149Z-pr-2022.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T000331Z-pr-2022.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T094803Z-pr-2022.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-26T10:05:51Z" }
---

# LLM が読む出力ストリームで marker を契約にするには prefix・行頭・デリミタ・識別子スコープの 4 条件すべてが要る

## 概要

SKILL.md の bash ブロックが `[CONTEXT] X=1` 形式の marker を stdout/stderr に出し、同ファイルの散文（完了報告の判定ルール）を LLM が読んで分岐する設計は rite の基本構造である。この emitter/consumer 契約は 4 つの条件が揃って初めて成立し、どれか 1 つでも欠けると「やっていないことを完了と報告する」false-success が成立する。起点事例は 11 cycle かけてこの 4 条件を 1 つずつ発見した。

## 詳細

### 4 つの必要条件

1. **`[CONTEXT] ` prefix 込みで照合する。** marker 名だけで照合すると部分文字列衝突が起きる。`REMOTE_BRANCH_DELETE_FAILED` は `BRANCH_DELETE_FAILED` を部分文字列として含むため、非アンカー照合ではリモート側の行にローカル側のルールが先に一致し、リモートの残渣に対してローカル削除コマンドを案内する誤処方になる。衝突が 1 件だけでも、改名ではなく照合のアンカー化で塞ぐ。改名はその 1 件しか塞がないが、アンカー化は同じ prefix 族の marker を今後足しても構造的に衝突しなくなる。

2. **位置（行頭）も規約に含める。** prefix だけアンカーしても、同じ出力ストリームに外部由来テキスト（git の stderr 等）を流す設計では、行中に現れた marker 断片を排除できない。規約は個々のルール行に複製せず、1 段落で全ルールに掛ける（9 箇所に「行頭が」と書き足すより drift しない）。ただし段落の自己限定（「以下のルールで『行があるとき』と書いた箇所」）は fallback（「いずれの行も無いとき」）に届かないため、肯定・否定の両方を明示的に含める。

3. **外部由来テキストはデリミタで囲んで data 扱いにする。** 行頭一致だけでは足りない。複数行 stderr の 2 行目以降は列 0 に着地するため、行頭一致を突破する。`--- dirty files begin ---` / `--- end ---` のようなデリミタで囲み、その区間は一律 data と規定する。契約は「サイト列挙」ではなく「性質」で書く — 退避サイトが増えるたびに列挙の更新漏れが起き、散文とコードが drift する。なお **デリミタは可読性の仕組みであり、data 自身が終端行を騙る経路を塞ぐのはインデント（列 0 に到達させないこと）の側**。両者を規約に書き分ける。`sed 's/^/  /'` は改行区切りの行頭にしか効かないため、インデントを security boundary にするなら `tr -d '\r'` を挟む。

4. **識別子までスコープし、複数一致は recency で解決する。** 同一セッションで同じ skill をループ invoke する設計（`/rite:batch-run --merge` が Issue ごとに `/rite:cleanup` を同一会話で呼ぶ）では、先行 Issue の失敗 marker が後続 Issue の完了報告を汚す。marker が `; branch=X` を持っていても照合側が marker 名までしか見ていなければスコープは実質存在しない。**評価順序の入れ替えは解にならない** — 失敗先頭なら stale な失敗が実成功を潰し、成功先頭なら stale な成功が実失敗を潰す。識別子は Issue 間の衝突しか解かないため、同一対象への再実行は recency（最後の出現）でしか識別できない。recency を導入するときは「上から評価し最初に一致」型の既存規約と正面から矛盾しないか照合すること。

### 「marker 不在 = 成功」を符号化に使わない

失敗だけ marker を出し成功は marker 不在で表す符号化は、不在が「成功」「未実行」「出力喪失」の 3 状態に多重定義される。consumer がそれを一意に断定すると false-success が復活する。**成功も positive marker で表す**のが構造的な解。

ただし fallback の意味は emitter の設計に依存する。「4 経路すべてが marker を出す」ステップでは marker 不在 = 未確認だが、「成功時は marker を出さない」ステップでは marker 不在 = 成功でよい。同じファイル内で規約が分かれるときは、その前提の違いを fallback 自身に明記しないと、後続の保守者が「直し忘れ」として揃えてしまう。

### 状態変更を伴う分岐には必ず失敗 marker を置く

3 分岐ガード（存在 / 不在 / 判定不能）を導入したとき、実際に `git push --delete` を実行する「存在」分岐だけ成否を捨てていた事例がある。下流が「marker 不在 = 成功」と解釈する契約だったため、削除失敗が完了として報告された。**「marker が無い = 成功」と書く前に、その分岐が本当に失敗し得ないかを確認する。**

### fallback 条件は marker family でスコープする

同じ出力ストリームに 2 系統（ローカル / リモート）の marker が流れる場所で、無条件の「いずれの `[CONTEXT]` 行も無いとき」を書くと、正常系では片方の marker が必ず存在するためリテラルには常に偽になり、判定オペランドが未定義になる。fallback 条件は必ず marker family（`FOO_*`）でスコープする。

### marker 値に外部由来の値を無エスケープで載せない

marker に外部由来の値（ブランチ名）を載せる設計では、値がデリミタ文字を含むと右端境界を騙って別エンティティの判定へ誤帰属する。エンコード規約を emitter/consumer の両側へ増やすより、契約を満たせない入力を fail-fast で弾く方が単純。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [Success-only Sentinel Design — sub-skill abort path sentinel 未定義](../anti-patterns/success-only-sentinel-design.md)

## ソース

- [fix 結果](../../raw/fixes/20260726T055002Z-pr-2022.md)
- [fix 結果](../../raw/fixes/20260726T033136Z-pr-2022.md)
- [レビュー結果](../../raw/reviews/20260726T031335Z-pr-2022.md)
