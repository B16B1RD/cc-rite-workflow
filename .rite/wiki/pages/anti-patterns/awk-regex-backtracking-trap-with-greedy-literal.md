---
title: "awk negative-class + greedy + literal の組み合わせは backtracking で literal を silent miss する"
domain: "anti-patterns"
description: "awk POSIX ERE で「行頭 `#` 以外で行内に literal X」を `^[[:space:]]*[^#].*X` 形式で書くと、X が行頭から始まる行で `[^...]` が X 先頭文字を消費し literal 再発見不能の backtracking trap を作る。canonical fix は前置 not-match `!/^[[:space:]]*#/ && /X/` で除外と検出を独立 regex に分離する確立イディオム。過去のレビュー事例 cycle 1/2 で 2 連続発生 (cycle 1 fix が新たな silent miss を作った self-induced regression)、cycle 2 で error-handling-reviewer が empirical mutation test で再現確認。lookahead 非対応の POSIX ERE 環境では前置 not-match が唯一の確立解。"
promote: rite-plugin
created: "2026-05-09T03:50:00+00:00"
updated: "2026-08-08T13:37:28Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260509T031148Z-pr-911.md"
  - type: "reviews"
    ref: "raw/reviews/20260509T032936Z-pr-911-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260509T033229Z-pr-911-cycle2-fix.md"
tags: ["awk", "regex", "backtracking", "silent-miss", "shell-comment-exclusion", "negative-class", "greedy-quantifier"]
confidence: high
---

# awk negative-class + greedy + literal の組み合わせは backtracking で literal を silent miss する

## 概要

awk POSIX ERE で「行頭が `#` 以外で、行内に literal `X` を含む」を表現するつもりで `^[[:space:]]*[^#].*X` や `^[[:space:]]*[^[:space:]#].*X` と書くと、X が行頭から始まる行で `[^...]` 部分が `X` の先頭文字を消費し、続く `.*X` が literal X を再発見できず silent miss する backtracking 経路を作る。canonical fix は前置 not-match `!/^[[:space:]]*#/ && /X/` で、shell コメント開始行除外と literal 検出を独立 regex に分離する確立イディオム。

## 詳細

### 失敗パターン（2 cycle 連続発生）

bash code block 内の shell コメント (`# ... flow-state-update.sh create ...`) を false positive 検出から除外する目的で、awk で以下のパターンを試みた:

```awk
# Cycle 1: BAD pattern v1
in_block && /^[[:space:]]*[^#].*flow-state-update\.sh create/ { ... }
# → indented shell comment (`   # flow-state-update.sh create`) を false positive (leading whitespace に [^#] が match)

# Cycle 2: BAD pattern v2 (cycle 1 fix で導入)
in_block && /^[[:space:]]*[^[:space:]#].*flow-state-update\.sh create/ { ... }
# → 行頭から始まる create 行 (`flow-state-update.sh create --phase ...`) を silent miss
```

cycle 2 fix で発覚した backtracking 経路:

1. literal X = `flow-state-update.sh create` が行頭から始まる行 (indent なし) で
2. `^[[:space:]]*` は 0 文字 match
3. `[^[:space:]#]` が先頭の `f` を消費
4. `.*` が後続の `low-state-update.sh creat` を greedy match
5. 続く literal `flow-state-update\.sh create` を行内に再発見できず → match 失敗
6. assert silent miss、test の identification power 喪失

### Solution: 前置 not-match canonical idiom

bash/awk regex の確立されたイディオムは shell コメント開始行を **前置 not-match で除外** したうえで literal を別 regex で判定する形:

```awk
# GOOD: 前置 not-match で意図を直接表現
in_block && !/^[[:space:]]*#/ && /flow-state-update\.sh create/ { ... }
```

利点:

- **意図直接性**: 「shell コメント開始行のみ除外」という意図が regex の prefix に直接表現される
- **行頭出現耐性**: literal X の行頭出現有無に影響を受けない (X 検出は別 regex で行うため backtracking 干渉なし)
- **確立イディオム**: bash/awk regex で「除外 + 検出」の組み合わせの canonical 形式

### Cross-validation の威力と限界

起点事例では reviewer 構成 `test + code-quality + error-handling` を全 3 cycle で固定したが、検出能力は cycle ごとに非対称だった:

| Cycle | CRITICAL 検出 reviewer | 見逃し reviewer |
|-------|----------------------|---------------|
| Cycle 1 | test + code-quality (cross-validated) | error-handling (LGTM 誤判定) |
| Cycle 2 | error-handling (empirical mutation test で再現) | test + code-quality (見落とし) |
| Cycle 3 | (no findings) | — |

教訓:

- 同じ reviewer 構成でも cycle ごとに検出力が異なる。固定構成で安心せず、各 cycle で empirical mutation test を必須とする
- 「cycle 1 fix が正しい」という前提で cycle 2 を進めると、cycle 1 fix が新たな silent miss を作っていた経路を見逃す
- error-handling-reviewer は「awk fall-through で何が起きるか」の empirical 再現を実施しやすく、silent failure 検出に強い

### 一般化: negative-class + greedy + literal trio の backtracking risk

本パターンは awk/POSIX ERE 固有ではなく、**negative character class + greedy quantifier + literal pattern の 3 要素が揃った時に常に backtracking trap のリスクがある**。perl/python/JavaScript 等の lookahead 対応 regex flavor では `(?!#)` で negation を表現できるが、POSIX ERE には lookahead がないため前置 not-match に分割するのが唯一の確立解。lookahead が使える環境でも、意図直接性と保守性の観点から「除外 prefix + 検出 pattern」の 2 段分割が推奨される。

## 関連ページ

- [bash code block 終端は固定 +N 行 window ではなく awk state machine で動的追跡する](../patterns/awk-bash-block-termination-tracking.md)
- [Empirical reproduction over invariant reasoning](../heuristics/empirical-reproduction-over-invariant-reasoning.md)
- [Mutation testing test fidelity](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #911 review cycle 1](../../raw/reviews/20260509T031148Z-pr-911.md)
- [PR #911 review cycle 2](../../raw/reviews/20260509T032936Z-pr-911-cycle2.md)
- [PR #911 cycle 2 fix](../../raw/fixes/20260509T033229Z-pr-911-cycle2-fix.md)
