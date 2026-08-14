---
title: "HINT-specific 文言 pin で case arm 削除 regression を検知する"
domain: "patterns"
description: "hook script の phase 別 case arm 内でのみ emit される HINT 文言 (`Phase 4.W.2 phase recorded` 等) を test fixture で literal pin することで、case arm 自体が削除された場合の silent regression を検知する。"
created: "2026-04-20T13:20:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260420T104328Z-pr-623.md"
  - type: "fixes"
    resource: "raw/fixes/20260420T105116Z-pr-623.md"
  - type: "fixes"
    resource: "raw/fixes/20260421T033138Z-pr-636-cycle-3.md"
  - type: "reviews"
    resource: "raw/reviews/20260601T023442Z-pr-1223.md"
  - type: "fixes"
    resource: "raw/fixes/20260601T023854Z-pr-1223.md"
  - type: "reviews"
    resource: "raw/reviews/20260601T024546Z-pr-1223.md"
tags: [testing, regression-detection, bash, hook-assertion, twin-site-contract, exit-code-path-pin]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-01T03:07:26+00:00" }
---

# HINT-specific 文言 pin で case arm 削除 regression を検知する

## 概要

hook script の phase 別 case arm 内でのみ emit される HINT 文言 (`Phase 4.W.2 phase recorded` 等) を test fixture で literal pin することで、case arm 自体が削除された場合の silent regression を検知する。fallback STOP_MSG は `Phase:` 等の共通文字列を出力するため `assert_contains "Phase:"` のみでは case arm 削除 regression が silent-pass する false positive を塞ぐ。

## 詳細

### 問題

stop-guard.sh のような phase dispatcher は、各 phase 固有の HINT 文字列を case arm 内で設定し、final fallback で共通 STOP_MSG (`Phase: $PHASE`) を emit する構造を取る。test fixture が `assert_contains "Phase:"` のみを pin していると、以下の 2 経路で同じ assert を PASS させてしまう:

1. **正常経路**: case arm 発火 → HINT 文言 emit → fallback STOP_MSG emit → `Phase:` 出現
2. **regression 経路**: case arm が削除される → fallback STOP_MSG emit のみ → 依然として `Phase:` 出現

結果、case arm 削除 regression は assertion PASS で silent 通過する。

### canonical pattern

test fixture に HINT-specific literal 文言を追加 pin する。対象 HINT 文言は対応する case arm 内にのみ存在するため、arm 削除 regression を確実に検知できる。

```bash
# fallback STOP_MSG でも emit される汎用 assertion
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"

# HINT-specific 文言 pin: case arm 削除 regression 検知用
# (cleanup_pre_ingest case arm 内にのみ存在)
assert_contains "stderr contains 'Phase 4.W.2 phase recorded'" \
  "Phase 4.W.2 phase recorded" "$STDERR_CONTENT"
```

### 相補関係による regression 検知強化

複数 test fixture が同じ HINT 文言を pin することで、片方が regression してももう片方が catch する相補関係を形成できる。cleanup fixture 事例では新規 `stop-guard-cleanup.test.sh` と sibling `stop-guard.test.sh` TC-608-A〜H が同一 HINT phrase (`Phase 1.0 (Activate Flow State)` / `Phase 4.W.2 phase recorded` / `rite:wiki:ingest returned` / `Phase 5 Completion Report has NOT been output`) を互いに pin し、fixture header で relationship を明示している。

### sentinel emission との直交性

HINT phrase pin だけでなく、`[CONTEXT] WORKFLOW_INCIDENT=1; type=manual_fallback_adopted` のような workflow_incident sentinel の stderr emit を同時に pin することで:

- HINT phrase regression → HINT phrase assertion が catch
- sentinel emission 経路 regression (例: `WORKFLOW_HINT` 条件削除) → sentinel assertion が catch

の 2 直交軸で silent failure 経路を封鎖する。同事例の cycle 3 fix で cleanup test fixture に両方を追加し 17 assertions を達成。

### Twin site contract への拡張（cycle 3 の実測）

8 件目の累積対策 PR の cycle 3 fix で twin site contract verification という拡張パターンが確立された: HINT emit 側 (stop-guard.sh) と grep 参照側 (create.md の `[CONTEXT] XXX_FAILED=1; reason=...` retained flag emit) が対応する marker (`STEP_0_PATCH_FAILED` 等) について、**片側だけ test で verify する** と silent regression を許すため、**両側を同 test で同時に check** する canonical template。

- **TC-634-E**: twin site contract の test 側 canonical template。stop-guard HINT の grep 参照 (`grep -c "STEP_0_PATCH_FAILED"` in HINT) と create.md 側の emit site (`grep -c '\[CONTEXT\] STEP_0_PATCH_FAILED=1' create.md`) の両方を assert
- **case arm 固有 HINT 文言 pin + twin site contract の併用**: case arm 削除 regression は HINT-specific literal pin で catch、retained flag emit site 削除 regression は twin site contract assert で catch、という 2 直交軸で silent failure 経路を封鎖する

### emit / consume / test の 3 点セット契約 (cumulative-defense PR で特に重要)

implicit stop regression の 8 回目対策 PR では新 marker 追加時の 3 点セット契約違反が同型再発する傾向が観測された:

1. **emit site**: bash block で `echo "[CONTEXT] ..."` する site
2. **consume site**: stop-guard.sh HINT の grep 参照 / Pre-check list の evidence 表示 / 関連 hook の検知 logic
3. **test assertion**: emit と consume の両方を verify する test fixture

3 点のいずれかを欠く marker は「dead signal」となり、次 cycle で削除推奨される（cycle 1 の F-06 = `MANDATORY_AFTER_INTERVIEW_STEP_0`、cycle 2 F-05 = `STEP_0_PATCH_FAILED` の同型再発)。詳細は [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md) の「Fix 側の予防契約」参照。

### Exit-code 経路判別への拡張（実測）

同じ構造が **同一 exit code を共有する複数経路** のテストにも当てはまる。`assert_contains "Phase:"` が複数経路で silent-pass するのと同型に、複数の path がすべて同じ exit code を返すスクリプトでは **bare な `assert <exit code>` だけでは「どの経路が発火したか」を pin できない**。exit code は fallback STOP_MSG の `Phase:` に相当する汎用シグナルで、回帰の検出はできても経路の特定はできない。

`wiki-lint-source-refs.sh` は invocation error として `exit 2` する path を 4 つ持つ。cycle 1 の test reviewer が、TC-12 が error 出力 (`errf`) を capture しているのに `assert_grep` で消費せず `exit 2` のみ assert していたため、**4 経路のうち branch_strategy 必須チェック経路を pin できていない** LOW/follow-up を検出した (回帰検出自体は成立するが経路特定力が無い)。

cycle 1 fix は、TC-10 / TC-11 と対称な `assert_grep "branch-strategy は必須"` を 1 行追加し、capture 済みの `errf` を消費して特定経路を pin した。near-zero コストで test の特定性を上げる修正。

→ **heuristic: 同一スクリプト内に同じ exit code を返す経路が複数ある場合、その経路テストは `assert <exit code>` + `assert_grep <経路固有のエラー文言>` の対称ペアで一貫させる**。bare exit-code assert は exit-code 版の「汎用シグナル false-pass」であり、HINT-specific 文言 pin と同じく **path-specific 文言を pin して初めて経路を判別できる** (本ページ冒頭の `Phase:` ↔ HINT 文言の二層構造と同型)。

cycle 2 re-review は本修正の identification power を mutation testing で実証した: 必須エラー文言を書き換えると新 assert が FAIL し、bare な `assert exit 2` は誤って PASS する (mutation による真正性検証の詳細は [[mutation-testing-test-fidelity]] を参照)。指摘ゼロで 2 cycle 収束した。

## 関連ページ

- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](mutation-testing-test-fidelity.md)

## ソース

- [PR #623 review results (cycle 1)](../../raw/reviews/20260420T104328Z-pr-623.md)
- [PR #623 fix results (cycle 1)](../../raw/fixes/20260420T105116Z-pr-623.md)
- [PR #636 cycle 3 fix (twin site contract verification + --preserve-error-count flag)](../../raw/fixes/20260421T033138Z-pr-636-cycle-3.md)
- [PR #1223 cycle 1 review — TC-12 が exit 2 のみ assert し 4 経路を区別しない LOW/follow-up](../../raw/reviews/20260601T023442Z-pr-1223.md)
- [PR #1223 fix — TC-10/TC-11 対称の assert_grep "branch-strategy は必須" を追加し特定 exit-2 経路を pin](../../raw/fixes/20260601T023854Z-pr-1223.md)
- [PR #1223 cycle 2 review — mutation testing で経路 pin の identification power を実証、0 findings / 2 cycle 収束](../../raw/reviews/20260601T024546Z-pr-1223.md)
