---
title: "`rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する"
domain: "heuristics"
created: "2026-04-27T23:01:24+00:00"
updated: "2026-04-27T23:01:24+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260427T121800Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T122511Z-pr-688.md"
tags: ["scope-creep", "review-discipline", "rejection-gate", "empirical-verification", "ac-trade-off"]
confidence: high
---

# `rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する

## 概要

review-fix loop で author が `rejected(scope-creep)` として承認した tradeoff が、後続 cycle reviewer の **empirical revert test** で CRITICAL silent corruption / data corruption と認定される事例が発生する。`rejected` action lines を commit message に書く際、reject した懸念事項自体を reviewer cross-validation で empirical 検証する gate を持たないと、author の主観判断で CRITICAL 級リスクを silent 通過させる経路となる。canonical 規範: `rejected(scope-creep)` 判断は (a) cross-validation で別 reviewer の独立判断を取り、(b) empirical revert test で「reject した場合の挙動」を直接観測してから commit に embed する。

## 詳細

### PR #688 cycle 30 → cycle 31 で実証された failure mode

cycle 30 fix で writer-side legacy fallback を実装した際、author は **cross-session takeover** (legacy.session_id != current sid で別 session metadata が silent に保持される) を `rejected(scope-creep)` として承認:

- **author 判断**: 「対称化を優先 / cross-session takeover の防御は別 Issue」
- **cycle 31 reviewer の empirical revert test**: legacy file に foreign session の sid を仕込んで writer fallback を起動 → metadata が silent に上書きされ、foreign session の作業 state が current session に混入する **CRITICAL silent corruption** を観測
- **認定**: data corruption を生む silent regression、`rejected` 判断は invalid

→ author の主観判断で「対称化を優先」した tradeoff が、実は data corruption を生む silent regression だった。

### AC trade-off shift pattern

cycle 30 fix は AC-4 silent skip (`per-session 不在 + legacy 別 session` 環境で silent no-op) を解消したが、**同じ修正で cross-session metadata 混合という新規 silent corruption を導入**。1 つの finding を fix する diff が別の finding を生む反転パターン (AC trade-off shift)。

`rejected(scope-creep)` で「別 Issue」と分離した懸念事項が、実は当該 fix で発火する直接的 regression だった。

### canonical gate: 3 段階検証

`rejected(scope-creep)` judgment を commit に embed する前に:

1. **cross-validation gate**: 別 reviewer (理想は domain reviewer: error-handling / security / test) に「reject 理由が妥当か」を独立判断させる。同意ならば次 step へ。
2. **empirical revert test gate**: reject した懸念事項を reproduce する scenario を /tmp 内に構築し、当該 fix を流して挙動を直接観測。corruption / silent failure / data loss が観測されないか確認。
3. **commit message embed**: 上記 2 gate を passed した上で `rejected(scope-creep): {reason}` を commit message に embed。

### Reviewer 規範: empirical revert test の手順

```bash
# 1. reject 対象の懸念事項を reproduce
mkdir -p /tmp/scope-creep-test
cd /tmp/scope-creep-test
echo '{"sid":"foreign-uuid","phase":"foreign-state"}' > legacy_state.json

# 2. 当該 fix を流す (current PR HEAD で)
SID=$(uuidgen) bash {plugin_root}/hooks/flow-state-update.sh patch --phase "new" --if-exists

# 3. 挙動を観測 (corruption / silent failure / data loss が発生していないか)
diff <(echo '{"sid":"foreign-uuid",...}') <(cat legacy_state.json)
# 期待: foreign-uuid を上書きしないか refuse する (sentinel emit + 異常 exit)
# 観測: foreign-uuid を current sid で上書き → CRITICAL silent corruption
```

→ empirical 観測結果が「reject した場合の挙動が許容できる」を支持しなければ、`rejected` を `accepted (must address in this PR)` に格上げ。

### Why `rejected` reasoning is fragile

- author は当該 fix を書いた本人なので「この fix は対称化のみ / 他は別 Issue」というメンタルモデルに固着しやすい (anchoring bias)。
- LLM reviewer は logical reasoning で「scope-creep だから別 Issue」を高速 confirm する傾向。
- empirical revert test は「reasoning がどれほど logically sound でも observable behavior が異なれば silent regression」という第三者的 observability を提供する。

### Wiki 経験則「Observed Likelihood Gate」との関係

`rejected(scope-creep)` 判断は本質的に Observed Likelihood Gate (evidence anchor 未提示は推奨に降格) の **逆方向** の判断: 「empirical evidence なしに reject する」ことが reject 判断を fragile にする。両 gate は対称的に「empirical evidence の有無」を検証 axis として共有する。

### 適用対象

- review-fix loop で author が `rejected(scope-creep)` / `rejected(out-of-scope)` / `rejected(minor)` をする全ケース。
- 特に「対称化」「refactor」「helper 抽出」を伴う fix で reject 判断が発生した場合は data integrity に関する empirical revert test を必須化。
- AC trade-off shift が懸念される fix (1 つの AC を解消する diff で別 AC を破壊しないか?) は empirical scenario を test suite に永続化。

## 関連ページ

- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](../heuristics/empirical-reproduction-over-invariant-reasoning.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)

## ソース

- [PR #688 cycle 31 review results — `rejected(scope-creep)` の empirical revert test で CRITICAL 認定](raw/reviews/20260427T121800Z-pr-688.md)
- [PR #688 cycle 32 fix results — cross-session takeover guard pattern + empirical 検証 gate 規範化](raw/fixes/20260427T122511Z-pr-688.md)
