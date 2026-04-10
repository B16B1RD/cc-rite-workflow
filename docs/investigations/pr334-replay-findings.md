# PR #334 (bash hook) replay 実測レポート

> **位置づけ**: Issue #403 (親 Issue #392 の対照実測サブタスク) の成果物。改善後 `rite:pr:review` を bash hook PR #334 に対して適用し、**error-handling reviewer の stderr 混入検出 / silent abort 防止検出**が修正後コードに対してどのように振る舞うかを定量的に検証する。
>
> **実測セッション**: 2026-04-10
> **対象 PR**: #334 `fix(hooks): context-pressure.sh の堅牢性改善 — silent abort 防止 + コメント精度修正`
> **baseRefOid**: `4e919ace5d901606c566f6f788f1cedb8d772d07`
> **mergeCommit**: `7165aa91328f7e4556d4dfef6d38d306195d46e3`
> **replay draft PR**: #407 (`investigate/pr334-replay`, commit `39640b2`)
> **設計書**: [../designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
> **親レポート**: [review-quality-gap-results.md](./review-quality-gap-results.md)
> **手順参考**: PR #405 (PR #373 replay, [pr373-replay-findings.md](./pr373-replay-findings.md))、Issue #402 / #406 の手法

## 0. サマリー

| 指標 | 結果 | 判定 |
|------|------|------|
| 総 finding 数 (reviewer 出力 raw) | **0 件** (CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 0) | — |
| 重複除外後の unique finding 数 | 0 件 | — |
| FP rate (strict / conservative / worst case) | **N/A** (mathematically undefined: 0/0) | — |
| Phase C2 検出 (error-handling reviewer) | stderr 混入: **0 件** / silent abort 防止: **0 件** | ⚠️ **検出機会なし** (下記第 4 章参照) |
| Rollback 判定 | **不要** (finding がないため rollback 閾値判定の対象外) | ✅ |
| reviewer 活性化 | error-handling **活性 ✓** + performance + devops + security | ✅ |

**主要結論**:

1. **改善後 review system は PR #334 の修正を正しく "可" と判定**: 全 4 reviewer (error-handling / performance / devops / security) が「可」評価を返し、新規 finding は 0 件。reviewer は **修正後コードを誤って問題視しない** という意味では正しく振る舞った。
2. **error-handling reviewer は活性化したが、stderr 混入 / silent abort は 0 件検出**: これは Phase C2 (#361 で導入された stderr 混入検出強化) の効果**有無を判定する材料にはならない**。理由は次節で詳述するが、本質的には「PR #334 の diff 自体が silent abort fix の **適用後**コードである」ため、検出すべき問題が diff には残存していないからである。
3. **methodological caveat (重要)**: 本 replay 手法 (および先行 PR #373 replay) は **post-fix code を replay** している。**Phase C2 の検出能力を真に評価するには、pre-fix code を replay する必要がある** (本 Issue のスコープ外、別 Issue 化推奨)。
4. **Rollback 判定**: FP rate 計算不能 (0/0) のため Phase A/B/C/C2 のいずれも rollback 候補にはならない。明示的な反証データがないだけで「効果が確認された」を意味しない。

## 1. 実測条件

### 1.1 対象 PR

- **PR #334**: `fix(hooks): context-pressure.sh の堅牢性改善 — silent abort 防止 + コメント精度修正` (#332)
- **ファイル数**: 2 (両方とも MODIFIED)
  - `plugins/rite/hooks/context-pressure.sh` (+2 / -2)
  - `plugins/rite/templates/config/rite-config.yml` (+1 / -0)
- **変更規模**: +3 / -2 (extra small)
- **Change type**: Bug fix (silent abort prevention) + cosmetic (comment polish)
- **選定理由** (親 Issue #392 / #403 より引用): 「Bash/hook script」カテゴリの対照実測対象。hook script の堅牢性改善 (silent abort 防止 + コメント精度修正) を扱うため、error-handling reviewer の stderr 混入検出・silent abort 防止チェックが**重点的に活性化することが期待**された。

### 1.2 replay 手順

Issue #403 本文の手順に準拠。先行 PR #373 replay と同一の方法論。

```bash
# Step 1: PR #334 merge commit と baseRefOid 特定
gh pr view 334 --json mergeCommit,baseRefOid
# baseRefOid: 4e919ace5d901606c566f6f788f1cedb8d772d07

# Step 2: worktree 作成 (baseRefOid チェックアウト + 新規ブランチ)
git worktree add -b investigate/pr334-replay ../rite-investigate-pr334 4e919ace5d901606c566f6f788f1cedb8d772d07

# Step 3: PR #334 の diff を worktree に適用
cd ../rite-investigate-pr334
gh pr diff 334 | git apply --3way -

# Step 4: commit + push + draft PR 作成
git -c commit.gpgsign=false commit -m "investigate: replay PR #334 for bash hook review measurement (#403)"
git push -u origin investigate/pr334-replay
gh pr create --draft --base develop --head investigate/pr334-replay \
  --title "investigate: PR #334 replay for bash hook review measurement (#403)" \
  --body "..."
# → PR #407 (https://github.com/B16B1RD/cc-rite-workflow/pull/407)

# Step 5: rite:pr:review を draft PR に対して起動
# (Issue #403 の /rite:issue:start フロー内で `skill: "rite:pr:review", args: "407"` として nested 起動)
```

### 1.3 レビュアー構成

改善後 `rite:pr:review` の自動選定結果 (Phase 2 file pattern + content analysis + Phase 3 selection logic):

| # | Reviewer | 選定理由 | selection_type |
|---|----------|---------|----------------|
| 1 | error-handling | `**/*.sh` + `**/hooks/**/*.sh` パターン一致 + キーワード検出 (`set -e`, `pipefail`, `\|\| CWD=""`, `2>/dev/null`) | `detected` |
| 2 | performance | `**/*.sh` + `**/hooks/**` パターン一致 (hook = performance クリティカル) | — |
| 3 | devops | `*.yml` パターン一致 (config 含む) | — |
| 4 | security | `recommended_for_code_changes: true` + 実行可能コード (`.sh`) 変更 | `recommended` |

- **レビューモード**: full (previous review なし、`review.loop.verification_mode: false`)
- **Doc-Heavy PR**: false (`doc_lines_ratio=0.0`, `doc_files_count_ratio=0.0`)
- **fact-check**: 実施せず (external claim 0 件)
- **debate**: 矛盾 0 件のため未発火

### 1.4 PR #334 の diff 内容 (5 行)

#### 変更 1: `context-pressure.sh` line 10 — コメント文言修正 (cosmetic)

```diff
-# - RED: Critical warning + flow split recommendation
+# - RED: Critical warning + /compact recommendation
```

ランタイム影響ゼロ。RED 状態時の推奨アクションが「flow split」から「`/compact`」に変わっていることを反映。

#### 変更 2: `context-pressure.sh` line 24 — silent abort 防止 (functional)

```diff
-CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
+CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
```

`set -euo pipefail` 下で `jq` が non-zero exit (binary 不在 / 不正 JSON / pipefail 経由) した場合、command substitution が非ゼロを返してスクリプト全体が abort する経路があった。`|| CWD=""` で fallback して abort を防ぐ。直後の line 25 `[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0` で空文字は no-op exit に流れる。

#### 変更 3: `rite-config.yml` line 159 — コメント追加 (documentation)

```diff
+#     # All thresholds are phase-aware: impl/lint +10, review/fix +30, default ±0
```

`pressure_thresholds:` の commented-out template 例への注釈追加。phase-aware 調整ロジック (`context-pressure.sh:109-125`) を template ユーザーに可視化。ランタイム影響ゼロ。

## 2. finding 一覧 (raw)

**0 件**。

| # | Reviewer | Severity | file:line | description | TP/FP 判定 |
|---|----------|----------|-----------|-------------|-----------|
| — | — | — | — | — | — |

全 4 reviewer がいずれの severity でも finding を返さなかった。

## 3. 推奨事項 (raw, FP 判定対象外)

reviewer は finding 0 件であったが、error-handling reviewer から **PR スコープ外の周辺既存パターンに対する推奨事項** を 2 件取得した:

| # | Reviewer | 内容 | 別 Issue キーワード |
|---|----------|------|---------------------|
| R1 | error-handling | `context-pressure.sh:22` のコメント `cat failure does not abort under set -e` は厳密には `pipefail` 下で SIGPIPE を受けた場合の挙動に依存するため、line 24 と同様の根拠コメント (`jq parse failure under pipefail aborts without fallback`) をインライン化しておくと将来の読者が同種 fix の根拠を辿りやすい | ✅ (`本 PR スコープ外`) |
| R2 | error-handling | `context-pressure.sh:85` の `python3 -c '...'` ブロックは yaml load 失敗時に `THRESHOLDS=""` で default にフォールバックする挙動がユーザーに一切見えない (silent drop)。stderr への warning 1 回 (hook 実行のたびではなく session 内 1 回) を検討する余地がある | ✅ (`本 PR スコープ外`) |

> **重要**: これらの推奨事項は **元 PR #334 の周辺既存パターン** に対する観察であり、**PR #334 の diff (line 24 / 159) で導入された問題ではない**。Phase 7 自動 Issue 化はこの replay 文脈の measurement 意図と齟齬があるため意図的にスキップした (parent #392 集約フェーズで再評価予定)。
>
> **観点**: R2 は **silent drop pattern** の指摘であり、error-handling reviewer の "silent failure detection" 能力が PR スコープ内 diff だけでなく**周辺ファイルにも作用している**ことを示す副次的データ。Phase C2 機構が「変更ライン外でも silent abort 経路を発見できる」という側面では機能していると言える (ただし PR #334 の diff そのものではなく、reviewer が周辺 context を読みに行った結果)。

## 4. Phase C2 効果判定

### 4.1 期待されていた検出

Issue #403 / #392 の判定基準:

> error-handling reviewer による stderr/silent abort 検出が 0 件の場合、Phase C2 (stderr 混入検出) の効果に疑義が残る

### 4.2 実測結果

| 検出項目 | 期待 | 実測 | 判定 |
|---------|------|------|------|
| stderr 混入検出 | 0 件以上 | **0 件** | ⚠️ 検出機会なし |
| silent abort 防止検出 | 0 件以上 | **0 件** | ⚠️ 検出機会なし |
| error-handling reviewer の活性化自体 | 活性 | **活性 ✓** | ✅ |

### 4.3 「検出機会なし」と判定する根拠

**PR #334 の diff 自体が silent abort fix の "適用後" コードである**。具体的には:

- 変更 2 (`|| CWD=""`) は **silent abort を防止する fix そのもの**。Phase C2 が検出すべき pattern (`CWD=$(... | jq ...)` だけで fallback がない silent abort 経路) は、replay 後の diff には**もう存在しない**。
- 変更 1 (コメント文言) と変更 3 (template コメント) は実行コードへの影響なし → error-handling reviewer の検査対象外。

つまり PR #334 の diff には **error-handling reviewer の Phase C2 機構が検出すべき silent abort / stderr 混入パターンが残っていない**。

reviewer は実際に変更ファイル全体 (line 22, 85 等) を読みに行き、**PR スコープ外の既存 silent drop pattern** (R2 推奨事項) を発見できている。これは Phase C2 機構が**周辺コードに対しては機能している**ことを示す副次的証拠だが、PR diff そのものに対する検出能力の証拠ではない。

### 4.4 結論: Phase C2 効果には**疑義を残せない**

| 命題 | 判定 |
|------|------|
| Phase C2 は PR #334 の diff から silent abort を検出できなかった → 機構が壊れている | **No** (検出すべき対象が diff に存在しない) |
| Phase C2 は PR #334 の diff から silent abort を検出した → 機構が正しく動いている | **No** (検出すべき対象が diff に存在しないため証明不能) |
| **真の判定** | **N/A — テストケースとして不適切** |

**methodological caveat (重要)**:

本 replay 手法は「**マージ済み PR の post-fix code** を再適用する」ため、bug fix を行った PR を対象にすると **検出すべき bug は diff から消失している**。これは先行 PR #373 replay (Issue #402 / #406) でも同じ性質を持つが、PR #373 が **新規実装 (silent failure detection の対象が新たに追加された)** であったのに対し、PR #334 は **既存 bug の修正 (検出対象が消えた)** であるため、本 replay の Phase C2 検証能力は構造的に低い。

## 5. FP rate 計算

| 計算方式 | 結果 |
|---------|------|
| strict (`FP / total_findings`) | 0/0 = **undefined (N/A)** |
| conservative (`(FP + 0.5*Ambiguous) / total_findings`) | 0/0 = **undefined (N/A)** |
| worst case (`Ambiguous=全FP として計算`) | 0/0 = **undefined (N/A)** |

**Rollback 閾値 30% との比較**: 計算不能のため **rollback 候補ではない**。ただしこれは「FP rate が低いことが確認された」という意味ではなく「**評価対象が存在しなかった**」という意味であり、Phase C2 / error-handling 機構の品質に対する positive evidence にはならない。

## 6. 親 Issue #392 集約への引き継ぎ事項

1. **PR #334 replay は finding 0 件 / FP rate 計算不能**。Phase C2 機構の検出能力を**実証も反証もしない**結果。
2. **methodological caveat の集約レポート反映が必須**: post-fix replay の構造的限界 (検出対象が diff から消失) を `review-quality-gap-results.md` に明示記載すべき。
3. **Phase C2 検出能力の真の検証には pre-fix replay が必要**: PR #334 の baseRefOid (`4e919ac`) ではなく、その**親コミット** (= PR #334 適用前の context-pressure.sh) に対して reviewer を実行する手法を検討する必要がある。これは別 Issue として親 #392 集約フェーズで提案する。
4. **副次的観察 (R2 推奨事項)**: error-handling reviewer は **PR スコープ外の周辺既存 silent drop pattern** を発見した。これは Phase C2 機構が**変更 diff のみに視野を限定せず周辺コードを能動的に走査している**ことの間接的証拠。
5. **reviewer 構成は期待通り**: error-handling が file pattern + keyword の両方で activate し、`recommended_for_code_changes` 設定により security も追加された。reviewer 選定機構は仕様通り動作。

## 7. 関連リンク

- 親 Issue: [#392](https://github.com/B16B1RD/cc-rite-workflow/issues/392) (review quality gap closure 集約)
- 本 Issue: [#403](https://github.com/B16B1RD/cc-rite-workflow/issues/403) (#392 サブ — bash hook 対照実測)
- 元 PR: [#334](https://github.com/B16B1RD/cc-rite-workflow/pull/334) (`fix(hooks): context-pressure.sh の堅牢性改善`)
- replay draft PR: [#407](https://github.com/B16B1RD/cc-rite-workflow/pull/407) (`investigate: PR #334 replay for bash hook review measurement (#403)`)
- review コメント: https://github.com/B16B1RD/cc-rite-workflow/pull/407#issuecomment-4219305593
- 先行 replay レポート: [pr373-replay-findings.md](./pr373-replay-findings.md) (PR #373 / Issue #402 / PR #406)
- 親レポート: [review-quality-gap-results.md](./review-quality-gap-results.md)
