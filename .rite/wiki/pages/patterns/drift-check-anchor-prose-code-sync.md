---
title: "AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する"
domain: "patterns"
created: "2026-04-17T00:49:00+00:00"
updated: "2026-04-17T00:49:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260417T002317Z-pr-553.md"
  - type: "reviews"
    ref: "raw/reviews/20260417T003119Z-pr-553-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260417T003737Z-pr-553-cycle-3.md"
tags: ["drift-detection", "lint", "pre-commit", "convergence", "mechanical-validation"]
confidence: high
---

# AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する

## 概要

doc に書かれた AC anchor / reasons table / Eval-order enumeration と、bash 実装の emit 順は 3 者対等な契約であり、いずれかのドリフトを検出する pre-commit lint (`distributed-fix-drift-check.sh` Pattern-2 / Pattern-5) で機械的に整合性を保証する。レビュアーの目視確認だけではカテゴリ追加・順序変更・名前変更で高頻度で drift が発生し、review fatigue の温床になる。

## 詳細

### 背景 — 3 重契約の発生箇所

`fix.md` / `cleanup.md` のような multi-reason failure 経路では、prose 側と実装側に以下 3 者の重複情報が同居する:

1. **AC anchor**: acceptance criteria を表記した `<!-- AC-7 -->` 等の anchor と prose テーブル
2. **Failure reasons table**: `| reason | Description |` の markdown テーブル（ユーザー向け）
3. **Eval-order enumeration**: コード emit 順を prose に書き起こしたコメント（`Phase 2.5 emit sequence = (invalid_pr_number / mktemp_failure_rm_err / rm_failure / ...)`）
4. **bash 実装の実際の emit 順**: `echo "[CONTEXT] ... reason=X"` が実行される実コード順序

このうち 1-3 は prose 側のリテラル重複、4 はコード実装。drift の起点は任意の 1 点でしか発生しないが、他 3 点への伝播が遅れると整合性が崩れる。

### Drift の種別

| Drift 種別 | 発生例 |
|-----------|--------|
| reason 追加時の片側反映漏れ | bash に `reason=cycle_state_file_rm_failure` を追加したが reasons table と Eval-order が更新されない |
| 順序変更の非対称 | bash で早期 guard を前方に移動したが Eval-order のコメントが旧順序のまま |
| reason 名の rename | bash の reason 名を `legacy_rm_failure` → `legacy_cycle_state_file_rm_failure` に変えたが prose が追従しない |
| AC anchor と bash カテゴリの齟齬 | AC-7 が 5 カテゴリ記述なのに bash が 4 カテゴリ mktemp ブロック実装 (review-results 通常と corrupt が同一 rm 呼び出しで合流するケース) |

### Pre-commit lint による機械検証

`plugins/rite/hooks/scripts/distributed-fix-drift-check.sh` が担う検証:

- **Pattern-2**: 「reasons table に書かれた reason 名」⇔「bash コード内の `reason=X` 文字列」の存在 1:1 一致 check
- **Pattern-5**: 「Eval-order enumeration の順序」⇔「bash コード内の echo emit 順」の順序一致 check

PR #553 で 9 経路 (7 reasons + 2 fallbacks: `invalid_pr_number` / `mktemp_failure_rm_err` / `rm_failure` / `mktemp_failure_rm_err_state_file` / `state_file_rm_failure` / `mktemp_failure_rm_err_cycle_state` / `cycle_state_file_rm_failure` + legacy 2) すべてで一致を実証。`legacy_cycle_state_file_rm_failure` と `mktemp_failure_rm_err_legacy_cycle` の 2 reason 追加時に drift check で表・コメント・コード emit 順の齟齬が自動検出される設計により、LLM 生成でも検証コストが scalar (レビュアー負荷に依存しない)。

### カテゴリ非対称の特別ケース — 表記単位とコード単位のずれ

PR #553 cycle 3 の project wisdom: `5 カテゴリ artifacts → 4 mktemp ブロック`の非対称マッピング (review result 通常と corrupt が同一 rm 呼び出しで合流) は、prose のカテゴリ列挙数とコードブロック数が 1:1 にならないケース。このような意図的な非対称は以下で明記する:

1. AC anchor に「N カテゴリの PR-specific local artifacts」と category 単位で記述
2. bash 実装側コメントで「M-1 と M-2 は同一 rm 呼び出しで処理」と合流を明示
3. drift check の Pattern-2 (reasons) は reason 単位で照合するため合流に影響されない

### 教訓 — 目視レビューの限界

3 重契約は `reason | description` 表と `# eval-order enumeration = (...)` コメントでリテラル重複するため、**マージ可** の軽量レビューでも drift を見落としやすい。機械検証 (pre-commit / CI) がないと、収束サイクル数が予期せず膨張する。distributed-fix-drift-check.sh のような専用 lint は `rite-config.yml` の `review.loop.pre_commit_drift_check: true` でデフォルト有効化しておき、fix 生成直後に必ず発火させるのが canonical。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Phase 番号は構造的対称性を保つ（孤立 sub-phase を生まない）](../heuristics/phase-number-structural-symmetry.md)

## ソース

- [PR #553 cycle 1 review (mktemp drift + Pattern-2/5 実証)](raw/reviews/20260417T002317Z-pr-553.md)
- [PR #553 cycle 2 review (pre-existing drift 昇格)](raw/reviews/20260417T003119Z-pr-553-cycle-2.md)
- [PR #553 cycle 3 review (AC anchor 5 categories ↔ 4 mktemp blocks)](raw/reviews/20260417T003737Z-pr-553-cycle-3.md)
