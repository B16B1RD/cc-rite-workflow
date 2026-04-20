---
title: "re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)"
domain: "heuristics"
created: "2026-04-19T03:30:00+00:00"
updated: "2026-04-20T04:35:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260419T032801Z-pr-586.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T032159Z-pr-586.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T043312Z-pr-617-cycle2.md"
tags: []
confidence: high
---

# re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)

## 概要

re-review / verification mode (前回 review comment の検証モード) では、reviewer の scope が「前回指摘の解消確認」に偏り、初回レビューで verify すべきだった latent design issue を見落とす経路がある。PR #586 cycle 4 で初検出された dogfooding bias (anchor 配布経路) と canonical drift (既存 regulation 違反) は cycle 1-3 の re-review で全て見逃されていた。**re-review でも初回レビューと同等の網羅性を確保** するのが Anti-Degradation Guardrail 原則。

## 詳細

### 発生事例 (PR #586 cycle 4)

PR #586 で以下の 2 つの design issue が cycle 1-3 で見落とされ、cycle 4 で初検出された:

1. **自 repo 固有 anchor の consumer distribution 経路漏れ**: Edit ツール `old_string` に hardcode された `# <<< gitignore-wiki-section-end` が本 repo の `.gitignore` L131 のみに存在し、templates/inject hook のような配布経路が無いまま「本 repo で動くから OK」と判断されていた
2. **同一ファイル内既存 regulation 違反**: init.md 内に「`2>&1` は付けない」規約のコメントが既に L536 に存在するにもかかわらず、新規 Phase 1.3.4 で `2>&1` を採用 — 同一ファイル内 regulation 違反 + canonical script (`gitignore-health-check.sh`) との drift

両者とも設計の根幹に関わる issue だが、re-review の scope に「(a) anchor の consumer-project distribution 経路 check」「(b) 同一ファイル内の既存 project convention check」が含まれなかった。

### 失敗の構造

1. verification mode が有効化されると reviewer は「前回の N 件の指摘を中心に」re-review する
2. 自然と verify scope が狭まり、初回で見るべきだった structural / design-level の観点が抜け落ちる
3. 同じ PR で cycle を重ねるうちに「一度 review 済」という暗黙の信頼が生まれ、再検証負荷が下がる
4. cycle 後半で初検出された latent issue は「なぜ cycle 1 で見なかったのか」の反省材料になる

### Canonical pattern (Anti-Degradation Guardrail)

1. **re-review の冒頭で「初回レビューの scope」を明示的に rerun する**: 前回指摘解消の check とは別に、design-level observations (distribution 経路 / 同一ファイル内 convention / dogfooding bias) を毎サイクル走査する
2. **scope checklist を reviewer 定義に明示**: `rite/skills/reviewers/` で reviewer ごとに「initial scope」「re-review 追加 scope」を分けず、毎回同じ scope を走らせる
3. **verification mode は指摘解消の確認「も」行うのであって、scope を狭めるモードではない**: 前回指摘の verify は追加 scope、初回網羅性は base scope として維持
4. **LLM reviewer の prompt 設計で「前回指摘にのみ focus しない」ガードを入れる**: prompt テンプレで「initial-quality observations も毎回実行」を明示

### 判定基準

- cycle N で初検出された finding が「cycle 1 で検出可能だった latent issue」に該当する場合、reviewer scope の網羅性を retrospective で見直すシグナルとする
- 特に structural / design issue (API shape / distribution / 責務分界) は review cycle の early で検出されるのが健全。cycle 4+ で初検出されるケースは scope drift の warning sign

### Verification mode FIXED 判定の evidence gate (PR #617 cycle 2 で追加)

verification mode で「前回指摘 N 件が解消されたか」を判定する際、目視確認や PR description 上の self-claim だけで FIXED と認定する経路は false-positive リスクが高い。`PR #617 cycle 2` で確立された canonical evidence gate は **「実ファイルの grep 確認 + bash -n syntax 検証」** の 2 段:

1. **実ファイル grep 確認**: 前回指摘の対象 anti-pattern (例: `L[0-9]+` literal / `2>&1` 混入 / inner/outer END crossing) を fix 後 commit に対して直接 grep し、count=0 を verify する。reviewer の前回コメントに記載された file:line を信頼せず、現 HEAD でのファイル状態を再 scan する
2. **bash -n syntax 検証**: bash code block を含む変更ファイル (commands/*.md / hooks/*.sh) は `bash -n {file}` で syntax error がないことを verify する。指摘された修正が新たな syntax error を導入していないかを decisive に検証する

evidence gate を通過した時点で FIXED と判定し、verification mode のサマリーに「(grep verified) / (syntax verified)」を明示する。これにより前回指摘解消の verify が「self-claim ベース」から「machine-checkable evidence ベース」に格上げされ、verification mode の信頼性が上がる。

PR #617 cycle 2 では cycle 1 の HIGH (ANCHOR crossing) と LOW (jp/en mixed) の両方をこの 2 段 evidence gate で FIXED と判定し、0 findings + mergeable で 1 cycle 解消した。verification mode が「scope を狭めるモード」ではなく「より厳格な evidence gate を追加するモード」として正しく機能した実例。

## 関連ページ

- [自 repo 固有 anchor を Edit old_string に hardcode すると consumer project で hard fail する (dogfooding bias)](../anti-patterns/dogfooding-anchor-hardcode.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](./observed-likelihood-gate-with-evidence-anchors.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #586 initial review (dogfooding bias 検出)](../../raw/reviews/20260419T032159Z-pr-586.md)
- [PR #586 cycle 4 fix (cycle 1-3 で見落とされた latent issue の修正)](../../raw/fixes/20260419T032801Z-pr-586.md)
- [PR #617 cycle 2 verification review (grep + bash -n evidence gate canonical 確立)](../../raw/reviews/20260420T043312Z-pr-617-cycle2.md)
