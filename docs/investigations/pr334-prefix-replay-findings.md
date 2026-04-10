# PR #334 pre-fix replay 実測レポート

> **位置づけ**: Issue #416 (親 Issue #392 の後続) の成果物。**pre-fix replay 手法** (PR #334 の inverse diff を develop に適用) により、Phase C2 (#361 分散伝播漏れ検出) の **検出感度** を定量検証する。
>
> **sibling との対比 (重要)**: [pr334-replay-findings.md](./pr334-replay-findings.md) (Issue #403 / PR #407) は **post-fix replay** であり、修正後コードに対する誤検出がないかを検証した。本レポートは **pre-fix replay** であり、修正前コードに含まれるバグを reviewer が検出できるかを検証する。両者は PR #334 の同じ 2 ファイル / 5 行に対する **signed-inverse** の diff を reviewer に提示している。
>
> **実測セッション**: 2026-04-10
> **対象 PR**: #334 `fix(hooks): context-pressure.sh の堅牢性改善 — silent abort 防止 + コメント精度修正`
> **baseRefOid**: `4e919ace5d901606c566f6f788f1cedb8d772d07`
> **mergeCommit**: `7165aa91328f7e4556d4dfef6d38d306195d46e3`
> **pre-fix replay draft PR**: #417 (`investigate/pr334-prefix-replay`, commit `7491ab4`)
> **手法**: `gh pr diff 334 --patch | git apply --reverse` (develop 上で inverse 適用)
> **設計書**: Issue #416 本文
> **親レポート**: [review-quality-gap-results.md](./review-quality-gap-results.md)
> **sibling (post-fix)**: [pr334-replay-findings.md](./pr334-replay-findings.md) (Issue #403 / PR #407)

## 0. サマリー

| 指標 | 結果 | 判定 |
|------|------|------|
| 総 finding 数 (reviewer 出力 raw) | **2 件** (CRITICAL 1 / HIGH 0 / MEDIUM 1 / LOW 0) | — |
| 重複除外後の unique finding 数 | **1 件** (context-pressure.sh:24 に 2 reviewer 合意) | — |
| FP rate (strict) | **0%** (0 FP / 1 unique finding) | ✅ ≤30% |
| Phase C2 検出 (error-handling reviewer) | silent abort 経路復活: **1 件 CRITICAL で検出** | ✅ **検出成功** |
| 検出率 (strict) | **100%** (1/1 — PR #334 が修正した bugs のうち finding として検出) | ✅ ≥70% 目標達成 |
| 検出率 (broad, 推奨事項含む) | **100%** (2/2 — silent abort + コメント不整合) | ✅ |
| Rollback 判定 | **不要** (Phase C2 機構の検出感度が実証された) | ✅ |
| reviewer 活性化 | error-handling **活性 ✓** + performance + devops + security | ✅ |

**主要結論**:

1. **Phase C2 (#361) の検出感度が実証された**: error-handling reviewer は `|| CWD=""` フォールバック削除 (= silent abort 経路復活) を **CRITICAL** で検出し、`set -euo pipefail` 下での具体的な失敗経路と他 7 フックとの一貫性逸脱を根拠として報告した。
2. **post-fix replay (#403) で「検出機会なし」だった問題が解決**: post-fix replay では PR #334 の diff が「fix 適用後」のコードであるため検出対象が存在しなかった。pre-fix replay により diff に「fix 適用前のバグ」が含まれ、reviewer の検出能力を直接テストできた。
3. **devops reviewer も同一箇所を MEDIUM で検出**: error-handling だけでなく devops も `|| CWD=""` 削除の影響を指摘。Phase 2 の reviewer 選定と Phase C2 の検出機構の両方が機能している証拠。
4. **security reviewer は「改善方向」と評価**: fail-closed (jq 失敗時にスクリプト中断) はセキュリティ的にはむしろ安全であるとの見解。これは perspective の違いであり、error-handling / devops の「silent abort = hook 機能喪失」との評価と矛盾しない (availability vs security の trade-off)。

## 1. 実測条件

### 1.1 対象 PR

- **PR #334**: `fix(hooks): context-pressure.sh の堅牢性改善 — silent abort 防止 + コメント精度修正` (#332)
- **ファイル数**: 2 (両方とも MODIFIED)
  - `plugins/rite/hooks/context-pressure.sh` (+2 / -2)
  - `plugins/rite/templates/config/rite-config.yml` (+1 / -0)
- **変更規模**: +3 / -2 (extra small)
- **Change type**: Bug fix (silent abort prevention) + cosmetic (comment polish)

### 1.2 replay 手順 (pre-fix — Issue #416 spec からの逸脱あり)

Issue #416 原文は worktree を base commit でチェックアウトする手法を提案していたが、draft PR の diff がマーカーファイルのみになり reviewer が pre-fix コードを検出する機会がない問題を実測前に発見。**採用手法**:

```bash
# Step 1: develop ベースで worktree 作成
git worktree add -b investigate/pr334-prefix-replay ../rite-investigate-pr334-prefix develop

# Step 2: PR #334 の inverse diff を適用 (修正を取り消す = バグを復活させる)
cd ../rite-investigate-pr334-prefix
gh pr diff 334 --patch > /tmp/pr334.patch
git apply --reverse /tmp/pr334.patch

# Step 3: commit + push + draft PR 作成
git commit -m "investigate: pre-fix replay — revert PR #334 to reintroduce pre-fix state"
git push -u origin investigate/pr334-prefix-replay
gh pr create --draft --base develop --head investigate/pr334-prefix-replay \
  --title "investigate: pre-fix replay for PR #334 Phase C2 detection sensitivity (#416)"
# → PR #417 (https://github.com/B16B1RD/cc-rite-workflow/pull/417)

# Step 4: /rite:pr:review 417
```

**手法の本質的差異 (post-fix vs pre-fix)**:

| 手法 | diff の意味 | reviewer が見るもの |
|------|-----------|-------------------|
| post-fix (#403/PR #407) | `gh pr diff 334 \| git apply` (順方向) | 修正後コード = バグが**ない** |
| **pre-fix (#416/PR #417)** | `gh pr diff 334 --patch \| git apply --reverse` (逆方向) | 修正前コード = バグが**ある** |

### 1.3 レビュアー構成

改善後 `rite:pr:review` の自動選定結果 (PR #407 post-fix replay と同一構成):

| # | Reviewer | 選定理由 | selection_type |
|---|----------|---------|----------------|
| 1 | error-handling | `**/*.sh` + `**/hooks/**/*.sh` パターン一致 + キーワード検出 (`set -e`, `pipefail`, `2>/dev/null`) | `detected` |
| 2 | performance | `**/*.sh` + `**/hooks/**` パターン一致 (hook = performance クリティカル) | — |
| 3 | devops | `*.yml` パターン一致 (config 含む) | — |
| 4 | security | `recommended_for_code_changes: true` + 実行可能コード (`.sh`) 変更 | `recommended` |

- **レビューモード**: full (previous review なし)
- **Doc-Heavy PR**: false
- **fact-check**: 実施せず (external claim 0 件)

### 1.4 PR #417 の diff 内容 (PR #334 の inverse)

#### 変更 1: `context-pressure.sh` line 10 — コメント文言 revert (cosmetic)

```diff
-# - RED: Critical warning + /compact recommendation
+# - RED: Critical warning + flow split recommendation
```

`/compact` → `flow split` への revert。実装 (line 168-176) は `/compact` を推奨するため、コメントと実装の不整合が生じる。

#### 変更 2: `context-pressure.sh` line 24 — silent abort 経路復活 (functional, **Phase C2 検出対象**)

```diff
-CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
+CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
```

`|| CWD=""` フォールバック削除。`set -euo pipefail` 下で `jq` 非ゼロ終了時にスクリプトが即座に abort する経路が復活。

#### 変更 3: `rite-config.yml` line 159 — コメント削除 (documentation)

```diff
-#     # All thresholds are phase-aware: impl/lint +10, review/fix +30, default ±0
```

コメントアウトされた template 例の注釈削除。ランタイム影響ゼロ。

## 2. finding 一覧 (raw)

### 2.1 raw 指摘事項

| # | Reviewer | Severity | file:line | description | TP/FP 判定 |
|---|----------|----------|-----------|-------------|-----------|
| 1 | error-handling | **CRITICAL** | context-pressure.sh:24 | `\|\| CWD=""` フォールバック削除。`set -euo pipefail` 有効で `jq` 非ゼロ終了時に silent abort。他7フック全て `\|\| CWD=""` 保持、本変更のみ逸脱。PostToolUse hook silent abort でコンテキスト圧迫警告が一切発火しない。 | **TP** |
| 2 | devops | **MEDIUM** | context-pressure.sh:24 | `\|\| CWD=""` 削除。`jq` 未インストールまたは不正 JSON で `pipefail` により非ゼロ、`set -e` で異常終了。現行 `\|\| CWD=""` は次行 exit 0 と組み合わせて正常終了を保証。 | **TP** (finding 1 と同一箇所) |

### 2.2 重複除外後 (unique findings)

| # | Severity (統合後) | file:line | description | 指摘者 |
|---|-----------|-----------|-------------|--------|
| 1 | **CRITICAL** | context-pressure.sh:24 | silent abort 経路復活 (`\|\| CWD=""` 削除) | error-handling (CRITICAL), devops (MEDIUM) |

### 2.3 TP/FP 判定

| Finding # | 判定 | 根拠 |
|-----------|------|------|
| 1 | **TP (真陽性)** | PR #334 は実際にこの silent abort 経路を修正するために作成された。`|| CWD=""` の存在理由は `set -euo pipefail` 下での `jq` 失敗時 abort 防止であり、削除は意図的にバグを復活させている。他 7 フックとの一貫性逸脱も reviewer が正しく指摘。 |

## 3. 推奨事項 (raw, FP 判定対象外)

| # | Reviewer | 内容 | Phase C2 検出対象か |
|---|----------|------|---------------------|
| R1 | error-handling | 行 10 コメント `flow split recommendation` と実装 (行 168-176 `/compact` 推奨) の不整合 (confidence 65) | ❌ (コメント精度は Phase C2 の直接対象ではない) |

## 4. Phase C2 効果判定

### 4.1 期待されていた検出

Issue #416 の判定基準:

> 検出率 (strict): silent abort 経路復活を CRITICAL/HIGH で検出できたか (≥1 件)
> Phase C2 感度判定: 検出 → 合格 (≥70%) / 未検出 → rollback 候補

### 4.2 実測結果

| 検出項目 | 期待 | 実測 | 判定 |
|---------|------|------|------|
| silent abort 経路復活検出 | CRITICAL/HIGH ≥1 件 | **CRITICAL 1 件** (error-handling) | ✅ **検出成功** |
| 同一箇所の cross-reviewer 合意 | — | **2 reviewer** (error-handling + devops) | ✅ 高信頼度 |
| error-handling reviewer の活性化 | 活性 | **活性 ✓** | ✅ |
| コメント不整合の検出 | LOW 以上 | **推奨事項** (confidence 65) | △ (finding ではなく推奨) |

### 4.3 Phase C2 検出感度の定量評価

**検出率計算**:

| 方式 | 分子 | 分母 | 結果 | 判定 |
|------|------|------|------|------|
| strict (finding のみ) | 1 (silent abort CRITICAL) | 1 (PR #334 の主要 bug = silent abort) | **100%** | ✅ ≥70% 目標達成 |
| broad (推奨含む) | 2 (silent abort + コメント不整合) | 2 (silent abort + コメント不整合) | **100%** | ✅ |

**分母の定義**: PR #334 が修正した bugs = (1) silent abort 経路 (= `|| CWD=""` 削除で復活)、(2) コメント不正確 (`flow split` → `/compact`)。config コメント追加 (変更 3) は bug fix ではなくドキュメント追加のため分母に含めない。

### 4.4 post-fix replay (#403) との対比

| 指標 | post-fix (#403/PR #407) | **pre-fix (#416/PR #417)** | 差分の解釈 |
|------|------------------------|---------------------------|-----------|
| finding 数 | 0 件 | **1 件** (CRITICAL) | pre-fix で bug が diff に存在するため検出可能に |
| Phase C2 検出 | 検出機会なし | **検出成功** | post-fix の構造的限界を pre-fix が補完 |
| FP rate | undefined (0/0) | **0%** (0/1) | pre-fix でのみ FP rate 計算が可能に |
| 推奨事項 | 2 件 (周辺既存 pattern) | 1 件 (コメント不整合) | 検出対象が異なる (既存 vs diff 内) |

**構造的差異の確認**:
- post-fix diff: `|| CWD=""` が**追加された**コード → reviewer は「修正が正しい」と判定 → finding 0
- pre-fix diff: `|| CWD=""` が**削除された**コード → reviewer は「バグが導入される」と判定 → CRITICAL

これは reviewer が diff の**方向性**を正しく評価できていることの証拠。同じ 5 行のコードに対して、修正方向と regression 方向を区別できている。

### 4.5 結論: Phase C2 検出感度は **合格**

| 命題 | 判定 |
|------|------|
| Phase C2 は pre-fix code から silent abort を検出できた | **Yes — CRITICAL で検出** |
| 検出率は ≥70% 目標を達成 | **Yes — 100%** |
| Phase C2 は rollback 候補か | **No — 検出感度が実証された** |
| post-fix replay の「検出機会なし」問題は pre-fix で解決されたか | **Yes** |

**methodological note**: pre-fix replay は「reviewer が bug を検出できるか」を直接テストする手法であり、post-fix replay の「修正を誤検出しないか (FP)」とは相補的な関係にある。Phase C2 の包括的評価には**両方の手法が必要**。

## 5. FP rate 計算

| 計算方式 | 結果 |
|---------|------|
| strict (`FP / total_unique_findings`) | 0/1 = **0%** |
| conservative (`(FP + 0.5*Ambiguous) / total_unique_findings`) | 0/1 = **0%** |
| worst case (`Ambiguous=全FP として計算`) | 0/1 = **0%** |

**Rollback 閾値 30% との比較**: 0% ≤ 30% → **rollback 対象外**。

## 6. 親 Issue #392 集約への引き継ぎ事項

1. **Phase C2 (#361) の検出感度が実証された**: error-handling reviewer が pre-fix code の silent abort 経路を CRITICAL で検出。post-fix replay (#403) の「検出機会なし」問題を解決。
2. **pre-fix replay 手法の有効性が確認された**: Issue #416 spec からの逸脱 (worktree-from-base-commit → inverse diff 適用) により、reviewer が検出可能な diff を生成できた。この手法は他の bug fix PR にも適用可能。
3. **Phase C2 は rollback 候補ではない**: 検出率 100%、FP rate 0% の結果により、Phase C2 (#361) の有効性が定量的に確認された。
4. **post-fix + pre-fix の組み合わせで包括的評価が可能**: post-fix は FP (誤検出) の不在、pre-fix は TP (真陽性) の存在をそれぞれ検証。両手法を組み合わせることで F1 score 的な包括的評価が可能になった。
5. **security reviewer の perspective**: fail-closed をセキュリティ的に「改善方向」と評価した点は、availability vs security の trade-off 分析として有用。Phase C2 の error-handling 観点 (silent abort = hook 機能喪失) と矛盾しない。

## 7. 関連リンク

- 親 Issue: [#416](https://github.com/B16B1RD/cc-rite-workflow/issues/416) (pre-fix replay 手法で Phase C2 検出感度を検証)
- 集約親: [#392](https://github.com/B16B1RD/cc-rite-workflow/issues/392) (review quality gap closure 集約, closed)
- 元 PR: [#334](https://github.com/B16B1RD/cc-rite-workflow/pull/334) (`fix(hooks): context-pressure.sh の堅牢性改善`)
- pre-fix replay draft PR: [#417](https://github.com/B16B1RD/cc-rite-workflow/pull/417) (`investigate: pre-fix replay for PR #334`)
- review コメント: https://github.com/B16B1RD/cc-rite-workflow/pull/417#issuecomment-4220297563
- sibling (post-fix replay): [pr334-replay-findings.md](./pr334-replay-findings.md) (Issue #403 / PR #407)
- 親レポート: [review-quality-gap-results.md](./review-quality-gap-results.md)
- Phase C2 実装: [#361](https://github.com/B16B1RD/cc-rite-workflow/issues/361)
