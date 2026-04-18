---
title: "Fix 修正コメント自身が canonical convention を破る self-drift"
domain: "anti-patterns"
created: "2026-04-18T12:00:00+00:00"
updated: "2026-04-18T12:00:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T114056Z-pr-578.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T114231Z-pr-578.md"
tags: ["self-drift", "canonical-convention", "grep-self-check", "review-fix-loop"]
confidence: high
---

# Fix 修正コメント自身が canonical convention を破る self-drift

## 概要

fix サイクルで追加・変更したコメントや説明文自体が、その PR が守るべき canonical convention（例: 「行番号参照禁止」原則）を破ってしまう self-drift failure mode。reviewer の推奨値を盲信した fix ほど発生しやすく、commit 前の `grep` self-check で decisive に検出できる。

## 詳細

### 発生事例 (PR #578 cycle 2)

PR #578 で F-ID 衝突（同一ファイル内で同一 F-NN ID が 2 件の独立 finding を指す silent ambiguity）を解消する fix を行った。その際に追加したコメントの中に、本プロジェクトが既に確立している「canonical convention = 行番号参照は脆いため semantic 参照を用いる」という原則に違反する `L1144` 等の literal 行番号を書き込んでしまった。cycle 2 で MEDIUM finding として浮上し、修正コメント自身が canonical を破っているという構造的欠陥が検出された。

### 失敗の構造

1. reviewer 1 が「recommend 値 = F-16」を提示（ただし既存 F-IDs との grep 検証は未実施）
2. fix 側が推奨値を盲信し、衝突がないか `grep` で全件確認しないまま採用しそうになる
3. 追加したコメント内に literal 行番号を書き込み、既に確立済みの「行番号参照禁止」原則を自ら破る
4. 同型 drift が fix コメントの複数箇所に波及し、cycle 2 で片付かず cycle 3 まで発散
5. reviewer 自身の推奨値が canonical convention を破る hallmark pattern として可視化

### Detection Heuristic

fix の commit 前に以下を必須として習慣化する:

```bash
# 1. 行番号参照の残存検出
grep -nE 'L[0-9]+' {changed_files}

# 2. F-ID / ID 採番時は必ず最大値 +1 で全件 grep
grep -oE 'F-[0-9]+' {target_file} | sort -u
# reviewer 推奨値ではなく、既存 IDs の最大値 +1 を選択

# 3. canonical convention 一覧との突合 (事前に確立した原則を列挙)
#    - 行番号参照禁止
#    - `if ! cmd; then rc=$?` 禁止
#    - `mktemp \|\| echo ""` 禁止
```

### 経験則の適用

本 anti-pattern は以下の既存経験則を束ねる **メタレベル self-drift pattern** である:

- **canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する**: fix 自身が書くコメントも canonical の一部であり、drift すると下流の実装者が「reference が正」と信じてコピペする
- **Asymmetric Fix Transcription**: 1 箇所の fix が他の対称位置に伝播されない、の self-referential 版（fix コメント自体が canonical 位置との非対称を作る）
- **Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格**: reviewer 推奨値に `grep` 検証 evidence が付いていなければ盲信しない

### 対処の canonical pattern

1. **commit 前 grep self-check**: fix で新規追加 / 変更した全行に対し、プロジェクトの確立済み convention を `grep` で走査する。最低限: 行番号参照 / `if ! cmd; then rc=$?` / `mktemp \|\| echo ""` の 3 点
2. **reviewer 推奨値の evidence gate**: reviewer 提示の具体値 (ID / 閾値 / 識別子) は、採用前に必ず既存コードベースとの衝突を `grep` で検証する。推奨値盲信は 2 段階修正（cycle 2 で再発見）の主要原因
3. **fix scope の self-review**: fix 適用後、fix 自身が canonical convention を破っていないか逐語 self-review を行う。review の gate を 2 段（reviewer による検出 + self-check）にすることで cycle 2 発散を抑止する
4. **canonical convention の list 化**: プロジェクトで確立した原則（行番号参照禁止等）は reference 文書に集約し、`grep` 検証が容易な表現（`L[0-9]+` 等）で記述する

### PR #578 での実測収束軌跡

3 cycle で収束: `1 HIGH + 1 MEDIUM → 1 MEDIUM → 0 findings`

- cycle 1: F-ID 衝突 / iteration 方式非対称 (**構造的** 欠陥)
- cycle 2: **self-drift** = 修正コメント内の literal 行番号（canonical 違反の連鎖 defect）
- cycle 3: convergence

cycle 2 は cycle 1 fix 中に発生した self-drift であり、commit 前 grep self-check があれば cycle 2 自体が不要だった。self-check の省略コストは「1 review-fix cycle 分の時間 + reviewer 集中力」に相当する。

## 関連ページ

- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)

## ソース

- [PR #578 cycle 2 review (self-drift detection)](../../raw/reviews/20260418T114056Z-pr-578.md)
- [PR #578 cycle 2 fix (2 段階修正)](../../raw/fixes/20260418T114231Z-pr-578.md)
