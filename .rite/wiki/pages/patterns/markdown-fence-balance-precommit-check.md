---
title: "Markdown code fence の balance は commit 前に awk で機械検証する"
domain: "patterns"
description: "Bash block 末尾に新規 statement を追加する際、既存の閉じフェンス ``` ``` ``` 直前に挿入すると closing fence が欠落し fence count が奇数になる silent regression が発生する。"
promote: rite-plugin
created: "2026-04-20T01:10:00+00:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260419T162557Z-pr-608-cycle2.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T011853Z-pr-2035.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-27T10:57:51+09:00" }
---

# Markdown code fence の balance は commit 前に awk で機械検証する

## 概要

Bash block 末尾に新規 statement を追加する際、既存の閉じフェンス ``` ``` ``` 直前に挿入すると closing fence が欠落し fence count が奇数になる silent regression が発生する。後続の散文や Skill 呼び出し指示が bash コードとして誤解釈され、slash command preprocessor 層や renderer 層で CRITICAL な構造破綻を引き起こす。commit 前に `awk '/^```/{c++} END{print c}' file.md` で fence 数が偶数であることを機械検証する。

## 詳細

### 事象（cycle 2）

前 fix commit で `if ! ...; then ... fi` ブロックを既存閉じフェンスの直前に挿入した際、`fi` 行の直後に独立した閉じフェンス ``` ``` ``` が必要であることを 3 箇所すべて見落とした。結果として `cleanup.md` の bash code fence count が 144 (偶数、balanced) → 153 (奇数、UNBALANCED) になり、後続の散文 + Skill 呼び出し指示が bash code として renderer / preprocessor で誤解釈される構造バグに発展した (CRITICAL × 3)。

### canonical 検証コマンド

```bash
awk '/^```/{c++} END{print c}' path/to/file.md
# 結果が偶数 (0, 2, 4, ...) なら OK、奇数なら UNBALANCED
```

より具体的に diff を見るには:

```bash
# 開始/閉じ fence のみ抽出して目視確認
grep -n '^```' path/to/file.md | head -40
# bash blocks の総数 (概算)
grep -c '^```bash' path/to/file.md
```

### 適用タイミング

- bash block 末尾に新規 statement (`fi` / `done` / 新コマンド) を追加した後
- 既存 bash block を split / merge する編集の後
- review で「indentation drift」「code block の途中から散文っぽい行」が見えたとき

### 補強策

- pre-commit hook に `awk '/^```/{c++} END{exit c%2}' file.md` を組み込む
- `/rite:lint` の command-file-check で fence balance を検査する (将来実装候補)
- reviewer は code fence 境界の違和感 (indentation drift / 散文混入) を CRITICAL 候補として検出する

### 関連する失敗様態

- code fence 内に別の code fence を置こうとした結果、外側の fence が閉じる
- `> \`\`\`bash` のような quoted fence と通常 fence の混在
- edit 時に `old_string` が複数 fence を含み、一部のみ replace される

いずれも fence balance check で即検出可能。

### 入れ子は外側を 4-backtick にする

テンプレート全体が 1 本の 3-backtick fence で囲われている文書に、記入例の fence を 3-backtick で追加すると、fence が閉じ位置で分割され **code と prose が反転する**。起点事例では追加の主目的だった記入例が prose になり、後半の推奨事項・READ-ONLY 節が code に閉じ込められた。

**この破損は 4 cycle 気付かれなかった**。fence count は偶数のまま（追加した 4 本も偶数）なので上記の balance check を素通りし、テキストとして読む限り異常が見えない。**レンダリング結果を見ないと分からない類の欠陥は、レビューでも発見が遅れる**。

処方: 外側の fence を 4-backtick (` ```` `) にすると内側の 3-backtick を透過的に含められる。同じリポジトリ内に既に先例がある場合は必ず参照する。

検出補強: fence count の偶奇だけでなく、**最外殻 fence の内側にある fence の本数**を見る。3-backtick fence の中に 3-backtick fence を書いた時点で構造は壊れている。

## 関連ページ

- [Markdown channel separation で HTML sentinel の終端性と bash tool 実行を両立させる](./markdown-channel-separation-for-terminal-sentinel.md)
- [段階分割 PR では「契約として宣言したこと」と「いま実装されていること」を時制で書き分ける](../heuristics/staged-pr-declared-contract-vs-implemented-fact-tense.md)

## ソース

- [CRITICAL × 3 fence balance](../../raw/fixes/20260419T162557Z-pr-608-cycle2.md)
