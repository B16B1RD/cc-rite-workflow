---
title: "LLM 向けコマンド spec の placeholder は解決元 entity を一意化する (単一 {number} を {issue_number}/{pr_number} に分離)"
domain: "patterns"
description: "LLM 実行 command spec で単一 `{number}` を `gh issue view` / `gh pr view` 双方の代入先に流用すると、issue/pr 単一番号空間ゆえ代入先 entity が非一意で 404・誤参照を招く。`{issue_number}` / `{pr_number}` に分離し verify-then-fallback 解決を明記、位置引数の振り分けは決定テーブルで明示、SPEC 表の英日 Arguments 列も対称追記する。過去のレビュー事例 cycle 1 で実測。"
promote: rite-plugin
created: "2026-06-02T03:50:58Z"
updated: "2026-06-02T03:50:58Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260602T025347Z-pr-1244.md"
  - type: "fixes"
    ref: "raw/fixes/20260602T025909Z-pr-1244.md"
tags: ["prompt-engineering", "llm-command-spec"]
confidence: high
---

# LLM 向けコマンド spec の placeholder は解決元 entity を一意化する (単一 {number} を {issue_number}/{pr_number} に分離)

## 概要

LLM が実行する command spec (`.md`) で、単一の汎用 placeholder `{number}` を `gh issue view {number}` と `gh pr view {number}` の両方の代入先に使うと、LLM が「どちらの entity 番号か」を一意に解決できず 404・誤参照を招く。GitHub の issue/pr は単一番号空間を共有するため、`{number}` だけでは曖昧。placeholder を `{issue_number}` / `{pr_number}` に**分離**し、各々の解決手順 (verify-then-fallback) を明記する。加えて位置引数の振り分け規則 (難易度ヒント vs 番号トークン等) は決定テーブルで明示する。

## 詳細

起点事例 (`/rite:learn` spec) の cycle 1 で、新規コマンド spec への review 指摘 3 件が「LLM 向け実行手順書としての placeholder 解決・引数パースの曖昧さ」に集約した。

### 落とし穴 1: 単一 `{number}` placeholder の代入先非一意

`{number}` 1 つを issue view と pr view の双方に流用すると、LLM が代入先 entity を一意に定められず 404・誤参照を招く。

**canonical 対策**:

- placeholder を `{issue_number}` / `{pr_number}` に分離する。
- GitHub の issue/pr 単一番号空間特性を利用した `#N` の **verify-then-fallback** 解決を書く (`gh pr view N` を試し → 成功なら PR とみなし `Closes` から Issue を導出 / 失敗 (not-found) なら Issue 扱い)。失敗種別の区別は [外部コマンド (gh) 失敗時に not-found と一時障害を区別せず別経路へ落とすのは silent failure](../anti-patterns/external-command-failure-origin-distinction.md) を参照。
- 番号不明時は該当 step を skip する明示分岐を置く。

### 落とし穴 2: 位置引数の振り分け規則が決定テーブルに無い

`/rite:learn eli5 1243` のように難易度ヒントと番号を取りうるコマンドで、振り分け規則が無いと LLM が `eli5` を番号と誤認する分岐が生じる。Phase 冒頭に「難易度ヒント / 番号トークン」の振り分け規則を決定テーブル (または 1 文の明示ルール) として置く。

### 落とし穴 3: SPEC コマンド表の Arguments 列の英日非対称

`docs/SPEC.md` / `docs/SPEC.ja.md` のコマンド表で、新コマンドの第 2 引数 (difficulty hint) が片方の表から欠落していた (tech-writer が引数列の英日対称性を起点に検出)。両ファイルに対称追記する ([Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) 対策)。table セル内のパイプは `\|` でエスケープする house pattern に揃える。

### 教訓

LLM-facing command spec のレビューでは「placeholder の解決元 (issue 番号 vs pr 番号) を一意に書く」「位置引数の振り分け規則を決定テーブルに明記する」が繰り返し問われる観点。修正は全て doc/spec 文言の明確化で、コード実体の挙動変更を伴わず、既存 house パターン (`close.md` の gh フラグ、SPEC の `\|` table escape) に揃えることで新規ジャーゴン導入を回避できた。

## 関連ページ

- [LLM substitute placeholder は bash residue gate で fail-fast 化する](./placeholder-residue-gate-bash-fail-fast.md)
- [外部コマンド (gh) 失敗時に not-found と一時障害を区別せず別経路へ落とすのは silent failure](../anti-patterns/external-command-failure-origin-distinction.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1244 review results](../../raw/reviews/20260602T025347Z-pr-1244.md)
- [PR #1244 fix results](../../raw/fixes/20260602T025909Z-pr-1244.md)
