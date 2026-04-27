---
title: "「invariant は logic 上成立」を信頼せず empirical reproduction で verify する"
domain: "heuristics"
created: "2026-04-27T23:01:24+00:00"
updated: "2026-04-27T23:01:24+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260427T115727Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T120659Z-pr-688.md"
tags: ["verification", "empirical-reproduction", "invariant", "reviewer-discipline", "silent-regression"]
confidence: high
---

# 「invariant は logic 上成立」を信頼せず empirical reproduction で verify する

## 概要

review-fix loop が累積 28+ cycle に達した時点でも、「invariant は logic 上成立する」という reasoning ベースの reviewer 判断は silent regression を見逃す経路となる。AC verification scenario を **/tmp 内に reproduction 環境を構築して helper の挙動を直接観測する** empirical 検証によって初めて顕現する non-trivial silent regression が存在する。canonical 規範: invariant 系の verdict (FIXED / acceptable / scope-creep rejected) を出す前に、AC reproduction scenario を実機で再現し、helper / system が期待通りに振る舞うことを直接観測する step を必須化する。test suite に AC reproduction scenario を直接 pin することも併せて canonical。

## 詳細

### PR #688 cycle 29 で初顕現した non-trivial silent regression

cycle 28 まで「invariant は logic 上成立」と判断されていた `_resolve_session_state_path` の writer-side fallback が、cycle 29 reviewer が **/tmp 内に AC-4 reproduction scenario を構築** して helper の silent no-op を直接観測することで CRITICAL 認定された:

- **scenario**: `schema_v=2` + valid sid + per-session 不在 + legacy が別 session の遺物
- **expected (logic)**: writer fallback で legacy にフォールバック → patch 反映
- **observed (empirical)**: writer fallback 不在 → silent skip → active=false 維持

→ reader (state-read.sh) は per-session→legacy fallback を実装するが writer (flow-state-update.sh) は同 fallback を持たない非対称が、AC-4 reproduction scenario でのみ顕現する silent regression の根本原因。28 cycle 経ても reasoning だけでは不検出。

### 検出規範

reviewer は invariant claim を以下の手順で empirical 検証:

```bash
# 1. AC scenario を /tmp 内に再現
mkdir -p /tmp/ac-4-repro/.rite-flow-state.d
echo '{"sid":"foreign-uuid-from-other-session","phase":"stale"}' > /tmp/ac-4-repro/.rite-flow-state

# 2. system / helper を invoke
cd /tmp/ac-4-repro
SID=$(uuidgen) bash {plugin_root}/hooks/flow-state-update.sh patch --phase "new" --if-exists

# 3. 期待 invariant が empirical に成立するか直接観測
cat /tmp/ac-4-repro/.rite-flow-state  # phase が "new" になっているか?
```

invariant が logic 上成立すると思っても empirical 結果が異なれば silent regression。reasoning だけで verdict を出さない。

### Test 規範: AC reproduction scenario を test suite で直接 pin

PR #688 cycle 29 までの failure mode は AC-4 reproduction scenario が test suite で直接 pin されていなかったため発生。canonical fix: scenario を 6 sub-assertions の test として永続化し future regression を機械的に捕捉:

```bash
# TC-AC-4-WRITER-FALLBACK
test_writer_fallback_with_per_session_absent_and_legacy_foreign_session() {
  setup_per_session_absent
  setup_legacy_foreign_session
  bash flow-state-update.sh patch --phase "new" --if-exists
  assert_eq "$(jq -r .phase legacy_state.json)" "new"
  # ...
}
```

### `rejected(scope-creep)` 判断の empirical gate

cycle 30 で `rejected(scope-creep)` として author が承認した tradeoff (cross-session takeover) が、cycle 31 reviewer の **empirical revert test** で CRITICAL silent corruption と認定された。reject 判断は reviewer cross-validation で empirical 検証する gate を持たないと、author の主観で CRITICAL 級リスクを silent 通過させる。

→ scope-creep rejection も empirical reproduction で verify する規範 (詳細は [`scope-creep-rejection-empirical-gate.md`](scope-creep-rejection-empirical-gate.md))。

### LLM reviewer 特有の bias

LLM reviewer は invariant の logical consistency を高速に reasoning できるため、「logically sound」と判断したら verdict を出してしまう傾向。実機 reproduction を取る verification discipline は LLM reviewer の構造的 bias への対策として canonical。

### 適用対象

- AC verification: AC が claim する invariant を empirical scenario で再現する。
- Helper migration: helper 経由化後、caller の挙動を実機 invoke で確認 (sandbox eval)。
- Symmetric refactor: 「対称化」claim を strict diff で確認 + 両 side で empirical scenario を流す。
- `rejected(...)` judgment: reject 理由 (scope-creep / out-of-scope / minor) を empirical revert test で gate する。

## 関連ページ

- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](../heuristics/reviewer-scope-antidegradation.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #688 cycle 29 review results — empirical reproduction で初顕現 silent regression](raw/reviews/20260427T115727Z-pr-688.md)
- [PR #688 cycle 30 fix results — empirical reproduction-driven fix](raw/fixes/20260427T120659Z-pr-688.md)
