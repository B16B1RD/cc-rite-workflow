---
title: "fix コメント / commit message で hallucinated canonical reference を生成する"
domain: "anti-patterns"
created: "2026-04-19T03:30:00+00:00"
updated: "2026-04-19T03:30:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260419T025335Z-pr-586.md"
tags: []
confidence: high
---

# fix コメント / commit message で hallucinated canonical reference を生成する

## 概要

fix サイクルで「canonical 参照」をコメントや commit message に書く際、Claude が実在しないファイル / 行番号 / anchor を生成する (hallucinate) リスクがある。PR #586 cycle 2 で「lint.md L1586-L1591 参照」と commit message に記載されたが実ファイルには該当行が存在せず、reviewer が `wc -l` で実在検証して cycle 3 で発覚した。行番号参照は drift しやすく、かつ LLM が「それっぽい数字」を生成する経路になるため、anchor / Phase 番号 / パス + パターン説明で参照するのが canonical。

## 詳細

### 発生事例 (PR #586 cycle 3)

cycle 2 fix commit で「canonical reference として bash-trap-patterns.md の `#signal-specific-trap-template` 節および lint.md L1586-L1591 を参照」と書いたが:

- bash-trap-patterns.md の anchor `#signal-specific-trap-template` は実在 (正)
- lint.md の L1586-L1591 は実在しない (hallucinated) — lint.md の行数を `wc -l` したら 1500 行未満だった
- reviewer が cycle 3 で実在検証して F-03 として HIGH 検出

同じ commit で正しい anchor と hallucinated 行番号が混在したため、読者は「片方が正なのでもう片方も正だろう」と盲信する経路が生まれた。

### 失敗の構造

1. fix 時に「canonical に準拠した」旨を commit message に書きたい
2. 具体性を出すために「ファイル + 行番号」を足す
3. LLM (Claude) が過去の session で見た別の行番号を再利用し、今のファイル状態と整合しない数字を生成する
4. 読者 (reviewer / future-self) は「行番号が書かれているから実在するだろう」と信じる
5. 検証の手間が高いため silent に drift が固定される

### Canonical pattern

1. **行番号参照を書かない**: 常に anchor (`#signal-specific-trap-template`) / Phase 番号 (`Phase 5.0.c`) / function 名 / heading 文字列で参照する
2. **行番号が必要な場合は生成時に `wc -l` で実在検証する**: commit message / コメントに `L1586-L1591` を書く前に、当該ファイルに対して `wc -l` + `sed -n '1586,1591p'` で実在と内容を確認する
3. **canonical reference 参照は literal 文字列で書く**: 「bash-trap-patterns.md の `## Signal-Specific Trap Template` 節」のように heading 文字列を引用すれば grep で辿れる
4. **レビュー側の検証手順**: reviewer は commit message / コメントに行番号が含まれていたら必ず `sed -n '{N},{M}p'` で実在確認する checklist を持つ

### 関連する失敗モード

- LLM は「もっともらしい行番号」を過去の session 経験から合成しやすい。`L1` のようなエッジケースでなく、`L1586-L1591` のような具体的な数字を見たら逆に警戒する
- ファイル編集を伴う PR では、commit message 内の他所参照が本 PR の変更で drift する可能性も同時にチェックする (「大量行挿入時の行番号 drift」とは異なるが同型の検出手順が有効)

## 関連ページ

- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](./fix-comment-self-drift.md)

## ソース

- [PR #586 cycle 3 fix (hallucinated L1586-L1591 の修正)](../../raw/fixes/20260419T025335Z-pr-586.md)
