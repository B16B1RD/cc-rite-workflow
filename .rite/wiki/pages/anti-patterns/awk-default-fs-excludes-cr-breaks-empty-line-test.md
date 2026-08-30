---
type: "anti-patterns"
title: "awk のデフォルト FS は `\\r` を含まない — CRLF 入力で「空行」判定が壊れる"
domain: "anti-patterns"
promote: rite-plugin
description: "awk のデフォルト FS は space / tab / newline であり **`\\r` を含まない**。"
created: "2026-08-08T14:00:41+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260808T022209Z-pr-2142.md"
  - type: "fixes"
    resource: "raw/fixes/20260808T024257Z-pr-2142.md"
tags: ["awk", "crlf", "line-ending", "external-input", "portability"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-08T14:00:41+09:00" }
---

# awk のデフォルト FS は `\r` を含まない — CRLF 入力で「空行」判定が壊れる

## 概要

awk のデフォルト FS は space / tab / newline であり **`\r` を含まない**。したがって `\r` だけの行はフィールド 1 個を持つ行として扱われ、`NF` は 1 になる。「空行かどうか」を `NF` で判定している述語は、CRLF 入力に対して**空行を非空と誤判定する**。

GitHub Web UI から投稿された Issue body は CRLF になりうる。ある PR では `## 見出し` の次の空行を値行として拾い、抽出も診断も同時に外した。

## 詳細

### 是正は述語側ではなく入力捕捉時

CR を落とす場所は 2 つ考えられる。

| 場所 | 帰結 |
|---|---|
| 各述語（`NF` を見る箇所ごとに `\r` を考慮） | 述語が増えるたび同じ配慮が要る。1 箇所直しただけでは**同型欠陥の非対称**が残り、Asymmetric Fix Transcription を再生産する |
| 入力捕捉時に 1 度落とす | 下流の述語がすべて素の想定で書ける。追加の述語も自動的に守られる |

**入力捕捉時に `tr -d '\r'` 相当を 1 度通す**のが正しい。1 行で両側が閉じるなら、pre-existing の側を副作用で閉じるのはスコープ超過ではない（その旨を commit message に明記する）。

### 同じ入力から生まれる兄弟欠陥

CRLF は「空行判定」だけでなく、行末アンカーを持つ正規表現（`foo$`）や、値を切り出す `sed` 式にも同時に効く。CR 由来の欠陥を 1 つ見つけたら、**同じ入力を読む全述語**を数えてから修正範囲を決める。

## 関連ページ

- [awk の exit は END 規則を実行する — 早期終了と END フォールバックの併用は二重出力になる](./awk-exit-runs-end-rule-double-output.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [抽出述語の厳格化は「壊れた入力」と「入力なし」を同一経路へ畳み、fail-loud を構造的に壊す](./strict-predicate-collapses-broken-into-absent.md)

## ソース

- [PR #2142 review results (cycle 4)](../../raw/reviews/20260808T022209Z-pr-2142.md)
- [PR #2142 fix results (cycle 4)](../../raw/fixes/20260808T024257Z-pr-2142.md)
