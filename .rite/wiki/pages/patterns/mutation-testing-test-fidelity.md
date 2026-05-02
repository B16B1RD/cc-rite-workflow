---
title: "Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する"
domain: "patterns"
created: "2026-04-27T23:01:24+00:00"
updated: "2026-05-02T11:07:39Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260426T235945Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T000422Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T020357Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T050216Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T051514Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T095733Z-pr-765.md"
tags: ["test", "mutation-testing", "false-positive", "dead-code", "verification", "bytes-exact-pin", "trailing-newline-strip", "self-grep-tautology", "count-threshold-mutation-evasion", "path-filter-coverage-gap"]
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

### 適用累積実績 (PR #688 cycles 3 → 4 → 5 → 31 → 42)

| cycle | 適用先 | 検出内容 |
|-------|--------|---------|
| 3 | TC-10 (null normalization) | dead code (PASS のまま) |
| 4 | fix verification | dead code 削除 + 真の動作 (jq `// $default`) verify に書き直し |
| 5 | TC-13 追加時の自己検証 | TC-13 false-positive 判明 |
| 31 | TC-AC-4-WRITER-FALLBACK | 6 sub-assertions のうち `legacy phase updated` が identification power 0 |
| 42 | TC-9 (`_resolve-cross-session-guard.test.sh`) | bash command substitution の trailing newline strip 仕様により helper が `printf '%s\n'` に regress しても test PASS する false-positive (assertion が `wc -c` ではなく `=` 比較のため byte 差分が消失) |

→ Wiki 経験則として **新規 test 追加時は mutation testing による真正性検証を strongly recommended** と位置付け。

### 適用 4: bash command substitution trailing newline strip 仕様による false-positive (PR #688 cycle 42 での evidence)

cycle 42 review で `_resolve-cross-session-guard.test.sh` TC-9 が **bash の `$(...)` command substitution が末尾 newline を strip する仕様** により helper の出力が `printf '%s'` (newline 無し) ↔ `printf '%s\n'` (newline 有り) のいずれでも assertion `[ "$got" = "$expected" ]` が PASS する false-positive 構造として実測:

```bash
# helper canonical (no trailing newline)
printf '%s' "$value"

# 想定 mutation (trailing newline regression)
printf '%s\n' "$value"

# Test (false-positive)
got=$(_resolve-cross-session-guard.sh ...)  # bash strips trailing \n
[ "$got" = "expected_value" ]  # 両 mutation で PASS
```

→ **`got=$(cmd); echo -n "$got" | wc -c` で byte count を assert** する canonical pattern に変更。bash command substitution の strip 仕様が assertion を bypass する false-positive 構造は **portable shell idiom 全般に潜在** するため、**helper 出力に newline 有無の規約がある場合は必ず byte-exact pin** を mandatory 化する。

```bash
# Canonical (bytes-exact pin)
got=$(_resolve-cross-session-guard.sh ...)
got_bytes=$(printf '%s' "$got" | wc -c | tr -d ' ')
expected_bytes=5  # "value" の byte 数
[ "$got_bytes" = "$expected_bytes" ] || fail "expected $expected_bytes bytes, got $got_bytes"
```

**Detection idiom**: helper 出力の trailing newline 規約を test で pin する場合、以下を mandatory 化:

1. **`$(...)` 経由の string compare assertion は trailing newline 規約を捕捉できない前提で書く**: `assert_eq` の前に `wc -c` で byte count を pin する 1 行を追加
2. **mutation testing で empirical 検証**: helper 実装を `printf '%s'` ↔ `printf '%s\n'` で双方 mutate し test suite を再実行 → 両 mutation で PASS したら trailing newline 規約は実質 unguarded 状態
3. **portable shell idiom レビューの check item に追加**: `$(...)` / `<<<` / `read -r` のいずれも trailing newline strip / preserve 挙動が異なる。helper 出力の byte-level 規約を test で pin する場合は `wc -c` / `od -c` 等 byte-level 検査の併用を canonical とする

### 実装手順 (canonical)

1. test 対象の実装行を `git stash` または `sed` で削除 / 改変する。
2. 当該 test を再実行する。
3. **FAIL すれば真正、PASS すれば dead code or identification power 0**。
4. 復元して fix 方針を決める (dead code なら test を実装の真の動作に書き直す、identification power 0 なら fixture old/new value を分離)。

### 検出が困難な領域

- jq の null/false 扱いのような「演算子レベルで先に置換される」semantics — 実装の Bash 行を pin するだけでは jq 内部の normalization に到達しない。
- fixture と patch value の同値設計 — test author の盲点になりやすい。
- helper 共通化後の caller-side routing — helper 単体 test は通っても caller 経由経路が pin されていない。

### 適用 5: review test の identification power 不足 — 3 種 dead code 化 pattern (PR #765 review での evidence)

PR #765 (Issue #691 = bang-backtick-check 二段ガード昇格) cycle 1 review で、新規追加された **review test 自身が mutation 耐性を持たない 3 種の dead code 化 pattern** が cross-validation で検出された。新規 lint rule / hook の test を書く際の canonical な反面教材:

#### Pattern 5-A: Self-grep tautology (TC-3)

test 自身が echo した文字列を自身で grep する循環構造。実装の検出ロジックは一切呼ばれず、test fixture の echo string が test 自身の grep 検証で必ず matched する false PASS 経路。

```bash
# 反面教材 (PR #765 TC-3)
echo "[bang-backtick] WARNING: detected pattern" >> "$tmpdir/output"
grep -q '\[bang-backtick\] WARNING' "$tmpdir/output"  # ← echo した自分自身を grep
```

**Mutation: 実装の hook script を空ファイルに置き換えても TC-3 は PASS する** → identification power 0。canonical fix は「実装が emit する canonical phrase を test fixture の prepared input には含めない」「fixture を加工 → 実装 invoke → 実装が emit した output に対して assert」の 3 段階分離。

#### Pattern 5-B: 件数判定の片側 mutation 隠蔽 (TC-4)

`grep -c >= 2` 形式の閾値判定で、同一 literal が 3 箇所に存在する場合、**1 箇所を mutate しても残り 2 箇所で PASS する** dead range pattern。

```bash
# 反面教材 (PR #765 TC-4)
match_count=$(grep -c 'BANG_BACKTICK_CHECK_INVOCATION_FAILED' file)
[ "$match_count" -ge 2 ]  # ← 3 site 中 1 site mutation でも PASS
```

**Mutation: 3 site のうち 1 site を mutate (literal を別文字列に変更) → 残り 2 site で `>= 2` を満たし PASS** → mutation 耐性 0。canonical fix は **`-eq N` 完全一致 assertion** に変更し、N を canonical site count と一致させる。grep -c の閾値判定は dead range を許容する設計欠陥として認識。

#### Pattern 5-C: Path filter coverage gap (TC-3 の glob)

scope filter glob (`agents/*/foo` `references/*/foo` 等) を test fixture に含めるが、**glob 全体を kill (例: glob 自体を空文字に置換) しても全 13 TC が PASS する** identification power 0 のケース。bash case の `*` が `/` を跨ぐ仕様により、glob 削除後も別 fallback path で matched してしまう。

**Mutation: glob 全体を `""` (空文字) に置換 → 13 TC 全 PASS** → glob filter は test 上 dead code。canonical fix は filter 適用前後の matched-file count を `path filter coverage` として独立 assertion 化し、filter ON/OFF の差分を empirical に pin する。

#### 共通教訓 — Review test の identification power empirical gate

新規 lint rule / hook を導入する PR では **必ず review test 側に mutation 耐性 empirical gate を設置**:

1. **Self-grep tautology test**: test fixture を変更せずに **実装の hook 本体を空ファイル / `exit 0` に置き換え** → 全 TC が FAIL することを確認
2. **件数判定の片側 mutation 隠蔽 test**: production の N site canonical 一覧から 1 site を mutate → 該当 TC が FAIL することを確認
3. **Path filter coverage gap test**: filter glob 全体を kill → filter 機能を要求する TC のみが FAIL することを確認

3 種の mutation を 1 つの `mutation-test.sh` script として CI に組み込み、新規 rule / hook 追加 PR の review-fix loop で必須実行する。本 pattern は [test-pin-protection-theater.md](../anti-patterns/test-pin-protection-theater.md) の sub-pattern として接続し、test 真正性の 4 軸 (dead code / identification power / self-grep tautology / count threshold mutation evasion / path filter coverage gap) を canonical 化する。

## 関連ページ

- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)

## ソース

- [PR #688 review results (cycle 3) — TC-10 false-positive 発見](raw/reviews/20260426T235945Z-pr-688.md)
- [PR #688 fix results (cycle 4) — mutation testing による解消パターン](raw/fixes/20260427T000422Z-pr-688.md)
- [PR #688 fix results (cycle 5) — TC-13 false-positive + 3 cycle 連続適用実績](raw/fixes/20260427T020357Z-pr-688.md)
- [PR #688 cycle 42 review — bash command substitution trailing newline strip 仕様による false-positive 構造](raw/reviews/20260428T050216Z-pr-688.md)
- [PR #688 cycle 42 fix — bytes-exact pin (`wc -c`) で trailing newline 規約の mutation 耐性を獲得](raw/fixes/20260428T051514Z-pr-688.md)
- [PR #765 cycle 1 review — review test の identification power 不足 3 種 (Self-grep tautology / 件数判定片側 mutation 隠蔽 / Path filter coverage gap)](raw/reviews/20260502T095733Z-pr-765.md)
