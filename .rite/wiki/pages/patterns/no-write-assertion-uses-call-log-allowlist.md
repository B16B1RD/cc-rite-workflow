---
type: "patterns"
title: "「書き込みが起きない」の検査は、呼び出しログの全行が読み取りであることの allowlist で行う"
domain: "patterns"
promote: rite-plugin
description: "外部状態が変わらないことを前後比較で assert しても、スタブが書き込みを反映しなければどんな実装でも通る。書き込み系の不在を denylist で探すと新しい書き込みの形を拾わないので、呼び出しログの全行が読み取りであることを allowlist で検査する。"
created: "2026-09-30T04:20:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-30T04:20:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260930T015930Z-pr-3468.md"
  - type: "fixes"
    resource: "raw/fixes/20260930T024747Z-pr-3468.md"
tags: []
confidence: high
---

# 「書き込みが起きない」の検査は、呼び出しログの全行が読み取りであることの allowlist で行う

## 概要

外部状態が変わらないことを前後比較で assert しても、スタブが書き込みを反映しなければどんな実装でも通る。書き込み系の不在を denylist で探すと新しい書き込みの形を拾わないので、呼び出しログの全行が読み取りであることを allowlist で検査する。

## 詳細

### 空振りする assert

「台帳は変わらない」を、台帳コメントの内容を実行前後で比べて検査していた。ところが gh のスタブはそのファイルに書き込まず、PATCH は失敗コードで終わるだけだったので、実装が台帳へ書き込もうとしても値は変わらず、assert は常に通った。

### denylist も漏れる

次に「PATCH / edit の呼び出しが無い」ことを検査したが、記録コメントを新規作成する形（`gh issue comment`）は列挙に無く、そちらで書き込む実装を検出できなかった。

### allowlist にする

スタブが受けた呼び出しをすべてログに残し、全行が読み取り（`repo view` / `pr view` / `api user` / `issue view` / コメントの GET）であることを検査する。書き込みの形を列挙しないので、新しい書き込み経路も落ちる。assert を足したら、書き込みを 1 つ加える変異で実際に落ちることを確かめる。

## 関連ページ

- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)

## ソース

- [fix 結果](../../raw/fixes/20260930T015930Z-pr-3468.md)
- [fix 結果](../../raw/fixes/20260930T024747Z-pr-3468.md)
