---
type: "heuristics"
title: "診断を 1 行足す修正は、外部入力・エラー経路・テスト網羅の 3 領域を同時に開く"
domain: "heuristics"
description: "診断メッセージの追加は「1 行足すだけ」に見える。"
created: "2026-08-08T14:00:41+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260808T004750Z-pr-2142.md"
  - type: "fixes"
    resource: "raw/fixes/20260808T014357Z-pr-2142.md"
tags: ["diagnostics", "review-fix-loop", "external-input", "sanitization", "test-coverage"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-08T14:00:41+09:00" }
---

# 診断を 1 行足す修正は、外部入力・エラー経路・テスト網羅の 3 領域を同時に開く

## 概要

診断メッセージの追加は「1 行足すだけ」に見える。しかし外部入力を 1 つでも文面へ埋め込んだ瞬間、**その 1 行は入力検証・出力衛生・エラー伝播・テスト網羅のすべてのレビュー対象になる**。ある PR の cycle 1 で足した WARNING 1 行に、cycle 2 で 4 件の指摘が集中し、うち 1 件は 6 reviewer 全員が独立に検出した。

## 詳細

### 1 行が開く 3 領域

| 領域 | 具体的に問われること |
|---|---|
| 外部入力 | 埋め込む値は誰が書けるか。長さ上限・CR 除去・改行畳み・制御文字中和の 4 段を通っているか |
| エラー経路 | 値の捕捉に使った `$(...)` の rc をどう扱うか。`\|\| var=""` が捕捉済みの値を破棄しないか |
| テスト網羅 | 新しい分岐に assert があるか。`assert_not_contains` に可変部分を needle にした counterweight があるか |

「診断を足す」と決めた時点でこの 4 点を同時に設計すれば 1 回で終わる。後から個別に当てると同じ行へ 3 度手を入れることになり、途中状態のたびに新しいレビュー面が生まれる。

### 4 段 idiom のコストは「番人の正しさの証明」まで含む

外部入力を診断へ通すと決めた瞬間に、長さ上限・CR 除去・改行畳み・制御文字中和の 4 段と「**そのどれが pin されているか**」という問いが同時に発生する。本 PR では 3 cycle かけて 4 段を積み上げた末に、中和モードが C1（CSI U+009B）を素通しすることが判明した。閉じるには 30 caller を持つ共有 helper への新モード追加が要る。

**そこで埋め込みをやめ「行番号だけ報告する」形へ単純化したところ、4 段と 4 件の指摘がまとめて消えた**。診断の目的が「切り分け」であって「内容の提示」でないなら、外部入力を診断チャネルへ通す経路自体を持たないほうが安い。足すコストは 4 段だけでなく、各段の番人と、番人の正しさの証明まで含む。

### 中和モードは既存 call site の多数派ではなく信頼境界で選ぶ

`--c0-only` を「既存 caller と同形だから」で採用したが、既存の利用箇所はいずれも gh/jq の stderr・ローカルパス・セッション内生成文だった。**第三者が書ける public リポジトリの Issue body が端末向け診断へ入る経路は本 site が初**で、helper の header 自身が `--c0-only` を「jq プライマリ経路依存」と限定していた。helper のモードを選ぶときは、header が書いた前提条件が自分の経路で成立するかを確認する。

## 関連ページ

- [新設した診断経路が既存の中和規約を素通りする](../anti-patterns/new-diagnostic-path-skips-existing-neutralize-convention.md)
- [`cmd=$(...) || cmd=""` は非ゼロ終了時に stdout 済みの診断 JSON を空文字列で上書きする](../anti-patterns/command-substitution-fallback-discards-diagnostic-json.md)
- [canonical helper を bypass して同等処理を inline 再実装する](../anti-patterns/canonical-helper-bypass.md)

## ソース

- [レビュー結果](../../raw/reviews/20260808T004750Z-pr-2142.md)
- [fix 結果](../../raw/fixes/20260808T014357Z-pr-2142.md)
