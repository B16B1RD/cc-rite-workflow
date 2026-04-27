---
title: "Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する"
domain: "patterns"
created: "2026-04-27T23:01:24+00:00"
updated: "2026-04-27T23:01:24+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260426T235945Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T000422Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T020357Z-pr-688.md"
tags: ["test", "mutation-testing", "false-positive", "dead-code", "verification"]
confidence: high
---

# Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する

## 概要

test が **「正しい input で PASS する」だけでは不十分**で、**「実装を mutate (sed で改変 / 削除) すると確実に FAIL する」** ことを empirical に確認することで初めて regression detection power が保証される。Mutation testing は (a) test が dead code (実用上到達しない code path) を validate していないか、(b) test の assert が identification power をもつか (fixture old value と patch new value が同値で revert test 不能になっていないか) の 2 観点を decisively 検出する。test author は同値設計に気付きにくいため、reviewer 側で mutation testing による真正性検証を strongly recommended と位置付ける。

## 詳細

### 適用 1: dead code を validate する false-positive TC の検出

cycle 3 で新規追加した TC-10 (JSON null normalization) を test reviewer が mutation testing で検証:

```bash
# Original implementation (state-read.sh:135-137)
if [ "$value" = "null" ]; then
  value="$default"
fi

# Mutation: 上記 3 行を削除
# 期待: TC-10 が FAIL する
# 実測: TC-10 が PASS する → dead code
```

→ jq の `// $default` 演算子が null を `$default` で先に置換するため、Bash 側 normalization は実用上到達しない dead code。

### Fix 方針

「dead code を test で pin」ではなく「実装の真の動作を test で pin」に書き直す:

```bash
# Before: TC-10 は normalization 自体を検証 (dead code を mock 経由で起動)
# After: TC-10 は jq の `// $default` 演算子が null/false に対して default を返すことを検証
```

simpler + mutation 耐性のある test に変換できる。

### 適用 2: identification power 0 の dead assertion 検出

cycle 31 で TC-AC-4-WRITER-FALLBACK の 6 sub-assertions を mutation testing:

```bash
# Fixture
echo '{"phase":"foo"}' > legacy_state.json

# Patch
flow-state-update.sh patch --phase "foo" --if-exists

# Assertion (dead — fixture old value と patch new value が同値)
assert_eq "$(jq -r .phase legacy_state.json)" "foo"
```

→ 「legacy phase updated」assertion は fixture phase と patch phase が同値で **identification power がゼロ**。empirical revert test (pre-fix base に対し新 TC 実行) で機械的に検出可能だが、test author が同値設計に気付きにくい failure mode。

### Fix 方針

fixture old value と patch new value を **意識的に分離** する:

```bash
echo '{"phase":"old_value"}' > legacy_state.json
flow-state-update.sh patch --phase "new_value" --if-exists
assert_eq "$(jq -r .phase legacy_state.json)" "new_value"
```

これで「patch が legacy file を update した」という invariant が真に検証される。

### 適用 3: load-bearing test の verification

cycle 2 で error-handling reviewer が pre-fix code を `/tmp/state-read-revert-test` に再現して silent exit 1 / empty stdout を確認、test reviewer が TC-8 を pre-fix で revert すると 11/12 PASS + TC-8.1 FAIL → post-fix 12/12 PASS の **2 段階を実機で検証**。

これは「fix が真に bug を防いでいることを実証する load-bearing test」の canonical pattern。

### 適用累積実績 (PR #688 cycles 3 → 4 → 5 → 31)

| cycle | 適用先 | 検出内容 |
|-------|--------|---------|
| 3 | TC-10 (null normalization) | dead code (PASS のまま) |
| 4 | fix verification | dead code 削除 + 真の動作 (jq `// $default`) verify に書き直し |
| 5 | TC-13 追加時の自己検証 | TC-13 false-positive 判明 |
| 31 | TC-AC-4-WRITER-FALLBACK | 6 sub-assertions のうち `legacy phase updated` が identification power 0 |

→ Wiki 経験則として **新規 test 追加時は mutation testing による真正性検証を strongly recommended** と位置付け。

### 実装手順 (canonical)

1. test 対象の実装行を `git stash` または `sed` で削除 / 改変する。
2. 当該 test を再実行する。
3. **FAIL すれば真正、PASS すれば dead code or identification power 0**。
4. 復元して fix 方針を決める (dead code なら test を実装の真の動作に書き直す、identification power 0 なら fixture old/new value を分離)。

### 検出が困難な領域

- jq の null/false 扱いのような「演算子レベルで先に置換される」semantics — 実装の Bash 行を pin するだけでは jq 内部の normalization に到達しない。
- fixture と patch value の同値設計 — test author の盲点になりやすい。
- helper 共通化後の caller-side routing — helper 単体 test は通っても caller 経由経路が pin されていない。

## 関連ページ

- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)

## ソース

- [PR #688 review results (cycle 3) — TC-10 false-positive 発見](raw/reviews/20260426T235945Z-pr-688.md)
- [PR #688 fix results (cycle 4) — mutation testing による解消パターン](raw/fixes/20260427T000422Z-pr-688.md)
- [PR #688 fix results (cycle 5) — TC-13 false-positive + 3 cycle 連続適用実績](raw/fixes/20260427T020357Z-pr-688.md)
