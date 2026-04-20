---
title: "HINT-specific 文言 pin で case arm 削除 regression を検知する"
domain: "patterns"
created: "2026-04-20T13:20:00+00:00"
updated: "2026-04-20T13:20:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260420T104328Z-pr-623.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T105116Z-pr-623.md"
tags: [testing, regression-detection, bash, hook-assertion]
confidence: high
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

複数 test fixture が同じ HINT 文言を pin することで、片方が regression してももう片方が catch する相補関係を形成できる。PR #623 では新規 `stop-guard-cleanup.test.sh` と sibling `stop-guard.test.sh` TC-608-A〜H が同一 HINT phrase (`Phase 1.0 (Activate Flow State)` / `Phase 4.W.2 phase recorded` / `rite:wiki:ingest returned` / `Phase 5 Completion Report has NOT been output`) を互いに pin し、fixture header で relationship を明示している。

### sentinel emission との直交性

HINT phrase pin だけでなく、`[CONTEXT] WORKFLOW_INCIDENT=1; type=manual_fallback_adopted` のような workflow_incident sentinel の stderr emit を同時に pin することで:

- HINT phrase regression → HINT phrase assertion が catch
- sentinel emission 経路 regression (例: `WORKFLOW_HINT` 条件削除) → sentinel assertion が catch

の 2 直交軸で silent failure 経路を封鎖する。PR #623 cycle 3 fix で cleanup test fixture に両方を追加し 17 assertions を達成。

## 関連ページ

- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)

## ソース

- [PR #623 review results (cycle 1)](raw/reviews/20260420T104328Z-pr-623.md)
- [PR #623 fix results (cycle 1)](raw/fixes/20260420T105116Z-pr-623.md)
