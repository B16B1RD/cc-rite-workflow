---
type: "patterns"
title: "検出範囲を広げる修正は「広がった」と「広がりすぎていない」を対で pin する"
domain: "patterns"
description: "検出器が取りこぼしていた入力を拾えるようにする修正で、positive fixture（新しく拾えるようになった形）だけを足すと**拡張の上限が守られない**。"
created: "2026-08-06T22:40:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260806T103316Z-pr-2124.md"
  - type: "fixes"
    resource: "raw/fixes/20260806T124959Z-pr-2124.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-06T22:40:00+09:00" }
---

# 検出範囲を広げる修正は「広がった」と「広がりすぎていない」を対で pin する

## 概要

検出器が取りこぼしていた入力を拾えるようにする修正で、positive fixture（新しく拾えるようになった形）だけを足すと**拡張の上限が守られない**。広げすぎた場合は次 cycle で誤検知として返ってくるが、そのときテストは green のままなので原因の切り分けに時間がかかる。拡張の**下限と上限を対で pin する**。

## 詳細

### 対で置く fixture（cycle 5）

第 3 のハンドル綴り `x=$(bash ".../_mktemp-stderr-guard.sh" ...)` を追跡対象に足した。実装は「**行内に guard 名がある場合に限り** `x=$(bash` 形を拾う」という条件付きにした。この条件を落とすと、ツリー内のあらゆる subprocess capture がハンドル扱いになる。

| fixture | 役割 |
|---|---|
| T-03h: guard 綴りを追跡する | 拡張の**下限**（広がったこと） |
| T-04h: guard 以外の `$(bash ...)` は追跡しない | 拡張の**上限**（広がりすぎていないこと） |

片方だけだと「広げた」ことしか守られない。

### 件数ではなく個々のハンドルを assert する（cycle 2）

1 論理行が複数の tempfile を作る形（`a=$(mktemp) && b=$(mktemp)`）を拾えるようにしたとき、`Total findings: 4` だけを assert すると**片方のハンドルが登録漏れしても別の行が 1 件余計に出れば green になりうる**。`multi-handle.sh:3 .*\$tmp_out` のように「どの行のどのハンドルか」を 4 本個別に assert する。

### 検証の順序（cycle 2 の fix が踏んだ 4 段）

1. 指摘の existing_call_site を**実ファイルで確認**する（`lib/git-status-filtered.sh:45`）
2. fixture で修正前後の差を**実測**する（1 件 → 4 件）
3. **全域走査で誤検知が増えていないことを確認**する（93 ファイル 0 件のまま）
4. 全スイート green（116/116）

(3) を飛ばすと「検出を広げたら誤検知も増えた」を次 cycle まで見逃す。

### 実装側の注意: 離れた位置の綴りは 2 段構えで拾う

guard 綴りは `x=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \` の形で**継続行に跨がる**ため、`=` の直後に guard 名を要求する regex では 1 件も一致しない。「行内に識別語があること」を先に確認してから assignment 形を収集する 2 段構えにする。

### 分岐の追加ではなく既存ロジックの一般化を選ぶ

cycle 2 で「1 行の 2 個目以降のハンドル」を拾えるようにした修正は、awk の `if (match(...)) return` を `while (match(...)) { 収集; s = 残り }` へ**一般化**するものだった。1 ケース専用の分岐を足す修正だと、次 cycle でその分岐自体が新たなレビュー対象面になって指摘を再生産する。

## 関連ページ

- [同じ処理を 2 経路で実装したら fixture の「意地悪さ」も 2 経路で揃える](../heuristics/dual-path-implementation-needs-matching-adversarial-fixture.md)
- [accept fixture と reject fixture は設計目的が逆 — 安全側の形状を両方に適用すると順序契約が pin できなくなる](../heuristics/accept-vs-reject-fixture-design-inversion.md)
- [検出 grep と mutation (Edit old_string) は同一の文字列 strictness で実装する](./detection-mutation-strictness-symmetry.md)

## ソース

- [PR #2124 fix results (cycle 2)](../../raw/fixes/20260806T103316Z-pr-2124.md)
- [PR #2124 fix results (cycle 5, final)](../../raw/fixes/20260806T124959Z-pr-2124.md)
