---
type: "patterns"
title: "canonical 例を持つ SoT は「例が自身の enforcer を通る」ことを実測で確かめる"
domain: "patterns"
description: "SoT が書式規則と canonical 例の両方を持ち、その規則を強制する script を名指ししている場合、例が規則に違反していても規則側・例側のどちらを読んでも気づけない。write 側は例を「真実の源」として写すため、違反した例は成果物が enforcer に reject される形で顕在化する。例を実際に validator へ流す fixture を置き、規則変更時に必ず再実行する。"
created: "2026-07-27T17:54:54+09:00"
updated: "2026-07-27T17:54:54+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260727T084223Z-pr-2036.md"
tags: []
confidence: high
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

## 関連ページ

- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)
- [LLM substitute placeholder は bash residue gate で fail-fast 化する](./placeholder-residue-gate-bash-fail-fast.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](../heuristics/empirical-reproduction-over-invariant-reasoning.md)

## ソース

- [PR #2036 review results (cycle 5, mergeable)](../../raw/reviews/20260727T084223Z-pr-2036.md)
