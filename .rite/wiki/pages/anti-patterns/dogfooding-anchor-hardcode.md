---
title: "自 repo 固有 anchor を Edit old_string に hardcode すると consumer project で hard fail する (dogfooding bias)"
domain: "anti-patterns"
created: "2026-04-19T03:30:00+00:00"
updated: "2026-04-19T03:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260419T032159Z-pr-586.md"
  - type: "fixes"
    ref: "raw/fixes/20260419T032801Z-pr-586.md"
tags: []
confidence: high
---

# 自 repo 固有 anchor を Edit old_string に hardcode すると consumer project で hard fail する (dogfooding bias)

## 概要

command 指示書 (`commands/**/*.md`) が Edit ツールの `old_string` に「自プラグイン開発 repo 固有のコメント / anchor」(例: `# <<< gitignore-wiki-section-end`) を hardcode しつつ、発動条件で anchor 存在を verify しない設計は、consumer project で Edit が `old_string not found` となり hard fail する典型的な **dogfooding bias**。anchor は templates/distribution 経路・inject hook のどちらもないまま「本 repo で動くから OK」と判断されがち。

## 詳細

### 発生構造

1. プラグイン開発 repo の `.gitignore` / 設定ファイルに自 repo 専用の anchor コメントを埋め込む
2. 新規 command 指示書で「その anchor を `old_string` に埋めた Edit」を LLM に指示する
3. 発動条件 (検出フェーズ) は anchor の存在ではなく、関連キーワード (例: `.rite/wiki/` 行の有無) だけを check する
4. consumer project (anchor 不在) で Edit が走り、`old_string not found` で hard fail する

PR #586 で `.gitignore` への negation 自動注入 (`/rite:wiki:init` Phase 1.3) が `# <<< gitignore-wiki-section-end (anchor / F-09 対応)` コメントを `old_string` に hardcode していたが、このコメントは本プラグイン repo の `.gitignore` L131 のみに存在し、consumer 経路 (templates 配布 / `/rite:init` の inject) が存在しなかったため、consumer が手動で `.rite/wiki/` を `.gitignore` に追加した repo では Phase 1.3.3 Edit が実行時 hard fail する経路があった。

### 対処 pattern (cycle 4 fix)

- **発動条件側で anchor 存在 check を必ず追加**: Phase 1.3.1 の発動条件に `grep -qF '# <<< gitignore-wiki-section-end' .gitignore` を加え、anchor 不在時は `state="skip"; reason="anchor_absent"` で early skip + 手動追記案内を表示する
- **anchor 非依存の fallback 経路を用意**: anchor が無い consumer には末尾追記などの degrade path を提示する (UX-positive)

### 教訓 (canonical rule)

- command 指示書が Edit ツールの `old_string` に「自 repo 固有のコメント / anchor」を hardcode する場合、発動条件側で **anchor 存在 check を必須** とする
- 「本 repo で動くから OK」は consumer project 視点で必ず silent hard fail を生む。開発 repo = reference repo ではないため、distribution 経路 (templates / hook inject) の有無を設計段階で確認する
- dogfooding で検出しづらいため、code review 時に「この Edit は consumer project で発火するか」を explicit check する checklist を持つ

### 検出手段 (reviewer scope への追加)

- 新規 command 指示書の PR では、Edit ツール `old_string` に含まれる固有文字列を `git grep` で repo 内検索し、出現箇所が 1 ファイル (その .gitignore / config 等) に限定されていないか確認する
- templates/scripts/hooks 経由の distribution 経路があるか grep で再確認する

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)
- [散文/実装 drift を検出する detection-mutation strictness symmetry](../patterns/detection-mutation-strictness-symmetry.md)

## ソース

- [PR #586 initial review (dogfooding bias 検出)](../../raw/reviews/20260419T032159Z-pr-586.md)
- [PR #586 cycle 4 fix (anchor 存在 check 追加)](../../raw/fixes/20260419T032801Z-pr-586.md)
