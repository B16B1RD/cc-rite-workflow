---
type: "patterns"
title: "canonical 例を持つ SoT は「例が自身の enforcer を通る」ことを実測で確かめる"
domain: "patterns"
description: "過去のレビュー事例の cycle 4 で **4 reviewer が独立に検出**した欠陥クラス。"
created: "2026-07-27T17:54:54+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260727T084223Z-pr-2036.md"
  - type: "reviews"
    resource: "raw/reviews/20260802T145006Z-pr-2092.md"
  - type: "fixes"
    resource: "raw/fixes/20260802T145247Z-pr-2092.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-03T00:55:00+09:00" }
---

# canonical 例を持つ SoT は「例が自身の enforcer を通る」ことを実測で確かめる

## 概要

起点事例の cycle 4 で **4 reviewer が独立に検出**した欠陥クラス。canonical JSON 例に追加した id `F-02b` が、同じファイルが定める書式規則 `^F-[0-9]{2,}$` に違反していた。write 側はこの例を「真実の源」として写すため、そのまま従うと永続 JSON が 1 件も保存されず、既定構成では該当ステップが `exit 2` で hard fail する。

## 詳細

**なぜ規則側・例側のどちらを読んでも見つからないか**:

- 規則 `^F-[0-9]{2,}$` を読んでも「例が違反している」ことはわからない（例は別の箇所にある）
- 例 `F-02b` を読んでも「規則に違反している」ことはわからない（規則は別の箇所にある）
- 両者を突き合わせるのは人間の照合作業で、SoT が長いほど漏れる

判明したのは「例を validator に流す」**実測**によってのみだった。cycle 3 で例を追加したときは 5 reviewer 全員が見逃し、cycle 4 で 4 名が同時に検出している（cycle 3 の fix が新たな穴を作ったパターン）。

**対処**:

1. canonical 例を持つ SoT には、**例が自身の enforcer を通る fixture** を置く。強制層の script（本ケースでは `review-result-save.sh`）に例をそのまま流し、`JSON_SAVED=true` を assert する。
2. 書式規則を変更したとき、および例を追加・変更したときの**両方**で再実行する。
3. SoT が複数の canonical 例を持つなら、すべての例について実行する（本 PR では `## JSON Schema` の例と `## PR コメント形式` の Raw JSON 例の 2 つが対象だった）。

**関連する同型の欠陥**: 同じ SoT の PR コメント例に新設キーが欠けていた（write 側が template を写すとキーが脱落する）、`findings[]` の定義文が「blocking 指摘の配列」と無条件に書かれていたため literal に取ると別の返信経路が丸ごと失われる、など。canonical 例と定義文は、**それを写す consumer の視点で読み直す**と欠陥が見える。

**同型の拡張 — 新設した原則を自分の diff に適用して検算する**: 規約・原則を新設する PR では、その原則の最初の適用対象は**その PR 自身の diff** である。別の起点事例では「実需の Issue がない構造は追加しない」原則を新設した同じ PR が、consumer の存在しない記録先へ MUST を課しており、新原則そのものに自己抵触していた。3 cycle かけて撤回に至ったが、原則を書き終えた時点で自分の変更を 1 度その原則で読み直していれば 1 cycle で気づけた。canonical 例と enforcer の関係（例が規則を通るか）と、新設原則と自 diff の関係（変更が原則を通るか）は同じ形の検査であり、どちらも「規則側・対象側のどちらを読んでも気づけない」性質を持つ。

## 関連ページ

- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)
- [LLM substitute placeholder は bash residue gate で fail-fast 化する](./placeholder-residue-gate-bash-fail-fast.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](../heuristics/empirical-reproduction-over-invariant-reasoning.md)
- [記録義務を規約に書く前に、その記録先を読む consumer が実在するかを grep で確かめる](./obligation-requires-existing-consumer-before-writing.md)

## ソース

- [PR #2036 review results (cycle 5, mergeable)](../../raw/reviews/20260727T084223Z-pr-2036.md)
- [PR #2092 review results (cycle 3)](../../raw/reviews/20260802T145006Z-pr-2092.md)
- [PR #2092 fix results (cycle 3)](../../raw/fixes/20260802T145247Z-pr-2092.md)
