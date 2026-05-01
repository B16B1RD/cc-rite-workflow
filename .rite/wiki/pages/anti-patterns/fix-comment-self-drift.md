---
title: "Fix 修正コメント自身が canonical convention を破る self-drift"
domain: "anti-patterns"
created: "2026-04-18T12:00:00+00:00"
updated: "2026-05-01T03:27:29Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T114056Z-pr-578.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T114231Z-pr-578.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T043015Z-pr-617-fix1.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T015356Z-pr-671.md"
  - type: "reviews"
    ref: "raw/reviews/20260501T012144Z-pr-756.md"
  - type: "fixes"
    ref: "raw/fixes/20260501T020145Z-pr-756.md"
tags: ["self-drift", "canonical-convention", "grep-self-check", "review-fix-loop", "lint-rule-self-meta-drift"]
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

### Prose 内行番号 literal も対象 (PR #617 で追加)

PR #617 fix で確認された通り、本 anti-pattern は **fix で追加されるあらゆる散文記述** (commit message / fix コメント / PR description / 設計メモ) 内の line 番号 literal にも適用される。fix 自身が canonical convention「行番号参照禁止」を破る self-drift を防ぐには、`grep -nE 'L[0-9]+' {changed_files}` による全件 scan を fix の必須 self-check として習慣化する。コメント / 散文 / commit message のいずれにも literal `Lxxx-yyy` / `(line N)` / `at L1234` 等が混入していないか確認する。

PR #617 で扱われたケース: 自修正 fix 中に prose 説明文で「Lxxx-yyy」記述を生成する経路を identify。fix 適用前に prose 全体を grep し、line 番号 literal が **新規追加されていないこと** を decisive に確認することで cycle 2 発散を防げる。canonical 違反の検出 grep は fix の **commit 前最終 gate** として固定化する。

### Lint rule 追加 PR の self-meta drift (PR #671 で追加)

PR #671 で、新規 lint script `hardcoded-line-number-check.sh` (P-A `(line N, M)` / P-B 散文形式 / P-C `{file}:{line}` の 3 種 hardcoded line-number reference を検出) を追加する review-fix loop の中で、**当該 PR が新規導入する lint.md 内の Asymmetry note (lint.md:978) に literal 散文形式 line-number reference が混入** し、その lint script 自身の P-B/P-C パターンによって自己検出された事例を実測した。

これは「累積対策 PR の review-fix loop で fix 自体が drift を導入する fractal pattern」(fix-induced-drift-in-cumulative-defense.md) と self-drift が交差する **self-meta drift** の典型例:

- **PR #578**: F-ID 衝突 fix の **コメント内** literal 行番号
- **PR #617**: 自修正 fix 中の **prose 散文** での line 番号 literal
- **PR #671**: 新規 **lint rule 自身** を追加する PR の prose に、その lint rule が検出する pattern 違反が混入

特に PR #671 の構造的特徴: 「rule X を強制する script を追加する PR」の prose / Asymmetry note が rule X に違反する self-referential silent regression。同 PR が lint script を test fixture (commands/**/*.md で 0 finding baseline) で検証していても、lint.md 自身の prose が baseline scan の対象に含まれていれば self-detect 可能だが、`--exclude` 等で除外されていると永続的に隠蔽される。canonical 対策:

- **lint rule 追加 PR の必須 gate**: 新規 lint rule を導入する PR の commit 前に、`bash {new-lint-script} --all` を **lint script 自身を含む commands/**/*.md** に対して実行し、self-violation を decisive 検出する
- **rule 適用範囲の明示**: 新規 lint rule の prose / Asymmetry note / 説明文に literal 行番号を書く必要がある場合、semantic name 参照 ([DRIFT-CHECK ANCHOR semantic name 参照](../patterns/drift-check-anchor-semantic-name.md)) に変換するか、その箇所を rule の `--exclude` 対象から外して self-detect 可能にする
- **review-fix loop での累積 surface**: PR #671 では 8 件の blocking findings のうち self-meta drift が main fix patterns の 1 つとして surface (cycle 2 で発見)。新規 rule 追加 PR では「rule 違反 prose の self-introduction」を review checklist の必須項目化する

### PR #578 での実測収束軌跡

3 cycle で収束: `1 HIGH + 1 MEDIUM → 1 MEDIUM → 0 findings`

- cycle 1: F-ID 衝突 / iteration 方式非対称 (**構造的** 欠陥)
- cycle 2: **self-drift** = 修正コメント内の literal 行番号（canonical 違反の連鎖 defect）
- cycle 3: convergence

cycle 2 は cycle 1 fix 中に発生した self-drift であり、commit 前 grep self-check があれば cycle 2 自体が不要だった。self-check の省略コストは「1 review-fix cycle 分の時間 + reviewer 集中力」に相当する。

### Cycle 内 fix の「全置換」claim と置換漏れ二重検出 (PR #756 で追加)

PR #756 cycle 2 で commit message が「F-NN/F-XX journal markers を semantic 説明に置換」と claim したが、test ファイル全体を網羅的に scan しなかったため一部置換漏れが発生した。test-reviewer と code-quality-reviewer が独立に同一 finding を HIGH × 2 (二重検出) で検出。これは「Comment Quality Finding Gate (no_journal_comment 原則 2)」の反復違反パターン (本 anti-pattern の `lint rule self-meta drift` sub-pattern と並ぶ canonical convention 違反系統)。

教訓:

- **「全置換」claim 時の機械的検証必須化**: cycle 内 fix で「全置換」を主張する commit message を書く前に、`git diff ${base_branch}...HEAD | grep -E '\+.*F-[0-9]+'` のような **機械的 grep 検証** を必須化する。LLM が「ファイルを scan した」自己申告に依存しない
- **二重検出 reviewer cross-validation の意味**: 独立 reviewer が同一 finding を high confidence で再検出する状況は、「fix 側で grep evidence を提示せずに claim だけで通そうとしている」ことを reviewer 側が見抜いている強い signal。`Observed Likelihood Gate` の triple cross-validation 適用対象
- **SoT lint 自動化提案**: Comment Quality Finding Gate (no_journal_comment 原則 2) の反復違反 (PR #578, #617, #671, #756) は、SoT (`comment-best-practices.md`) 側に lint script (`grep -E '\+.*F-[0-9]+'`) を CI 自動化することで構造的に防止する。本 wiki でも `hardcoded-line-number-check.sh` 同型の `journal-marker-check.sh` を提案する

PR #756 cycle 3 で 2 件、cycle 4 で 1 件 (line-number drift と複合) の self-drift が累積検出され、cycle 5 で finally 0 finding 収束。本累積パターンは「commit message が claim する変換は機械検証する」doctrine の SoT 化の必要性を実証する。

## 関連ページ

- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md)

## ソース

- [PR #578 cycle 2 review (self-drift detection)](../../raw/reviews/20260418T114056Z-pr-578.md)
- [PR #578 cycle 2 fix (2 段階修正)](../../raw/fixes/20260418T114231Z-pr-578.md)
- [PR #617 fix (prose 内行番号 literal scope 拡張)](../../raw/fixes/20260420T043015Z-pr-617-fix1.md)
- [PR #671 fix (新規 lint rule 自身の self-meta drift)](../../raw/fixes/20260426T015356Z-pr-671.md)
- [PR #756 cycle 3 review (journal marker 二重検出 HIGH × 2)](../../raw/reviews/20260501T012144Z-pr-756.md)
- [PR #756 cycle 4 fix (全置換 claim の機械検証必須化)](../../raw/fixes/20260501T020145Z-pr-756.md)
