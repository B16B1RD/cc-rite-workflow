---
title: "SoT-reviewer 表現 drift: pos/neg 方向の差で派生記述が silent drift する"
domain: "anti-patterns"
created: "2026-04-28T18:55:00+00:00"
updated: "2026-04-28T18:55:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260428T183538Z-pr-706.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T184201Z-pr-706.md"
tags: ["sot", "reviewer-rule", "drift", "dry"]
confidence: high
---

# SoT-reviewer 表現 drift: pos/neg 方向の差で派生記述が silent drift する

## 概要

SoT (Single Source of Truth) 側で「期待値 X 以上」(pos 表現)、reviewer 側で「X 未満で finding 発行」(neg 表現) のように同一概念を相反方向で記述すると、severity table のような派生記述で pos / neg 方向のいずれかに silent drift する経路が発生する。SoT 参照型 DRY 設計の典型的な落とし穴であり、SoT 参照リンクで両表現の意味的整合を明示するのが canonical 対策。

## 詳細

### 失敗モード

PR #706 cycle 1 (HIGH F-01) で実測。`comment-best-practices.md` (SoT) の D セクションが「期待値: 公開 API の WHY 密度は内部 helper の 1.5 倍以上」と pos 表現で記述する一方、`tech-writer.md` の Detection Checklist (e) は「公開 API と内部で密度差なし (< 1.5 倍未満) で finding 発行」と neg 表現で記述。同じ 1.5x 閾値を SoT で「以上 = OK」、reviewer で「未満 = finding」と書くと、severity table のような派生記述では:

- 派生 1: `MEDIUM` 行に「公開 API の WHY 密度が内部より低い場合 (= SoT pos 表現の補集合)」と書きうる
- 派生 2: `MEDIUM` 行に「公開 API と内部で密度差なし (= reviewer neg 表現を踏襲)」と書きうる

両者は意味的には同等のはずだが、例ベースで test 計算すると **同じデータで判定が割れる** 経路が存在する (例: 公開 API 密度 = 内部 helper 密度 × 1.0 のとき派生 1 は finding、派生 2 は判定不能)。reviewer LLM が派生記述を読んで判断する際、どちらに従うべきかが曖昧で false positive / false negative の両方を生む。

### 検出手段

- `Likelihood-Evidence: new_call_site` anchor 付き finding として cross-validation 不要で blocking 検出可能 (Observed Likelihood Gate の primary source)
- 同一概念を扱う 2 箇所 (SoT / reviewer) を grep で抽出し、閾値の方向 (`>=` vs `<`) と用語 (「以上」vs「未満」) を機械照合する

### Canonical 対策

1. **SoT 参照リンク埋め込み**: reviewer 側に「閾値判定は SoT セクション D を参照 (→ `comment-best-practices.md#d-density-guideline-公開-api-vs-内部-helper`)」と書き、相反表現の同居を避ける。閾値や正規表現を 2 度書きしない。
2. **派生記述の同期**: severity table 等の派生記述で閾値を再記述する場合、SoT 側の表現をそのまま引用する (pos 表現で書かれていれば pos のまま、neg ならば neg のまま)。
3. **用語の方向統一**: reviewer rule 内で「期待値 / 違反」のいずれかを canonical 方向として固定する。pos 表現に統一するなら reviewer は「期待値が満たされていない場合 finding」、neg 表現なら「条件 X が成立する場合 finding」と全箇所統一する。

## 関連ページ

- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](../heuristics/identity-reference-documentation-unification.md)

## ソース

- [PR #706 review results (cycle 1)](../../raw/reviews/20260428T183538Z-pr-706.md)
- [PR #706 fix results (cycle 1)](../../raw/fixes/20260428T184201Z-pr-706.md)
