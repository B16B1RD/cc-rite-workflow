---
title: "Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する"
domain: "patterns"
created: "2026-04-27T23:01:24+00:00"
updated: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260725T032345Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260725T025323Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260725T033607Z-pr-2013.md"
  - type: "reviews"
    ref: "raw/reviews/20260724T070805Z-pr-2003.md"
  - type: "reviews"
    ref: "raw/reviews/20260724T074215Z-pr-2003.md"
  - type: "fixes"
    ref: "raw/fixes/20260723T021111Z-pr-1974-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T133807Z-pr-1972.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T020659Z-pr-1967.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T022920Z-pr-1967.md"
  - type: "reviews"
    ref: "raw/reviews/20260719T235117Z-pr-1921.md"
  - type: "reviews"
    ref: "raw/reviews/20260626T031814Z-pr-1663.md"
  - type: "reviews"
    ref: "raw/reviews/20260610T003030Z-pr-1337-c2.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T115303Z-pr-1321.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T085210Z-pr-1319.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T052136Z-pr-1317.md"
  - type: "reviews"
    ref: "raw/reviews/20260608T032933Z-pr-1301.md"
  - type: "reviews"
    ref: "raw/reviews/20260606T171726Z-pr-1295.md"
  - type: "reviews"
    ref: "raw/reviews/20260606T002556Z-pr-1283.md"
  - type: "reviews"
    ref: "raw/reviews/20260605T182035Z-pr-1281-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260605T181146Z-pr-1281.md"
  - type: "reviews"
    ref: "raw/reviews/20260605T091117Z-pr-1279.md"
  - type: "reviews"
    ref: "raw/reviews/20260528T155654Z-pr-1172.md"
  - type: "reviews"
    ref: "raw/reviews/20260528T154013Z-pr-1172.md"
  - type: "fixes"
    ref: "raw/fixes/20260528T155033Z-pr-1172.md"
  - type: "fixes"
    ref: "raw/fixes/20260528T143720Z-pr-1169.md"
  - type: "reviews"
    ref: "raw/reviews/20260528T141817Z-pr-1169.md"
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
  - type: "reviews"
    ref: "raw/reviews/20260509T071343Z-pr-915.md"
  - type: "reviews"
    ref: "raw/reviews/20260520T011841Z-pr-1066.md"
  - type: "fixes"
    ref: "raw/fixes/20260520T022118Z-pr-1066-cycle1.md"
  - type: "reviews"
    ref: "raw/reviews/20260528T122742Z-pr-1167.md"
  - type: "reviews"
    ref: "raw/reviews/20260601T011012Z-pr-1222.md"
  - type: "fixes"
    ref: "raw/fixes/20260601T011318Z-pr-1222.md"
  - type: "reviews"
    ref: "raw/reviews/20260602T070147Z-pr-1246.md"
  - type: "fixes"
    ref: "raw/fixes/20260602T065355Z-pr-1246.md"
  - type: "reviews"
    ref: "raw/reviews/20260604T032559Z-pr-1266.md"
  - type: "reviews"
    ref: "raw/reviews/20260604T160823Z-pr-1270.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T073719Z-pr-1736.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T075749Z-pr-1736.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T081555Z-pr-1736.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T140345Z-pr-1742.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T142317Z-pr-1742.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T144050Z-pr-1742.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T145103Z-pr-1742.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T153807Z-pr-1742.md"
  - type: "reviews"
    ref: "raw/reviews/20260703T155000Z-pr-1742.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T141120Z-pr-1742.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T143042Z-pr-1742.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T144416Z-pr-1742.md"
  - type: "fixes"
    ref: "raw/fixes/20260703T154111Z-pr-1742.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T050800Z-pr-1969.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T051500Z-pr-1969.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T054112Z-pr-1969-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T063747Z-pr-1969.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T064426Z-pr-1969.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T122232Z-pr-1970-cycle3.md"
tags: ["test", "mutation-testing", "false-positive", "dead-code", "verification", "bytes-exact-pin", "trailing-newline-strip", "self-grep-tautology", "count-threshold-mutation-evasion", "path-filter-coverage-gap", "load-bearing-whitespace-pin", "regex-alternation-per-branch-coverage", "regex-quantifier-semantic-coverage", "symmetry-claim-bidirectional-pin", "negative-assert", "non-blocking-contract-mutation"]
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

### 適用 6: Load-bearing whitespace を持つ fixture を formatter から守る pre-check (PR #915 review での evidence)

PR #915 (Issue #914 = mutation fixture M1-M6 永続化) cycle 1 review で、**M6 fixture の末尾 fence の trailing whitespace が M6 識別力の唯一の load-bearing 要素**であるという脆弱性が指摘された。fixture が `prettier` / `editorconfig` / `markdownlint` 等の formatter で silent に剥がされた場合、mutation の identification power は壊れるが test 自身は PASS する false-positive 経路に陥る。

#### 失敗の構造

mutation fixture を永続化すると、fixture file 自身が repository の formatter / linter 設定に晒される。fixture 内のある特定の whitespace / indent / 末尾文字 etc. が「mutation を検出するための唯一の identifying feature」であるとき、その feature は **fixture から 1 文字除去されただけで identification power が 0 に落ちる** が、**fixture 自身は formatter pass で更新済みなので test 上は PASS** する silent regression を引き起こす。

```bash
# M6 fixture (最終 fence の trailing whitespace が load-bearing)
```bash
echo "test"
```␣␣  ← trailing 2 spaces が M6 検出力の唯一の load-bearing 要素

# Mutation: prettier で trailing whitespace 削除
```bash
echo "test"
```  ← trailing whitespace 消失で M6 identification power = 0
```

#### Canonical 防御: pre-check で load-bearing 要素を assertion 化

meta-test の冒頭で fixture 内の load-bearing 要素を **明示的に grep で pin** し、formatter に剥がされた場合は test 自身が FAIL するよう構造化する:

```bash
# M6 fixture pre-check (cycle 2 fix で追加)
grep -qE '```[[:space:]]+$' "$M6_FIXTURE" \
  || fail "M6 fixture lost trailing whitespace on closing fence (formatter strip?)"
```

このように **fixture の load-bearing feature を test 内で明示的に grep pin** することで、formatter / linter による silent strip を防御できる。

#### 共通教訓 — load-bearing fixture feature の self-pin

新規 fixture 永続化 PR で fixture 内の **whitespace / indent / trailing character / inline character** が mutation 識別力の唯一の load-bearing 要素になっている場合、以下を mandatory 化:

1. **load-bearing feature を test 内で grep pin**: meta-test の冒頭で `grep -qE '<load_bearing_pattern>' "$FIXTURE" || fail` を実行
2. **コメントで load-bearing 性を明示**: fixture file 内に「この trailing whitespace は M6 識別力の唯一の load-bearing 要素」とコメント追記し、後続 contributor に formatter run の判断材料を残す
3. **`.editorconfig` / `.prettierignore` で fixture path を除外**: 上記 1, 2 が defense-in-depth でしかないため、formatter 適用範囲から fixture path を排除する設定を導入する

本 pattern は適用 5 の 3 種 dead code 化 pattern (Self-grep tautology / 件数判定片側 mutation 隠蔽 / Path filter coverage gap) と同じく、**fixture の真正性を mutation testing から守る canonical 防御** の系統。

### 適用 7: Regex alternation / quantifier semantic の per-branch positive coverage (PR #1066 で実証)

PR #1066 cycle 11 で 2 種の regex per-branch coverage gap が cross-validated として検出され、本 pattern を **regex alternation / quantifier semantic** 軸へ拡張する canonical 事例になった。本拡張は適用 5 の「Pattern 5-B 件数判定の片側 mutation 隠蔽」と同型構造 (per-branch coverage gap) を、対象が grep -c 閾値ではなく **regex の構造単位 (alternation の各 branch / quantifier の各 semantic)** に変えた sub-pattern。

#### Pattern 7-A: Regex alternation の片側 positive coverage 欠落

regex の alternation (`A|B|C`) は各 branch 独立に matching するため、test の positive case は **全 branch に対して個別に配置** する必要がある。1 branch のみの positive coverage は他 branch を実質 dead range にする。

```bash
# 反面教材 (PR #1066 初版 test)
regex='could not resolve.*pull\s*request\|no.*pull\s*request found'
# Positive test: `could not resolve to a PullRequest` だけ
echo "could not resolve to a PullRequest" | grep -qE "$regex"  # PASS

# Mutation: `no.*pull request found` alternative を別 literal に置換
regex='could not resolve.*pull\s*request\|DIFFERENT_LITERAL'
# Positive test 全 PASS (no.*pull request found branch の positive case が無いため)
```

→ `no.*pull request found` alternative を別 literal に置換しても全 test PASS → 実質 dead range。

#### Pattern 7-B: Regex quantifier semantic の per-case coverage

regex quantifier (`\s*` / `\s+` / `?` / `*` / `+`) は 0 / 1 / N 回マッチを semantic に表現する。test の positive case は **quantifier semantic の境界値 (0 回 / 1 回 / N 回)** ごとに配置する必要がある。1 境界値のみの coverage は他境界値で発生する quantifier 置換 regression を catch できない。

```bash
# 反面教材 (PR #1066 初版 test)
regex='could not resolve.*pull\s*request'
# Positive test: `PullRequest` (空白なし、0 回) だけ
echo "could not resolve to a PullRequest" | grep -qE "$regex"  # PASS

# Mutation: `\s*` (0 回以上) を `\s+` (1 回以上) に置換
regex='could not resolve.*pull\s+request'
# Positive test の `PullRequest` は `\s+` でマッチしないため FAIL するが、空白あり case
# (`Pull Request`) の positive coverage が欠落していると quantifier semantic の境界値テスト
# として `\s*` ↔ `\s+` の差分を decisive 検出できない (空白なし側 1 case のみで 0 回境界
# しか pin できない)
```

→ `\s*` (0+) を `\s+` (1+) に置換すると空白なし case が FAIL するが、**空白あり case の positive coverage を持たないと quantifier semantic 全体の境界値テスト** (0 回 / 1 回両方) として decisive ではない。境界値の両端を positive で pin することで quantifier mutation を both direction で catch する。

#### Canonical 対策

PR #1066 fix (cycle 1) では positive 6 + negative 6 case で alternation 各 branch と quantifier 各 semantic を網羅:

| Case | Coverage |
|------|---------|
| `Could not resolve to a PullRequest` (空白なし) | quantifier 0 回境界 |
| `Could not resolve to a Pull Request` (空白あり) | quantifier 1 回境界 |
| `GraphQL: Could not resolve to a PullRequest ... (repository.pullRequest)` | 実 gh stderr 形式 (regression 実装互換性) |
| `no pull request found` | alternation `no.*pull request found` branch positive |
| `no PullRequest found` | alternation × quantifier 0 回 cross coverage |
| 大文字小文字混在 case | `-i` flag 削除 regression 検出 |

#### 防止策

1. **regex alternation の各 alternative に positive test を独立配置**: 1 case で複数 alternative を担保する設計は mutation 耐性 0。alternation hit 数を `grep -oE | wc -l` で counter として assert すると alternative 個別の覆遺漏れも検出できる
2. **regex quantifier の各 semantic 境界に positive test を配置**: `\s*` なら 0 回 / 1 回 / N 回、`?` なら 0 回 / 1 回、`*` なら 0 回 / 1 回 / N 回、`+` なら 1 回 / N 回。境界値テストで quantifier 置換 mutation (`\s*` → `\s+` / `?` → `+` 等) を catch
3. **regex flag (`-i` / `-E` / `-P`) の存在を assert する独立 case**: flag 削除 mutation を catch するため flag 必須の test fixture (例: 大文字混在) を持つ独立 case を 1 つ以上配置
4. **negative case でも alternative 境界を確認**: alternation の各 branch がマッチしてはいけない counter case (例: `pull request` 単独で `could not resolve` 前置なしのもの) を配置し、branch 拡張 mutation (alternation 追加) を catch
5. **mutation script に regex 専用 mutator を追加**: alternation の各 branch を 1 つずつ別 literal に置換、quantifier (`\*`, `\+`, `?`, `\s*`, `\s+`) を相互に置換するスクリプトを mutation-test.sh に追加し、新規 regex test PR で必須実行

本 sub-pattern は適用 5 の 3 種 dead code 化 pattern (Self-grep tautology / 件数判定片側 mutation 隠蔽 / Path filter coverage gap) と並列し、**regex 構造 (alternation / quantifier / flag) を test 真正性 mutation で守る canonical 防御** の系統として位置付ける。

### 適用 8: 新規 lint helper の regression test が implementation を mutate しても PASS する (PR #1167 cycle 2 follow-up)

PR #1167 (Issue #1160 — `sh-cross-ref-check.sh` 新規 lint 追加) cycle 2 review で、新規ヘルパー `strip_code_fences` (コードフェンス内行を除外する awk in_fence toggle) に **identification power を持つ回帰テストが無い** ことを reviewer が mutation 観点で指摘:

```bash
# Mutation: strip_code_fences の中身を no-op (cat) に置換
strip_code_fences() { cat "$1"; }   # ← フェンス除去を無効化

# 実測: test suite 11/11 PASS のまま
#   → 既存 11 ケースの fixture にフェンス内ノイズ行が含まれず、
#     フェンス除去の有無で結果が変わらない = strip_code_fences が dead path
```

→ helper の中核機能 (フェンス除去) を完全に無効化しても test が通るため、**test は実装の正否を検出できない**。これは「新規 lint helper を追加する PR で helper 単体の mutation 耐性 test を欠く」failure mode で、適用 5 の「Self-grep tautology / path filter coverage gap」と同型 (実装を kill しても TC が FAIL しない identification power 0)。

本件は cycle 2 で **non-blocking follow-up** として surface した (Observed Likelihood Gate で hypothetical 寄りに降格、本 PR scope 外)。教訓は適用 5 の 共通教訓に集約される通り: **新規 lint rule / hook / helper を導入する PR では、その helper の中核ロジックを no-op に mutate して該当 TC が FAIL することを CI で確認する**。フェンス除去ヘルパー自体の設計は [[lint-strip-code-fence-before-extraction]] を参照。

### 適用 9: bug fix が correctness invariant を導入したら同 PR で mutation-fail test を添える + bash positional 引数誤配置の silent false-positive (PR #1169 で実証)

PR #1169 (Issue #1168 — Stop hook loop-continuation) で 2 つの mutation testing 観点が実測された。

#### 9-A: correctness invariant を導入する fix には回帰検出 test を同 PR で添える

cycle 2 の bug fix が `consume-handoff` の fail-closed ordering (delete-then-return) という correctness invariant を導入したが、その invariant を守る回帰検出ネットが無かった (test gap)。これは「**fix が新たな test gap を残す**」pattern。cycle 3 で test-reviewer が MEDIUM (scope=follow-up) で指摘し、対応として:

- 既存 TC の DAC-probe (chmod 0555 で `_atomic_write` を強制失敗) を流用し、書込失敗時の **値 withhold / handoff 残存 / rc≠0 / 診断 ERROR emit** を assert する TC-H6 を追加。
- さらに **print-then-delete への mutation で TC-H6 が実際に FAIL する**ことを確認し、false-positive test でないことを保証した。

教訓: **bug fix が correctness invariant を導入したら、同 PR 内で「その invariant を壊す mutation で FAIL する」test を必ず添える**。invariant 導入 commit と回帰検出 commit は不可分。invariant を導入したのに mutation-fail test を欠くと、後続改修で invariant が静かに巻き戻っても誰も気付かない。fail-closed ordering の本体は [[consume-operation-delete-then-return-fail-closed]] を参照。

#### 9-B: bash positional 引数誤配置は test が常に PASS する silent false-positive

cycle 2 で test-reviewer が、TC の positional 引数誤配置 (`stop_payload "$d" true` で `true` が session-id スロットに入る) を検出した。引数がずれていても test が **常に PASS する silent false positive** を生んでおり、**mutation testing でのみ検出可能**だった (正常 input では assertion が偶然成立する)。

教訓: bash positional helper を呼ぶ test は、引数順の誤配置が silent false-positive を生む。helper の中核ロジックを mutate して該当 TC が FAIL するかを確認する mutation gate に加え、**positional 引数を意図的に 1 つずらした mutation でも TC が FAIL する**ことを確認すると、引数スロット誤配置を decisive に catch できる。適用 5 の Self-grep tautology / 件数判定片側 mutation 隠蔽と同じ「test が実装の正否を検出できない」identification power 0 の系統。

### 適用 10: 「対称化」claim は positive / negative 両側を独立 assert で pin し双方向 mutation で検証する (PR #1172 で実証)

PR #1172 (Issue #1170 — `consume-handoff` の corrupt JSON 読取時 WARNING を `cmd_set` / `cmd_get` と対称化) は、適用 9 (PR #1169) と同じ `flow-state.sh` consume-handoff 領域の直接 follow-up であり、**「対称化」(symmetrization) を謳う変更の test 真正性**を新しい軸として実測した。

#### 失敗の構造 — 片側 pin は無条件 emit mutant を見逃す

「対称化」とは「**corrupt 側では WARNING が発火し、happy-path 側では発火しない**」という双方向の invariant である。ところが cycle 1 時点の test は corrupt 側の発火 (TC-H7 相当) だけを assert しており、**happy-path 側の非発火を pin していなかった**。test reviewer が mutation testing で gap を実証:

```bash
# Mutation: 関数を「無条件 WARNING emit」に改変 (corrupt 判定を外す)
# 期待: 対称性が壊れるので test が FAIL すべき
# 実測: 既存 103 assert が全 PASS → coverage gap
#   corrupt 側 assert は無条件 emit mutant でも当然 PASS し、
#   happy-path 側の非発火を見る assert が無いため mutant を catch できない
```

→ corrupt 側だけの assert は、無条件 emit mutant に対し identification power 0。これは適用 5 Pattern 5-B (件数判定の片側 mutation 隠蔽) / 適用 7 (alternation の片側 positive coverage 欠落) と同型の **「対称性主張の片側のみ pin」coverage gap** で、対象を grep -c 閾値や regex branch から **動作の対称性 (発火 / 非発火)** へ一般化したもの。

#### Fix 方針 — negative-assert で非発火側を pin し双方向 mutation で確認

cycle 1 fix で happy-path (handoff キー欠落の正常系) で corrupt-read WARNING が**非発火**であることを pin する negative-assert (TC-H4) を追加し、TC-H7 (corrupt 側発火) と対にした。さらに**双方向 mutation で両 assert の identification power を実証**:

| Mutation | 期待 | 検出する test |
|----------|------|--------------|
| 無条件 WARNING emit (corrupt 判定除去) | happy-path でも発火 → 非発火 assert が FAIL | TC-H4 (negative-assert) |
| WARNING 行削除 | corrupt 側でも非発火 → 発火 assert が FAIL | TC-H7 (positive-assert) |

両 mutation がそれぞれ別の test を FAIL させることで、対称性の両側が独立に pin されたことが保証される。

#### Canonical 対策

1. **対称化 claim は両側を独立 assert で pin する**: 「A 条件で発火 / B 条件で非発火」を謳う変更は、発火側 (positive-assert) だけでなく**非発火側 (negative-assert)** も必ず assert する。片側だけでは無条件 emit / 無条件 silent のいずれかの mutant が必ず通り抜ける。
2. **positive / negative の grep regex は同一文言で対にする**: 両 assert が同じ canonical phrase を検査することで、文言 drift による片側の取りこぼしを防ぐ (発火側は「phrase が出る」、非発火側は「phrase が出ない」を pin)。
3. **双方向 mutation で両 assert を検証する**: 「無条件 emit mutant → negative-assert が FAIL」「emit 削除 mutant → positive-assert が FAIL」の双方を実機で確認する。片方向の mutation だけでは対の片側が dead のまま残りうる。
4. **sibling script を source する hook の mutant は hooks/ ディレクトリ内に配置する**: mutation 対象を `/tmp` にコピーすると sibling script (`*.sh`) の source 解決が相対 path で壊れる。`hooks/` ツリー内に mutant を置いて実環境の source 解決を再現する (適用 9-A の「実装本体を実環境で mutate」と同じ運用要件)。

本 sub-pattern は [[asymmetric-fix-transcription]] (対称位置への fix 伝播漏れ) の **test 側双対**にあたる: 前者は「対称な実装サイトへ fix を伝播し忘れる」失敗、本適用は「対称な動作 invariant の片側を pin し忘れる」失敗。実装の対称化を謳ったら、その対称性を守る test も両側対称に置く。

### 適用 11: 閾値の off-by-one 境界は「測定対象シグナルを単独の結果決定要因」にして pin し mutation で実証する (PR #1222 で実証)

`nlines >= 25` のような閾値比較の off-by-one (`>=` ↔ `>` / 閾値 `25` ↔ `24`) は、fixture が閾値から離れた値 (本文 26 行以上) で overshoot していると、どの mutation も既存 TC を全 PASS のまますり抜ける。PR #1222 の `bash-heaviness-check` では全 long-block fixture が `filler 26` 以上で、ちょうど 24 / 25 行の境界が未カバーだったため、cycle 1 では「境界値テスト欠落」が推奨に留まっていたが、cycle 2 で reviewer が mutation testing を実施して off-by-one が捕捉されないことを実証し MEDIUM に昇格した。

canonical な解消手順:

1. **測定対象シグナルを単独の結果決定要因にする**: 評価対象 (long-block) 以外のシグナル (python-inline) を第 2 シグナルに固定し、評価対象の発火有無のみが exit code を決める構成にする。これで閾値の `>=` 境界だけが TC の合否を分ける。
2. **境界の両側を別 TC で pin する**: (a) 本文 24 行 (閾値未満) → 非検知 + ラベル非出力 / (b) 本文 25 行 (閾値ちょうど) → 検知 + `long-block(25)` のラベル付き値まで assert。後者は閾値だけでなく行カウントロジックの回帰も同時に pin する。
3. **fixture の行数が SUT のカウント定義と一致することを確認する**: fence 行を含む / 含まない、heredoc body を数える / 数えない等のカウント定義差で 1 行ずれると境界 TC が無意味になるため、`filler N` の N を実機で逆算検証する。
4. **commit 前に mutation で非 vacuous を実証する**: 隔離 worktree で `>= 25` → `>= 26` と `LINE_THRESHOLD 25 → 24` の両 mutation を適用し、それぞれ追加した境界 TC が FAIL することを確認してから commit する。

これは「detection 完全性 (off-by-one) を test で守る」適用であり、適用 7 (regex quantifier の semantic 境界) や適用 10 (対称化の双方向 pin) と同じ「片側だけ / 境界の外側だけ pin して中身が dead」失敗の数値閾値版にあたる。

### 適用 12: 非ブロッキング契約の回帰防止に「実装末尾 exit 0 削除」mutation で revert test を立証する (PR #1246 で実証)

PR #1246 (Issue #1232 — `settings-local-rite-hook-cleanup.sh` の非ブロッキング契約) cycle 1 で「CLEANED 経路 + 内側 mktemp 失敗時の exit code leak」HIGH を末尾 `exit 0` 明示で fix し、cycle 2 で 0 findings に収束した。収束を支えたのは **fix の回帰防止 test (S-7) を mutation/revert test で立証**したこと:

- 複数 reviewer が隔離 worktree で **実装末尾の `exit 0` を削除する mutation** を適用し、S-7 が `expected=0 actual=1` で FAIL することを確認 → 「test が偽陽性 (実装が壊れても pass) でない」ことを実機で否定。
- edge-case (CLEANED 経路 + 内側 no-arg mktemp 失敗) を再現する S-7 の pin 方法: PATH-shim した mktemp を **引数で分岐** (`[ $# -eq 0 ]` の no-arg call のみ exit 1、テンプレート付き呼び出しは real mktemp へ delegate) させる。S-5/S-6 の mv-shim 技法の拡張。

教訓: 非ブロッキング契約 (exit 0 always) のような「正常系では observable な差が出ない」invariant の回帰防止 test は、正常 input で PASS するだけでは identification power 0 になりやすい。**契約を壊す mutation (末尾 exit 0 削除) で該当 TC が FAIL する**ことを実機で確認して初めて回帰検出力が保証される。本族の exit-code leak 自体は [[trailing-and-shortcircuit-exit-code-leak]] を参照。

### 適用 13: reviewer 側が READ-ONLY 制約下の detached worktree mutation test で新規 self-test の behavioral 性を立証し 0 findings / 1 cycle mergeable を達成 (PR #1266 で実証)

PR #1266 (Issue #1250 — review helper 3 件の gate-behavior self-test 追加、371 行 / 87 アサーション) は、本 pattern が推奨する mutation testing を **reviewer 側が review 時点で実施する** successful application として 0 findings / cycle 1 mergeable に到達した:

- test / error-handling reviewer が**それぞれ独立に detached worktree で mutation test** を実施し、「reason 語彙改変 → 3 fail」「exit code 改変 → 2 fail」等で新規テストが no-op false-pass でないこと (behavioral 性) を実証。READ-ONLY 制約下の reviewer でも worktree-only pattern で mutation 検証経路が機能することを実測 (適用 10 の運用要件「mutant を実環境ツリー内に配置」と整合)。
- helper 3 件の reason 語彙 / exit code / `[CONTEXT]` emit をテストアサーションと **verbatim 照合する「契約照合」アプローチ**で false confidence を排除。
- `set -uo pipefail` (-e なし) + `RC=0; ... || RC=$?` の RC capture はテストハーネスの正当設計として全 reviewer が承認 (silent failure 経路なし)、quoted heredoc (`<<'EOF'`) stub は変数展開ゼロでインジェクション経路なし、単一 TMP_ROOT + EXIT trap の資源管理で leak ゼロを実測。

教訓: 新規テスト追加 PR は「テスト自身の真正性」が唯一の review 対象になるため、reviewer が mutation testing を独立再現することが最も decisive な検証手段になる。test author 側で適用 5/9/10 の mutation gate を実施済みでも、reviewer 側の独立 mutation 再現 (2 reviewer 以上) が cross-validation として 1 cycle 収束を支える。

### 適用 14: mutation 検証は latent な remediation guidance 矛盾の発見にも機能する (PR #1270 で実証)

PR #1270 (Issue #1268 — cleanup WIKICHAIN parity test への intervening set 検出 TC-6 追加) で、適用 13 の reviewer 側 worktree-only mutation pattern が連続適用され (PR #1266 → #1270 で定着)、test / error-handling reviewer が計 6 mutation で TC-6 の検出力を実証 (intervening set 注入で fail / 継続行 `--handoff` join で false positive なし / prose backtick 言及の除外) し 0 findings / 1 cycle mergeable に到達した。

本 PR の新観測は、error-handling reviewer が mutation 検証の **過程で** 「TC-6 の remediation 指示 (`--handoff` 再指定) に従うと TC-1 (単一 site 強制) が count=2 で fail する」という **latent な SoT guidance 矛盾** を発見したこと (pre-existing、本 PR scope 外、boundary 推奨事項として surface)。mutation を実際に適用して test suite を回すと、「ある TC の fix guidance に従った結果が別 TC の前提と衝突する」将来矛盾が、guidance を読むだけでは見えない形で実機顕在化する。

教訓: mutation 検証の価値は (a) test の identification power 実証に加えて、(b) **remediation 経路同士の整合性検証** (guidance に従った修正後の suite 全体の挙動確認) にも及ぶ。test author は TC ごとの fix guidance を書く際、その guidance を適用した状態で suite 全体が意図した fail/pass 分担になるかを mutation で確認すると、TC 間の guidance 矛盾を commit 前に検出できる。

### 適用 15: コメント訂正のみの fix でも mutation で test の弁別力を再確認する (PR #1279 で実証)

PR #1279 (Issue #1275 — JSON emit フォールバックの C0 neutralize) cycle 2 review で、cycle 1 の fix が **挙動変更を伴わないコメント訂正のみ** (「C1 素通しは jq と対称」claim の入力クラス別書き分け) であったにもかかわらず、test reviewer が mutation 検証 2 種で対象 TC-16 の regression 検出力を再実証した:

| Mutation | 検出する assert |
|----------|----------------|
| fix 行 (`neutralize_ctrl --c0-only` 適用) を削除 | TC-16 の 3 assert が FAIL |
| `--c0-only` → default (C0+DEL+C1 バイト単位置換) へ改変 | 日本語保持 pin (`_reason` の UTF-8 日本語が無傷であること) が FAIL |

コメント訂正 fix は diff 上「テスト対象の挙動が変わらない」ため再レビューが文言確認に縮退しがちだが、**再レビュー時点での mutation 実施は「訂正されたコメントが記述する挙動を test が実際に pin しているか」の独立検証**として機能する。特に 2 種目 (`--c0-only` → default) は「コメントが主張する設計判断 (UTF-8 日本語を壊さないために --c0-only を選んだ) を test が弁別できる」ことの実証であり、claim と pin の対応関係を機械的に確認した。前 cycle の nit (TC-16 sanity pin コメント精度) も同じ実測で「TC 全体が path 弁別を担保している」と確認され actionable な改善余地なしと再判定された (nit の自然消滅 — 形骸化 pin 疑いは [[test-pin-protection-theater]] 参照、本件は実測で否定)。

教訓: **fix の種別 (挙動変更 / コメント訂正) に関わらず、再レビューでは対象 TC への mutation で弁別力を再確認する**。コメント訂正 PR では「コメントが主張する設計判断を test が pin しているか」が mutation の検証対象になる。claim 自体の事実性検証は [[symmetry-claim-input-class-runtime-verification]] を参照。

### 適用 16: fix 側の mutation claim を reviewer が独立再実証する — 観測数差異は核心一致で合意 (PR #1281 で実証)

PR #1281 (Issue #1278 — pre-tool-bash-guard deny フォールバックのエスケープ連鎖対称化) で、mutation testing が **fix workflow と review workflow の両側で対になって機能する** 形が完成形として実測された:

- **fix 側 (commit 前の runtime 実証)**: cycle 1 で検出された vacuous assertion (静的 reason のみで fallback を発火させた TC-116) を関数抽出 + 境界行 extract で非 vacuous 化した際、隔離 worktree で核心行削除 → 2 assertion fail を確認してから commit した。「非 vacuous 化した」という claim を commit 前に mutation で実証する手順 (適用 9-A の系譜)。
- **review 側 (claim の独立再実証)**: cycle 2 の test reviewer は fix 側の mutation claim を鵜呑みにせず、独立に 4 種の mutation 実験 (各エスケープ行の個別削除 + neutralize→cat 置換) を worktree-only pattern (適用 13) で再実施し、4 段連鎖のどの 1 行を壊しても assertion が落ちることを再実証した。
- **観測数差異の取り扱い**: fix 側 claim (2 assertion fail) と reviewer 観測 (mutation 種別ごとに異なる fail 数) は一致しなかったが、「非 vacuous である」という **核心の一致** を確認して合意した。mutation 再実証の合意条件は fail 数の literal 一致ではなく「実装を壊すと test が落ちる」という identification power の確認である。

教訓: fix が mutation 検証を claim する場合、reviewer は同じ mutation をなぞるのではなく **独立に設計した mutation セット** で再実証するのが cross-validation として強い (fix 側の mutation 設計自体の盲点も検出できる)。観測数の差異は核心 (非 vacuous 性) が一致していれば合意条件を満たす。vacuous 化の根本原因と解決手法は [[static-input-chain-function-extraction-non-vacuous-test]] を参照。

### 適用 17: vacuous 教訓を設計段階から反映したテスト追加が 0 findings / 1 cycle 収束を達成 — fake binary の引数精密スコープと両方向 assert (PR #1283 で実証)

PR #1283 (Issue #1282 — deny / JSON emit フォールバックの neutralize 失敗時 placeholder 縮退経路に fail-closed テストを追加) は、直前 PR #1281 の TC-116 vacuous 教訓 (適用 16) を **設計段階から反映** したテスト追加 PR で、4 reviewer (test / error-handling / performance / security) 全員が独立 mutation 実験 (placeholder→raw reason 退行 / fake tr matcher 破壊 / BLOCKED stderr 抑止 / silent allow 化) で非 vacuous 性を実証し、**指摘 0 件 / 1 cycle mergeable** に到達した successful preventive application。有効だった 3 パターン:

1. **「placeholder 文言あり (positive) + 通常 reason なし (negative)」の両方向 assert が縮退発生の証明として機能**: placeholder 縮退経路は「placeholder が出る」だけでは通常経路の reason が混在しても PASS しうる。「pattern 名を含まない (非 vacuous)」「通常 reason を含まない」の negative 側を対にすることで、縮退が実際に発生したことを decisive に pin する (適用 10 の対称 pin 系譜)。
2. **fake binary の引数 matcher は対象モードのみに精密スコープし、他用途は real binary へ委譲する**: fake tr は `case "$1" in *000-*)` で neutralize_ctrl の `\000-` レンジ引数のみ exit 1 させ、hook 内の他の tr 用途 (`$1=-d` / `$1=\n` 等) は real tr へ委譲。`flow-state.sh` の `tr -d '[:space:]'` / `contains_ctrl` の `tr -d` への巻き添えゼロを事前調査で確認してから commit する (適用 12 の mktemp 引数分岐 shim 技法の tr 版 — PATH-shim の引数分岐は「実質失敗しない」固定引数パイプ経路を強制発火させる canonical 技法として定着)。
3. **negative assertion 単独は空出力 mutation で trivially pass するため positive assertion とのペア構成が必須**: 「X を含まない」だけの assert は出力が空になる mutation でも PASS する。「fallback 出力が存在する」「valid JSON である」等の positive assert と組むことで初めて identification power を持つ。

なお recommendation 7 件は全て design_confirmation (mktemp rc 未チェック / fake_bin trap 未登録 / sandbox cleanup を OS reaper に委ねる設計はいずれも対称転記元と同一規約で PR 由来でない) — 既存スイート規約への準拠確認が finding 化しない運用も併せて実測。

教訓: 直前 PR で実測された vacuous 教訓 (適用 16) を**次の test 追加 PR の設計段階で反映**すると、review-fix loop なしの 1 cycle 収束が達成できる。fake binary 注入で「実質失敗しない」経路を強制発火させる場合は、(a) 引数 matcher の精密スコープ、(b) 巻き添え事前調査、(c) positive/negative ペア assert の 3 点セットを設計時 checklist とする。

### 適用 18: テストのみ変更 PR の新規 assert 4 件を reviewer 側 worktree-only mutation で非 vacuous 立証 + fault-injection shim の引数精密スコープ jq 版 (PR #1295 で実証)

PR #1295 (Issue #1287 — 委譲 helper テストの網羅性 follow-up、+101/-5 でテストのみ変更・helper 本体無変更) は 0 findings / 1 cycle mergeable に到達し、本 pattern の複数系譜が並行適用された successful application:

- **新規 assert 4 件の非 vacuous 性立証**: test reviewer が worktree-only pattern (適用 13 の系譜) で absent regex broaden / cleanup 除去 / sentinel swallow の各 mutation を適用し、対応する TC がそれぞれ FAIL することを機械的に確認。
- **検査方式の置換 (count delta → path 集合差分) を双方向 mutation で上位互換と検証**: leak 注入 (正方向: 検出して FAIL) / 他プロセス削除 (逆方向: false-fail せず PASS) の双方向で検出能力を実証 (適用 10 の双方向 mutation 系譜を「検査方式の置換」検証に適用)。方式自体の詳細は [[shared-tmp-leak-check-path-set-difference]] を参照。
- **jq fault-injection shim の引数精密スコープ**: `MOCK_GH_SCENARIO=pif_normalize_fail` シナリオで jq を fault-inject する shim は **`-s` 引数完全一致 + scenario gate の二重ガード** で誤介入なしを保証 (helper 内 `jq -s` は 1 箇所のみと Grep で事前確認)。適用 12 (mktemp 引数分岐 shim) / 適用 17 (fake tr 引数精密スコープ) で確立した PATH-shim 引数分岐技法の jq 版で、(a) 引数 matcher の精密スコープ + (b) 巻き添え事前調査 checklist の連続 3 例目。

教訓: 適用 17 の fake binary 設計 checklist は jq のような構造化データ処理 binary にも同型適用でき、テストのみ変更 PR の 1 cycle 収束を再現する。boundary 推奨 (mktemp template の TMPDIR 非対応による add-direction ambiguity 残存等) を reviewer 自身が non-blocking と明示判断する運用も 1 cycle 収束に寄与した。

### 適用 19: 既存 TC を byte-identical に一般化した新 helper の teeth を双方向退行 mutation で立証 + 「既存 TC との対称性 byte 比較」を review 検証手段に併設 (PR #1301 で実証)

PR #1301 (Issue #1293 — symmetry test の保護対象に `pr/create.md` / `pr/cleanup.md` の `create-issue-with-projects.sh` caller を追加、テストのみ変更) は 0 findings / 全 4 レビュアー「可」で初回 mergeable に到達し、適用 13 / 18 の「テストのみ追加 PR を reviewer 側 worktree-only mutation で非 vacuous 立証」系譜を継続した。新 helper `assert_single_create_caller` の 3 assertion (a: canonical callsite 存在 / b: `args_json=$(jq -n` 分離 constructor / c: 全 invocation が canonical) を、test / code-quality / error-handling の 3 reviewer が worktree-isolated mutation で検証:

| Mutation | 期待 | 検出する assert |
|----------|------|----------------|
| caller を nested `"$(jq -n ...)"` 形式へ退行 | 分離 constructor 不在 → FAIL | (b)(c) |
| callsite 近傍に flag-style `--title` を再導入 | non-canonical invocation → FAIL | (c) / TC-11 |

→ 新 assertion が nested cmdsub 退行と flag-style `--title` 退行の**両方を実際に FAIL 検出**することで、teeth (非 vacuous 性) を実機実証した。

本 PR の固有観点 2 つ:

1. **既存 TC との対称性 byte 比較を review 検証手段に併設**: 新 helper は既存 TC-1 / TC-1c / TC-2 の grep パターン・arithmetic を **byte-identical に一般化**している。reviewer は mutation testing (teeth 確認) に加えて「新 helper の grep/arithmetic が既存 canonical TC と byte 一致するか」を照合することで、create.md 系と**対称な検証強度**を持つことを確認した。テスト追加 PR のレビューでは「mutation test による teeth 確認」と「既存 TC との対称性 byte 比較」が対の有効な検証手段になる ([[asymmetric-fix-transcription]] の test 側双対 — 適用 10 が「対称な動作 invariant の両側 pin」だったのに対し、本適用は「既存 canonical TC との実装対称性 byte 照合」)。
2. **mutation 過程で surface した構造的観察を pre-existing と判定し scope 外化**: canonical grep の `bash` anchor 非対称により non_canonical が負値化しうる理論経路が観察されたが、revert test で TC-2 にも存在する pre-existing と判定 → 本 PR scope 外、「anchor 非対称を TC-2 と同時に別 Issue で統一」を follow-up 候補に記録 (適用 14 の「mutation 過程での latent guidance 矛盾発見」と同じ、mutation が test 設計の隣接欠陥を可視化する系譜)。

教訓: 既存 canonical TC を一般化して新 helper を作るテスト追加 PR では、(a) 新 assertion が想定退行で FAIL する teeth 確認、(b) 新 helper の grep/arithmetic が既存 TC と byte 一致する対称性照合、の 2 軸を reviewer 検証手段として併用すると、create.md 系と同等の検証強度を保ったまま 1 cycle 収束できる。byte-identical generalization の対称性側面は [[asymmetric-fix-transcription]] を参照。

### 適用 20: regex alternation の片側 branch を pin する positive TC を reviewer 側 mutation で非 vacuous 立証 (PR #1317 で実証)

PR #1317 (Issue #1312 — `bash-heaviness-check` の standalone signal `inline-gh-create-title` に single-quote / 非 bash フェンス TC を補強、+56/-0 でテストのみ変更・検出器本体無変更) は 0 findings / 1 cycle mergeable に到達し、適用 7 (regex alternation per-branch coverage) と 適用 13/18/19 (テストのみ変更 PR を reviewer 側 worktree mutation で非 vacuous 立証) が**同一 PR で合流**した successful preventive application。

#### 検証構造 — 開始引用符 alternation の `'` branch が既存 TC で dead range だった

検出 regex `--title[[:space:]=]+["'][^$"']` の開始引用符クラス `["']` は、既存 TC-017/019/024 が**全て double-quote** だったため `'` branch の positive coverage を持たず、`["']`→`["]` の劣化 mutation が 25 TC を全 PASS のまますり抜ける状態だった (適用 7-A「alternation の片側 positive coverage 欠落」と同型、対象が gh stderr regex から検出器の opening-quote class に変わった版)。test-reviewer と error-handling-reviewer が**それぞれ独立に**隔離環境で 2 種の mutation を実機適用し、追加 TC の teeth を実証:

| Mutation | 期待 | 検出する TC |
|----------|------|------------|
| `["']` → `["]` (single-quote branch 除去) | 28 TC 中 TC-026 のみ FAIL (既存 double-quote TC-017/019/024 は全 PASS) | TC-026 (single-quote positive) |
| `[^$"']` から `$` 除外を撤去 | TC-018 (double-quote `"$var"`) + TC-027 (single-quote `'$pr_title'`) が FAIL | TC-027 (single-quote `$` sentinel) |

→ single-quote branch の追加 TC が「double-quote TC では捕捉不能な劣化」を**単独で**検出することを 2 reviewer が cross-validation で確認。

#### Asymmetric Fix Transcription 監査の test 側適用

test-reviewer は Wiki anti-pattern [[asymmetric-fix-transcription]] の「転記先が静的 reason のみで vacuous 化していないか」観点を本 PR の対称転記 TC (double-quote → single-quote への転記) に適用し、**TC-026 fixture から `--title` を除くとアサーション (rc=1 + signal) が崩れる (falsifiable = 非 vacuous)** ことを確認した。適用 16 (PR #1281) の TC-116 vacuous 教訓が、転記元/転記先の「注入する入力の性質 (静的 vs 動的)」を対称性監査対象に含める形で test 追加 PR の review に定着している。

#### 設計判断の test pin

TC-027 は single-quote 内 `$` (`--title '$pr_title'`) が bash では literal だが検出器は `$` を変数 sentinel とみなし not-flag する**意図的 false-negative** を pin する。「real variable form を決してブロックしない安全側の選択」という設計判断をコメントで明文化したうえで test = 実行可能仕様として固定しており、適用 12 (非ブロッキング契約のような observable な差が出にくい invariant) と同じく「設計意図を test で pin する」系譜。

教訓: 検出 regex の alternation / negated bracket の各 branch は、それぞれ独立の positive/negative TC で pin しないと片側が dead range のまま劣化 mutation をすり抜ける。テストのみ変更 PR では reviewer 側の独立 mutation 再現 (2 reviewer 以上) が teeth の cross-validation として 1 cycle 収束を支える (適用 13/18/19 の連続再現)。boundary 推奨 (equals × single-quote の 2×2 完全網羅) は区切り文字クラス `[[:space:]=]` と開始引用符クラス `["']` が独立文字クラスで直交 pin 済みのため reviewer が「実害なし・スコープ外」と非 blocking 判定し、user も Phase 7 で「無視」を選択した — alternation の各因子が独立なら直交 pin で十分という判断の実測。

### 適用 21: negative assertion の非 vacuity を「差分ペア構造 + 入力決定性」で立証する — 能動 mutation を回せない READ-ONLY reviewer の構造的代替 (PR #1319 で実証)

PR #1319 (Issue #1220 — `review-source-resolve.sh` の未カバー error 経路 5 件に behavioral assertion を追加、+125/-0 でテストのみ変更・検出器本体無変更) は 4 reviewer (test / performance / error-handling / security) 全員「可」/ 指摘 0 件 / 1 cycle mergeable に到達し、適用 13/16/18/19/20 の「テストのみ変更 PR を reviewer 側で非 vacuous 立証」系譜を継続した。本 PR の固有観点は **能動 mutation を回せない状況での negative assertion 非 vacuity 立証手法** にある。

#### 観点 1: differential ペア構造が negative assertion の非 vacuity を構造的に保証する

新規 `assert_err_lacks "REVIEW_SOURCE_STALE=1"` (match ケースで STALE marker が**出ない**ことを pin する negative assertion) は、単独では「STALE がそもそも当該経路で発火し得ない」だけでも trivially pass する vacuous リスクを持つ (適用 17 #3 の「negative assertion 単独は空出力 mutation で trivially pass」と同型)。本 PR の Test 6/8 は **同一 emitter に対し match ケース (STALE 不在を assert) と mismatch ケース (STALE 存在を assert) を対で配置**しており、mismatch ケースが「STALE は本経路で emit され得る」ことを実証するため、match ケースの negative assertion は「equality 分岐が STALE を実際に抑止している」ことを検証する非 vacuous なものになる。これは適用 10 (対称化の positive/negative 双方向 pin) を、**能動 mutation の代わりに「正常入力で発火する positive ケースを差分ペアとして併設する」構造的論証**へ展開したもの。reviewer (security) は「mismatch ケースが positive proof として働くため match ケースの negative assertion は trivially-passing ではない」と差分構造から非 vacuity を導いた。

#### 観点 2: 入力決定性の理論的保証が runtime mutation の代替になりうる

test-reviewer は READ-ONLY guard によりサンドボックス内の能動 git mutation を block されたが、`BOGUS_SHA` = all-zeros (Git の予約 null-object sentinel、実 commit object の content hash には成り得ない) と match ケースの sandbox 実 HEAD (`git rev-parse HEAD`) の組み合わせから `BOGUS_SHA != HEAD_SHA` が**決定論的に保証される**ことを理論的に立証し、mismatch 分岐が確実に発火することを runtime mutation なしで担保した。能動 mutation が制約で回せない場合、(a) 差分ペア構造 + (b) 入力値の決定性の理論保証 の 2 点で identification power を代替立証できる (適用 13 の worktree-only mutation が使えない READ-ONLY 経路の補完)。

#### 観点 3: assert する reason 文字列の実装 emit との byte 一致照合が test 正しさの核心

test / error-handling reviewer はともに、新規 9 件の `assert_err_has "...reason=..."` の reason 文字列 (`explicit_file_commit_sha_mismatch` / `local_file_critical_high_scope_nit_noted` / `local_file_schema_required_fields_missing` 等) を実装 `review-source-resolve.sh` の `echo "[CONTEXT] ..."` emit 行と 1 件ずつ突合し全一致を確認した。assert する literal が実装 emit と byte 乖離していれば test は壊れた実装でも green になる (vacuous) ため、**reason 文字列の実装 emit との byte 一致照合**が error-path behavioral test の正しさの核心になる (適用 19 の「既存 TC との byte-identical 対称性照合」を test↔実装 emit 方向へ向けた版)。

教訓: 能動 mutation を回せない READ-ONLY reviewer でも、(a) match/mismatch の差分ペア構造 (positive ケースが negative assertion の非 vacuity を保証)、(b) 入力決定性の理論保証 (all-zeros SHA 等の構造的に衝突しない値)、(c) assert literal と実装 emit の byte 一致照合 の 3 点で error-path behavioral test の identification power を構造的に立証できる。差分ペアによる非 vacuity 担保は active mutation (適用 10/13) の構造的代替として、対称転記の vacuous リスク ([[asymmetric-fix-transcription]] の test 側双対) を回避する。

### 適用 22: dedup assertion の非 vacuity を重複 fixture で立証 + section-scoped 静的契約 test の helper rename 検出を mutation で実証 (PR #1321 で実証)

PR #1321 (Issue #1209 — `wiki-lint-source-refs.test.sh` の dedup assertion と lint.md 6.2 fallback 回帰追加、+35/-2 でテストのみ変更・helper / lint.md 本体無変更) は test / code-quality 2 reviewer が独立 mutation で 0 findings / 1 cycle mergeable に到達し、適用 13/18/19/20/21 の「テストのみ変更 PR を reviewer 側で非 vacuous 立証」系譜を継続した。本 PR の固有観点は 2 種の vacuity 解消手法を 1 PR で併用した点にある:

1. **dedup assertion の非 vacuity は「入力に重複を実在させる」ことで担保する**: TC-1 の label は `sort -u` を謳うが、入力 (p1/p2) に重複 ref が 1 件もないため helper の `sort -u` を `cat` に置換しても全 assert が PASS する vacuous 構造だった (適用 5 Pattern 5-A の dedup 版 — 機構が input に対し no-op だと dead path 化)。fixture `write_pages` の p2 に p1 と同一の**正規化済み** ref を重複追加し、「当該 ref の出力行数 = 1」を assert することで `sort -u`→`cat` mutation が count=2 を生んで FAIL する load-bearing 化を達成。両 ref を prefix なし正規化済み形式に揃え normalization を no-op にすることで、`sort -u` のみが結果決定要因になるよう isolation した (適用 11「測定対象シグナルを単独の結果決定要因にする」の dedup 版)。
2. **section-scoped 静的契約 test の helper rename 検出を empty-section fail で構造化**: TC-14 は lint.md 6.2 の helper-不在 fallback (`[ ! -f ...wiki-lint-source-refs.sh ]` branch) の io_error 出力契約 4 行を `assert_grep_in_section` で if-branch scoped に pin する。reviewer が io_error→true / helper rename の 2 mutation を実機適用し、前者は read_ok assert が FAIL、後者は guard 内 filename 変化で section 抽出が空になり empty-section fail で surface することを確認。section start_pattern を guard の helper filename に anchor することで「rename しても test が更新を強制される」rename-detection 機構を実装した ([[section-scoped-assertion-prevents-narrative-false-negative]] の rename 検出への応用)。

教訓: 機構 (dedup / sort -u) を test する assertion は、その機構が input に対し実際に作用する fixture (重複を実在させる) を用意しないと no-op mutation をすり抜ける vacuous 構造になる。md 契約の静的回帰 test では section anchor を契約の load-bearing identifier (helper filename 等) に置くことで、anchor 対象の rename を empty-section fail として強制 surface できる。lint.md のような LLM 実行手順書 (bash として直接起動されない) の fallback 分岐は behavioral test 不能なため、section-scoped 静的契約 test が canonical な回帰防御になる ([[static-input-chain-function-extraction-non-vacuous-test]] の md 契約版)。

### 適用 23: sweep 条件の構造的盲点 (>&2 同一行条件 vs 代入行 idiom) を author 側 mutation で実証して fail-closed 設計へ pivot する (PR #1337 で実証)

PR #1337 (Issue #1329 — head -c / 関数内 >&2 / cat 系の control-char 中和横展開) で、新規 sweep test TC-3 の初版が **`head -c` + `>&2` 同一行条件**で書かれていたが、author が commit 前の mutation 注入 (post-compact.sh の neutralize_ctrl 除去) で **mutation が検出されない vacuous 状態**を実証した。原因は `head -c` snippet の大半が `var=$(... | head -c 200 ...)` の**代入行**で、emission の `>&2` は後続 echo 行に分離している構造 — 同一行条件 sweep では構造的に検出不能。

fix 方針: `>&2` 条件を撤去して **head -c 全行を sweep し、非 emission の既知 site (lock pid 読み取り) のみ明示 allowlist で除外する fail-closed 設計**へ pivot。pivot 後の再 mutation で検出を確認。

さらに review cycle 1-2 で 4 reviewer (security / error-handling / test / code-quality) が**独立に worktree-only mutation** で TC-3 / TC-4 / TC-5 / TC-025 の非 vacuity を再実証し、author 側 mutation claim の信頼性を cross-validation で裏付けた (cycle 2 は 0 findings / mergeable)。

教訓: **sweep test の検出条件 (同一行 grep / 行指向フィルタ) は、対象 idiom の構造 (代入行と emission 行の分離) と一致するかを mutation で実証してから commit する**。「条件付き sweep が綺麗」という直感は構造的盲点を隠す — fail-closed (全行 sweep + allowlist) は false positive 管理のコストを払う代わりに盲点を排除する。pivot 時は cross-reference コメントの追随も必須 ([design-pivot-stale-cross-reference-comment](../anti-patterns/design-pivot-stale-cross-reference-comment.md) 参照)。

### 適用 24: 回帰防止テストの grep token は「修正パス固有」にする — 旧コードの remediation hint にもマッチする generic token は修正前でも PASS する (PR #1663 で実証)

PR #1663 (Issue #1662 — corrupt/orphaned wiki-worktree からの自己回復) review で、新規追加された回帰防止テストの assertion が **旧コード (修正前) の remediation hint 文言にもマッチする generic な grep token** を使っていたため、**修正前でも PASS する non-discriminating な構造** になっていたことが指摘された。回帰防止テストの定義上、対象は「修正前は FAIL し修正後は PASS する」べきだが、grep token が修正パス固有でないと修正前でも条件を満たし identification power が 0 になる。

```bash
# 反面教材 — 修正後の自己回復経路を検証するはずの assertion
# だが grep token が旧コードにも存在する remediation hint 文言にマッチ
assert_err_has "WARNING"            # ← 旧コードの別 WARNING でも PASS
assert_err_has "worktree"           # ← 旧コードの hint 文言でも PASS

# 修正前 (silent exit 1 の旧経路) でも上記が PASS してしまう = non-discriminating
```

これは適用 5 Pattern 5-A (Self-grep tautology) / 適用 14 (latent matching) と同型の「test が実装の正否を弁別できない」identification power 0 の系統で、特に **「修正前後で文言が共有される領域」(同ファイル内に旧経路の hint と新経路の WARNING が併存する)** で発生しやすい。anti-silent-failure 化のような「silent → observable」遷移を検証する回帰テストは、旧経路 (silent) でも偶然 surface する generic 語ではなく、**修正で新規導入された経路固有の sentinel / reason 文字列** を grep token に選ぶ必要がある。

canonical 対策:

1. **grep token を修正パス固有の literal に絞る**: 修正で新規に emit するようになった `[CONTEXT]` sentinel / reason 文字列 (例: 自己回復経路でのみ出る固有 marker) を assertion token にする。`WARNING` / `error` / ドメイン共通語のような旧コードにも存在する generic token は避ける。
2. **修正前 base に対する revert test で discrimination を実証する**: 適用 1〜3 の手順どおり、修正行を revert (または旧 silent 経路を再現) して当該 TC が **FAIL する**ことを確認してから commit する。修正前後の両方で PASS する token は non-discriminating として token を絞り直す。
3. **「silent → observable」遷移テストは observable 側の固有 sentinel を pin する**: silent failure を observable にする修正の回帰テストは、「何かが stderr に出る」ではなく「修正が導入した固有の WARNING/sentinel 行が出る」を pin する。旧経路でも出る汎用語では silent regression (再び silent に戻る) を catch できない。

教訓: 回帰防止テストの grep token は「対象の修正パスでのみ生成され、修正前のコードには存在しない literal」を選ぶ。これが満たされているかは **修正前 base での revert test が FAIL すること**で機械的に保証する。同ファイル内に旧経路 hint と新経路 WARNING が併存する anti-silent-failure 化修正で特に陥りやすい (修正自身が局所 silent 抑制を残す self-referential 失敗は [[asymmetric-fix-transcription]] / [[mktemp-failure-surface-warning]] と対で監査する)。

### 適用 25: payload/target が「本来 allow されるもの」でないと mutation に対し vacuous (PR #1736)

`pre-tool-bash-guard.sh` の reviewer git guard に timeout bypass 対策 (総バイト長ガード + 反復上限) を追加した PR #1736 で、追加テストが「主張する不変条件を実際には検証していない」vacuous サブアサーションを 2 種、cycle をまたいで mutation で摘発した。

- **独立に deny される payload は guard の mutation に対し vacuous**: cycle 2 の TC が `git <巨大パディング>checkout evil` を deny 判定していたが、`git checkout` は **guard/cap の有無に関わらず** Pattern 4 (A) で独立に deny される。よって cap 除去 mutant でも `decision=deny` のまま pass し、cap の検出力ゼロ。**検証したい guard が無ければ本来 allow されるはずの read-only verb (`git <巨大パディング>status`) に payload を変えた瞬間、cap 除去 mutant は `git status` に正規化され allow に flip し、初めて真の mutation-catcher になった** (allow→deny flip の観測が帰属の証拠)。「deny を確認する」テストは、対象の guard を外すと **allow に戻る** payload でなければ帰属が成立しない。
- **O(n²) を突くつもりの入力が実は fast path を通る**: 別 TC が `${COMMAND%%<<*}` (heredoc 除去) の O(n²) スキップを検証すると称し `git checkout evil <<EOF\n<200KB>\nEOF` を使ったが、`<<` が文字列**先頭**にあると `%%<<*` は先頭一致で高速完了し、guard の有無で速度が変わらない (mutant でも `ms<5000` pass)。コメントが主張する「O(n²) strip skipped」を実測していなかった。**検証対象の性質 (どの入力配置が O(n²) を発火させるか) を正確に狙う**必要があり、O(n²) no-heredoc 経路は別 TC (`<<` なし巨大コマンド → mutant で rc=124 timeout) が担保する形へ役割分離した。
- **共有 tag の inert write**: deny 経路が自己完結でメッセージを構築する場合、共有 `BLOCKED_SUBKIND` 等への代入は唯一の読み手 (skip される別 block 内) に届かず inert write になる。削除するか、tag-at-source の一貫性目的で残すなら inert である旨をコメントで明示する (将来の maintainer が「tag が message を駆動する」と誤読して復活させる regression を防ぐ)。
- **huge command 入力は argv 制限回避のため tempfile + `jq --rawfile`**: MB 級のコマンドを `jq -n --arg cmd "$big"` で組むと "argument list too long" でテストハーネス自体が壊れる。file に書き出し `--rawfile` で読ませる。

教訓: 「deny を確認する」テストの payload は、**検証対象の guard を外すと allow に戻る**もの (read-only verb / by-default-allowed 入力) を選ぶ。state-mutating verb や独立に block される入力は、guard の有無に関わらず deny され vacuous。加えて「O(n²)/slow を突く」テストは入力の**配置**まで検証対象の発火条件に合わせる (先頭一致で fast path を通ると空振り)。いずれも **guard 除去 mutant で当該 assertion が FAIL するか**を commit 前に必ず実測する ([[static-input-chain-function-extraction-non-vacuous-test]] / [[leading-dash-arg-injection-gate-pre-git]] と同じ「非 vacuous 化 → mutation 実証」の系譜)。

### 適用 26: 複数ガードが論理和を構成するとき「特定ガードを exercise する」コメントは vacuous — mutation で isolate 可否を確認し、未到達な防御的分岐は正直に文書化する (PR #1718)

PR #1718 (issue-claim の CAS `_atomic_claim_steal` 二段ガード = mismatch→10 / revive→10 + work-memory-lock の PID 再利用検出) の 4 cycle レビューで、実装ではなく **テストコメントの「カバレッジ主張の正確さ」** が dominant な指摘対象になった。並行奪取テスト TC-14 は全 contender を `mk_active` するため winner が live で、loser は 2 ガードのどちらでも abort しうる。ところが TC-16 のコメントは「mismatch→10 は TC-14 の losers で exercised され、mismatch path が double-steal guarantee を担う」と記し、**特定ガード (mismatch) を単独 isolate している**かのように読めた。

#### 失敗の構造 — 「行実行順序」と「mutation-isolated coverage」の混同

unmutated code では mismatch ガードが先に評価され loser を捕捉する。この「行実行順序」を「mutation-isolated coverage (そのガードだけを検証している)」と混同すると over-claim になる。mutation で実測すると:

```bash
# mismatch ガード単独除去 ([ "$cur" = "$expected" ] || exit 10 を削除)
#   → TC-14 は緑のまま (winner が live なので revive ガードが loser を捕捉)
# revive ガード単独除去 (_holder_is_live "$cur" && exit 10 を削除)
#   → TC-14 は緑のまま (mismatch ガードが loser を捕捉)
# 両ガード除去 → 初めて赤 (5 プロセス全 mv、_stolen=5 ≠ 1)
```

→ TC-14 は 2 ガードの **論理和** のみを検証しており、どちらのガードも単独では isolate していない。これは適用 5 Pattern 5-B (件数判定の片側 mutation 隠蔽) / 適用 10 (対称性主張の片側のみ pin) と同型の coverage gap を、対象を **「防御 in-depth の複数ガードのうち特定の 1 つを exercise する」というコメント上の主張** へ一般化したもの。

#### Fix 方針 — コメント軟化も valid な fix (未到達分岐の正直な文書化)

二次防御の revive 分岐 (out-of-lock classify と in-lock 再検証の間の TOCTOU race で発火) は、公開 CLI 経由では **on-disk holder ≠ expected かつ not-live** という状況を決定的に作れず未到達になる。mismatch ガードを単独 isolate するテストを追加するのも一案だが (堅牢)、この PR では **コメントを「2 ガードが協調して防ぐ／全 contender が live なため単独 isolation は本 TC では担保されない」という実態へ軟化する最小変更** (実行コード不変) で解消し、次 cycle で 4 reviewer が実装トレースで over-claim/under-claim ゼロを再検証して 0 findings 収束した。

**未到達の防御的分岐を「カバー済み」と偽らず、コメントで正直に未到達と文書化する**ことは valid な fix であり (no-silent-caps)、必ずしも「テストを足す」必要はない。カバレッジ主張は必ず mutation で裏付ける。

#### 併発 sub-pattern (同 PR で cross-validation)

- **プラットフォーム依存 skip ガードの左右対称**: start-token 取得不能環境での legacy PID-only hold を検証する成功アサート TC (TC-014) と skip ガード TC (TC-015) は対称に揃える。片方だけガードが欠けると「コードは正しいがテストが特定環境で偽 FAIL」する非対称バグになる (詳細は [test-env-gate-ci-alignment](../heuristics/test-env-gate-ci-alignment.md))。
- **「対称化」AC の test pin 強度非対称**: eval 前 jq 検証の対称化 AC で、対称元テスト (`projects-status-update` TC-002) が warning 文言まで pin しているのに新規側 (`create-issue` TC-015) が汎用 exit≠0 のみで新ブランチ固有挙動を pin していない non-symmetry が残った。汎用 exit≠0 は対象ブランチを削除しても下流の別経路で同 exit code になり vacuous。対称化 AC は実装だけでなく **テストの pin 強度も対称化** し、mutation (対象ブランチ削除で当該テストのみ FAIL するか) で裏付ける。
- **SPEC 要約の over-claim 回避**: 実装の保守的縮退経路 (legacy / プラットフォーム非対応) を SPEC 要約で無条件断定せず「when a start-token was recorded」等の条件付き表現で明記する ([prose-design-without-backing-implementation](../anti-patterns/prose-design-without-backing-implementation.md) の逆方向 = 実装より強く書かない透明性)。

教訓: **防御 in-depth の複数ガードのうち特定の 1 つを「exercise する」と主張するテストコメントは、mutation で当該ガードを単独除去して該当テストが FAIL するかを確認するまで信じない**。論理和構造では単独 isolation は成立せず、CLI で決定的再現不能な二次防御は「未到達」と正直に文書化するのが最小 fix。

### 適用 27: 2 段構え fallback (優先経路 → fallback 経路) の fallback 側成功パスが未カバーのまま残る (PR #1921 で実証)

PR #1921 (Issue #1914 — `issue-body-safe-update.sh` の owner/repo 解決を SSH host alias 対応にする) で、優先経路 (`git-remote.sh resolve-owner-repo`) → fallback 経路 (`gh repo view`) の 2 段構え実装に対し、初版テストは「優先経路の成功」と「両経路の失敗」の 2 状態だけを固定し、**fallback 経路が実際に成功する状態が未カバー**のまま残っていた。test reviewer が fallback 関数を `false` に置換する mutation を適用し、全テストが緑のままであることを実測して確定した。

```bash
# 反面教材 — 2 状態のみ固定
# 1. 優先経路 (resolve-owner-repo) が成功する場合
# 2. 優先経路・fallback 経路の両方が失敗する場合
# ↑ fallback 経路 (gh repo view) が単独で成功するケースの pin が無い

# Mutation: fallback 関数を無条件 false に置換
gh_repo_view_fallback() { return 1; }
# 期待: 優先経路を無効化した状態で FAIL するはず
# 実測: 全テストが PASS → fallback 単独成功パスが dead
```

fallback は「普段通らない経路」であるため、成功系のテストを書き忘れてもテストスイートは緑で通過し、将来のリファクタで fallback が壊れても元のバグへ silent に回帰する。これは適用 5 Pattern 5-B / 適用 10 (対称性主張の片側のみ pin) と同型の coverage gap を、対象を **「優先経路 / fallback 経路の 2 段構え」の tier 別 pin** へ一般化したもの。

#### Canonical 対策

優先経路成功 / fallback 経路成功 / 全 tier 失敗の **3 状態を個別に pin** する。tier を分ける mutation (優先経路のみ無効化 → fallback 単独成功を確認、fallback のみ無効化 → 優先経路単独成功を確認、両方無効化 → 失敗 degrade + WARNING を確認) を必須の 3 点セットとする。

同 PR review でもう 1 件、テストの前提不成立時 skip を `pass` ではなく素の `echo` で実装したことで、skip 発火時にアサーション数が減っても `FAIL: 0` のまま表示され、カウンタ・マーカー基準の走査からカバレッジ欠落が観測できなくなるパターンが検出された ([[test-helper-follows-sibling-convention]] の再発事例)。4 reviewer 中 3 名が 0 findings で、唯一 findings を出した test reviewer が隔離 worktree での mutation testing により両指摘を実測で裏づけた事例。

教訓: **N 段構え fallback は tier 数と同数の positive pin を用意する**。「優先経路成功」「全滅」の 2 極端だけでは中間 tier (fallback 単独成功) が dead range になる。tier ごとに他 tier を無効化する mutation を適用し、対応する pin が単独で FAIL することを commit 前に確認する。

### 適用 28: fixture は検証対象の分岐に到達するまでの状態ライフサイクル全体を再現しないと mutation で flip しない (PR #1967 で実証)

reap manifest（`branch\t<name>` 形式）の消費ロジックに対する新規テスト（D-03: 別名エントリは消費しない、を含む複数 TC）が、mutation testing（消費ロジックを sed で無効化しても全 TC が PASS したままになる）で空虚（vacuous）と判明した。原因は fixture が「manifest にエントリが記録されている」状態だけを用意し、消費ロジックが実際に評価する前提条件（当該 branch が worktree で checkout 中で claim が free、かつ mtime が fresh）を再現していなかったこと — 消費ロジックの手前にある無関係な分岐（stale claim の early continue 等）で TC が early-return し、意図した消費ロジック自体には到達していなかった。修正は「実在する branch + claim-free な worktree」という完全なライフサイクルを fixture 側で構築し、mutation 適用で TC が確実に FAIL することを再確認して収束させた（cycle 2 では新設した D-04/D-05 も同じ observation で non-vacuous を実証）。

教訓: 状態遷移を経由するロジック（manifest 消費、claim 解放、multi-step ワークフロー等）をテストする fixture は、検証対象の分岐に到達するまでの**前提条件を実際に満たす状態**を構築しなければならない。単に「最終状態のデータ（manifest のエントリ）」を置くだけでは、その手前にある無関係な early-return / guard 分岐で TC が意図せず早期終了し、mutation で対象ロジックを無効化しても TC が変化しない空虚テストになる。fixture 設計時は「この TC は本当に対象分岐を通るか」を mutation で実測するまで信頼しない（[[fixture-mutation-isolates-invariants]] の manifest ライフサイクル版）。

### 適用 29: 隔離 scratchpad での mutation test により、新設した WARNING 検証テストの実効性を実証 (PR #1970 で実証)

PR #1970 cycle 2 で追加した TC-15（`.claude/settings.local.json` コピー失敗時の WARNING 出力を検証するテスト）に対し、cycle 3 で error-handling reviewer が実リポジトリを汚さない `scratchpad/mutation-test/` 上の隔離コピーで対象コードを cycle 1 以前の無音化パターン（`2>/dev/null || true`）に意図的に戻し、TC-15 を含むテストスイートが `32/32 PASS` → `31 PASS / 1 FAIL` に変化することを実証した。これにより「新設テストが実際に対象コードの振る舞いに依存しており、トートロジーでない」という主張に実測の裏付けが与えられた。

教訓: mutation testing を実施する際、対象コードが本番の作業ブランチ（PR の diff 対象）そのものである場合、mutation の適用先を **実リポジトリの外（一時ディレクトリ等の隔離コピー）** に限定することで、reviewer の READ-ONLY 制約（working tree を変更しない）を守りながら実効性検証ができる。適用 5〜9 で確立された「mutation で実装を kill してテストが red になるか確認する」手法を、reviewer 自身が対象 PR の branch を直接操作できない制約下でも安全に実行するための具体的な実装パターン。

### 適用 30: 安全ゲートを剥がす mutation は producer 側 (recorder + guard) にも discriminating assert が無いと consumer 側だけでは無検知で通過する (PR #1974 cycle 2 で実証)

PR #1974 (Issue #1945) cycle 2 で、新規追加した `session_worktree` type の manifest 記録ロジック（recorder + `{pr_merged}=true` guard）に対し、consumer 側（reap ロジック）の discriminating test は用意されていたが、**producer 側（recorder + guard 自体）** には対応するテストが存在しなかった。test reviewer が両方のブロック（sandbox-mask 分岐 / busy-failed 分岐）から `{pr_merged}=true` guard を剥がす mutation を適用したところ、既存テストスイートが無検知で通過することを実測した。

```bash
# 反面教材 — consumer 側 (reap ロジック) のみ discriminating assert を持つ
# producer 側 (recorder + guard) は「呼ばれたら記録される」ことしか検証していない

# Mutation: 両ブロックから {pr_merged}=true ガードを除去
# （未マージ corpse worktree のパスも無条件で記録されるようになる）
# 期待: producer 側の test が FAIL する
# 実測: 全テスト PASS → producer 側に discriminating assert が存在しない
```

#### Canonical 対策

`assert_grep_in_section` で該当分岐 (sandbox-mask / busy-failed) それぞれについて、**record 呼び出しと `{pr_merged}=true` ガードの両方が同一セクション内に存在すること**を固定する。汎用の「`pr_merged` という語がどこかにある」だけの assert では、ガードが record 呼び出しから外れて常時記録に regression しても検知できない — 検出対象の 2 要素（呼び出しとガード）を **同一の狭いセクション境界内** で共起させる assert でなければ discriminating power を持たない。

#### 教訓

新機能が「安全ゲート（`{pr_merged}=true` 等の条件）付きで既存の共有インフラを呼び出す」形の場合、テストカバレッジは **consumer 側（呼び出された結果をどう処理するか）だけでなく producer 側（呼び出す条件そのもの）にも discriminating assert が必要**。producer 側のテストが「呼ばれたら動く」ことしか検証せず「ガードなしでは呼ばれないこと」を検証していないと、安全ゲート自体を剥がす regression がテストスイートを無検知で通過する。本パターンは適用 5 の Self-grep tautology / Path filter coverage gap と同型 (呼び出し条件の mutation に対する identification power 0) だが、対象を「安全ゲート付き呼び出しの producer/consumer 両面カバレッジ」に一般化したもの。関連する共有リソース契約違反の背景は [[shared-resource-type-reuse-without-consumer-contract-check]] を参照。

### 適用 31: degrade 経路テストの discriminator は「degrade が働いて初めて成立する肯定結果」で設計し、commit 前 mutation で識別力を検証する (PR #2003 で実証)

PR #2003 (Issue #1999、flock 不在環境の `command -v flock` degrade 追加) では、**同一 PR 内の 2 つの新規テストで識別力が分岐した**: TC-6 (atomic-write) は set の rc / state file 内容 / stderr を直接 assert して mutation (ガード除去) を正しく検出したが、TC-9 (wiki-ingest-lock) は (1) rc の `|| true` 破棄、(2) locale 依存の英語エラーメッセージ grep（非英語 locale で never match）、(3) mkdir ロック実装ゆえガード有無で構造的に pass する assert 構成、の 3 重で mutation に対し全 green の false-positive test だった。error-handling / test 両レビュアーが隔離 worktree の mutation 実験で独立にこれを実証した (cycle 1 HIGH)。

fix では discriminator を「degrade が働いて初めて成立する肯定結果」で再設計した — no-flock `set` の rc 直接 assert に加え、**別セッションからの liveness 判定が `held` を返す**ことを assert する (degrade が壊れて state 未書込なら holder not-live → `stale` が返るため locale 非依存に検出できる。既存 TC の挙動の再利用)。fix commit 前にガード除去 mutation で新 TC-9 が正確に 2 assert FAIL することを検証してから push し、cycle 2 で両レビュアーが独立再実証して収束した (3 cycle: HIGH 1 → LOW 1 → 0)。

#### 教訓

- degrade / fallback 経路のテストは、エラーメッセージ文字列の否定形 grep ではなく「degrade 成功時にのみ成立する状態遷移・戻り値」を assert する ([[locale-dependent-error-message-grep-assertion]] 参照)
- 「テストの識別力を直す fix」自体も、commit 前に mutation で FAIL することを確認してから push する — 修正が本当に teeth を持つかは実測でしか分からない
- degrade 系 PR の妥当性説明には「どの環境でも機能していた保護を除去しない (degrade 前は当該環境で操作自体が失敗していた) = strictly additive availability」の framing が有効 (application レビュアーが cycle 3 で明文化)

### 適用 32: mutation は「今直した箇所」ではなく「そのテストが守ると主張する全アサート」に当てる (PR #2013 cycle 3 で CRITICAL として実証)

PR #2013 cycle 2 で「成功行のアサートが集計行にもマッチする」穴を見つけ `assert_line_matches` で塞ぎ、3 種の mutation で確認した。ところが cycle 3 で、**同じファイルの別のアサート**（失敗ファイル名を検証する側）が runner の `=== Running: X ===` 進捗行にマッチしたまま残っていることが判明した。

```bash
# TC-4 のアサート（守ると宣言した軸: 「失敗リストがファイル名を出す」）
assert_contains "$OUT" "_test-helpers.test.sh"

# 実際にマッチしていたのは失敗リストではなく進捗行:
#   === Running: _test-helpers.test.sh ===
# この行は結果に関係なく必ず出るため、失敗リストが名前を出さなくなっても 4 assertions が永久に green
```

TC-4 のコメント自身が「ファイル名を出す行が消えるのを防ぐ」と書いており、**守ると宣言した軸そのものが未 pin** だった。直接の原因は cycle 2 で **修正した箇所（成功行）しか mutation で検証しなかった** こと。

> **規則 1**: mutation は「今直した箇所」ではなく **そのテストが守ると主張する全アサート** に回す。アサートごとに「これが守る挙動を壊したら赤くなるか」を 1 つずつ確認する。直した箇所だけを検証するのは「修正の確認」であって「テストの検証」ではない。
>
> **規則 2**: 文字列マッチを書いたら、**被テスト対象がその文字列を別の目的で出していないか grep する**。進捗行・ヘッダ・診断文は同じ識別子を含みやすい。

#### 「N 象限を pin した」と主張するときは軸の直交性を確認する

同 PR は「4 象限（失敗 × drift）」を pin したと称したが、`失敗 × 正しくカウントされた skip` のセルが無く、各 TC のサンドボックスに合成ファイルが 1 個しかないため **ファイル横断の積み上げ**（`SKIPPED=$((SKIPPED + file_skips))`）が一度も実行されていなかった。結果 5 種の mutation が生存した。さらにパーサ 2 種のうち 2 つ目は、1 つ目が先にマッチして **到達すらしていなかった**（`SKIP: N` を出すと `Results:` パーサに届かない）。

> **規則 3**: 「象限」を主張するなら各軸の値が **独立に変化する** ケースを列挙して埋める。集計ロジックを pin するなら入力を複数にし、フォールバック経路を pin するなら先行経路が空振りする入力を作る。

#### mutation が生存したら、テストを足す前に「なぜ届かないか」を実測する

cycle 3 では 9 種の mutation（失敗名 suppress ×2 / 集計行の gated group 削除 ×2 / 積み上げ→代入 / `[^❌]` ガード緩和 ×2 / 行アンカー除去 / bail 順序 revert / 成功行サフィックス削除）を全て KILLED まで持っていった。うち 1 種（`[^❌]` ガード緩和）は初回 SURVIVED し、原因を調べたところ「TC-8 が `SKIP: N` を出すため 2 つ目のパーサに到達していない」ことが判明、`Results:` 形式を使う TC-9 を分離して塞いだ。

> **規則 4**: mutation が生存したら、**テストを足す前に「なぜ届かないか」を実測で特定する**。届かない原因を潰さずにテストを増やすと、同じ死角に別の vacuous TC を積むだけになる。

#### 「N 件 pass」は識別力の証拠にならない

cycle 2 で新設した会計テストの初版は 42 assertions が緑だったが、mutation（成功行から gated group サフィックスを削除）を **検出できなかった**。原因は `assert_contains` が出力全体を見ており、集計行にも同じ文字列があったため。行を特定する `assert_line_matches` を足して塞いだ。


## 関連ページ

- [無音失敗を可視化する防御コードには、その防御コード自体を守る失敗パステストを追加する](../heuristics/defensive-code-needs-its-own-failure-path-test.md)

- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [Enum 拡張時の few-shot coverage completeness](../heuristics/enum-extension-few-shot-coverage-completeness.md)
- [Lint の見出し抽出はコードフェンス内行を除外してから行う (検証ツール自身の false-negative 防止)](./lint-strip-code-fence-before-extraction.md)
- [consume 操作 (read+delete+return) は delete-then-return 順で fail-closed にする](./consume-operation-delete-then-return-fail-closed.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [入力注入経路のない静的文字列処理連鎖は関数抽出 + 境界行 extract で非 vacuous unit テスト化する](./static-input-chain-function-extraction-non-vacuous-test.md)

## ソース

- [PR #1967 review results cycle 1 (D-03 fixture が manifest 消費分岐に未到達で空虚テスト、HIGH 1件)](../../raw/reviews/20260722T020659Z-pr-1967.md)
- [PR #1967 review results cycle 2 (D-04/D-05 の mutation 実証)](../../raw/reviews/20260722T022920Z-pr-1967.md)
- [PR #688 review results (cycle 3) — TC-10 false-positive 発見](../../raw/reviews/20260426T235945Z-pr-688.md)
- [PR #688 fix results (cycle 4) — mutation testing による解消パターン](../../raw/fixes/20260427T000422Z-pr-688.md)
- [PR #688 fix results (cycle 5) — TC-13 false-positive + 3 cycle 連続適用実績](../../raw/fixes/20260427T020357Z-pr-688.md)
- [PR #688 cycle 42 review — bash command substitution trailing newline strip 仕様による false-positive 構造](../../raw/reviews/20260428T050216Z-pr-688.md)
- [PR #688 cycle 42 fix — bytes-exact pin (`wc -c`) で trailing newline 規約の mutation 耐性を獲得](../../raw/fixes/20260428T051514Z-pr-688.md)
- [PR #765 cycle 1 review — review test の identification power 不足 3 種 (Self-grep tautology / 件数判定片側 mutation 隠蔽 / Path filter coverage gap)](../../raw/reviews/20260502T095733Z-pr-765.md)
- [PR #915 review — M6 fixture trailing whitespace の load-bearing 性検出 + pre-check による self-pin canonical 化](../../raw/reviews/20260509T071343Z-pr-915.md)
- [PR #1066 review — regex alternation の片側 positive coverage 欠落 + quantifier `\s*` semantic 片側のみテスト (2 種 cross-validated HIGH)](../../raw/reviews/20260520T011841Z-pr-1066.md)
- [PR #1066 cycle 1 fix — alternation 各 branch + quantifier 境界値 + flag 必須 case + 大文字小文字混在 case で positive 6 + negative 6 に拡張](../../raw/fixes/20260520T022118Z-pr-1066-cycle1.md)
- [PR #1167 cycle 2 review — 新規 helper strip_code_fences を cat に mutate しても test 11/11 PASS する identification power 0 を mutation 観点で指摘 (non-blocking follow-up)](../../raw/reviews/20260528T122742Z-pr-1167.md)
- [PR #1169 fix results (cycle 3) — consume-handoff の fail-closed invariant を守る TC-H6 を追加し、print-then-delete への mutation で FAIL することを確認 (correctness invariant 導入 fix には mutation-fail test を同 PR で添える)](../../raw/fixes/20260528T143720Z-pr-1169.md)
- [PR #1169 review results (cycle 2) — bash positional 引数誤配置 (`stop_payload "$d" true`) が test 常時 PASS の silent false-positive を生み mutation testing でのみ検出可能だった事例](../../raw/reviews/20260528T141817Z-pr-1169.md)
- [PR #1172 review results (cycle 1) — 「対称化」claim の片側 (happy-path 非発火) を pin する test 欠落を mutation で検出、無条件 WARNING emit mutant が全 103 assert を pass する coverage gap](../../raw/reviews/20260528T154013Z-pr-1172.md)
- [PR #1172 review results (cycle 2) — cycle 1 fix (TC-H4 negative-assert) が gap を解消したことを双方向 mutation で実証 (無条件 emit → TC-H4 fail / WARNING 削除 → TC-H7 fail)](../../raw/reviews/20260528T155654Z-pr-1172.md)
- [PR #1172 fix results — happy-path 非発火を pin する negative-assert (TC-H4) を TC-H7 と対に追加、mutant を hooks/ 内に配置して sibling script source 解決を再現し gap 捕捉を確認](../../raw/fixes/20260528T155033Z-pr-1172.md)
- [PR #1222 review results (cycle 2) — long-block 25 行境界 TC 欠落を mutation で実証し MEDIUM 昇格 (filler overshoot で off-by-one がすり抜け)](../../raw/reviews/20260601T011012Z-pr-1222.md)
- [PR #1222 fix results (cycle 2) — python-inline を第 2 シグナルに固定し long-block を単独の結果決定要因にして 24/25 行境界を pin、`long-block(25)` ラベルまで assert、`>=25→>=26` / `25→24` 両 mutation で捕捉を実証](../../raw/fixes/20260601T011318Z-pr-1222.md)
- [PR #1246 review results (cycle 2) — 0 findings 収束を支えた mutation/revert test (実装末尾 exit 0 削除 → S-7 FAIL) の立証](../../raw/reviews/20260602T070147Z-pr-1246.md)
- [PR #1246 fix results — CLEANED 経路 + 内側 mktemp 失敗の exit 0 を pin する S-7 の mktemp 引数分岐 shim 技法](../../raw/fixes/20260602T065355Z-pr-1246.md)
- [PR #1266 review results — reviewer 2 名が READ-ONLY 制約下の detached worktree mutation test を独立実施し新規 self-test 87 アサーションの behavioral 性を実証、0 findings / 1 cycle mergeable](../../raw/reviews/20260604T032559Z-pr-1266.md)
- [PR #1270 review results — worktree-only mutation 6 種で TC-6 検出力を実証、mutation 検証の過程で TC-6 remediation 指示と TC-1 の latent SoT guidance 矛盾を発見 (0 findings / 1 cycle mergeable)](../../raw/reviews/20260604T160823Z-pr-1270.md)
- [PR #1279 review results (cycle 2) — コメント訂正のみの fix に対し mutation 2 種 (fix 行削除 → TC-16 の 3 assert FAIL / --c0-only → default 改変 → 日本語保持 pin FAIL) で test の弁別力を再実証、前 cycle nit (sanity pin コメント精度) も同実測で自然消滅 (0 findings / 2 cycle 収束)](../../raw/reviews/20260605T091117Z-pr-1279.md)
- [PR #1281 fix results — vacuous assertion を関数抽出 + 境界行 extract で非 vacuous 化し、隔離 worktree での核心行削除 mutation (2 assertion fail) を commit 前に実施して runtime 実証](../../raw/fixes/20260605T181146Z-pr-1281.md)
- [PR #1281 review results (cycle 2) — test reviewer が fix 側 mutation claim を独立に設計した 4 種 mutation (各エスケープ行個別削除 + neutralize→cat 置換) で再実証、観測数差異は「非 vacuous」核心一致で合意 (0 findings / 2 cycle 収束)](../../raw/reviews/20260605T182035Z-pr-1281-cycle2.md)
- [PR #1283 review results — TC-116 vacuous 教訓を設計段階から反映した fail-closed テスト追加、4 reviewer 独立 mutation 実験で非 vacuous 性を実証、fake tr 引数精密スコープで巻き添えゼロ (0 findings / 1 cycle mergeable)](../../raw/reviews/20260606T002556Z-pr-1283.md)
- [PR #1295 review results — テストのみ変更 follow-up PR で新規 assert 4 件の非 vacuous 性を worktree-only mutation で立証、path 集合差分化の双方向 mutation 検証 + jq fault-injection shim の `-s` 完全一致 + scenario gate 二重ガード (0 findings / 1 cycle mergeable)](../../raw/reviews/20260606T171726Z-pr-1295.md)
- [PR #1301 review results — symmetry test 保護対象拡張のテストのみ変更 PR で新 helper assert_single_create_caller の (a)(b)(c) 3 assertion を 3 reviewer が worktree-isolated mutation (nested cmdsub 退行 + flag-style --title 退行) で teeth 立証、既存 TC との byte-identical 対称性照合を検証手段に併設 (0 findings / 全 4 レビュアー可で初回 mergeable)](../../raw/reviews/20260608T032933Z-pr-1301.md)
- [PR #1317 review results — inline-gh-create-title の開始引用符 alternation `["']` の single-quote branch を pin する TC-026/027/028 を test/error-handling reviewer が独立 mutation (`["']`→`["]` で TC-026 のみ FAIL / `$` 除外撤去で TC-018+TC-027 FAIL) で非 vacuous 立証、Asymmetric Fix Transcription の test 側監査も適用 (0 findings / 1 cycle mergeable)](../../raw/reviews/20260609T052136Z-pr-1317.md)
- [PR #1319 review results — review-source-resolve error 経路 assertion 追加で、negative assertion (`assert_err_lacks STALE`) の非 vacuity を match/mismatch 差分ペア構造 + all-zeros SHA 決定性で立証 (能動 mutation を READ-ONLY guard で回せない構造的代替)、reason 文字列の実装 emit byte 一致照合を test 正しさの核心と確認 (4 reviewer 可 / 0 findings / 1 cycle mergeable)](../../raw/reviews/20260609T085210Z-pr-1319.md)
- [PR #1321 review results — dedup assertion の非 vacuity を重複 fixture (p2 に p1 と同一の正規化済み ref) で担保し `sort -u`→`cat` mutation で count=2 FAIL を立証、section-scoped 静的契約 test (TC-14) の helper rename を empty-section fail で検出する rename-detection 機構を io_error→true / rename 2 mutation で実証 (test/code-quality 2 reviewer 可 / 0 findings / 1 cycle mergeable)](../../raw/reviews/20260609T115303Z-pr-1321.md)
- [PR #1337 review results (cycle 2) — TC-3 の >&2 同一行条件 sweep が代入行 idiom を検出できない盲点を author mutation で実証し fail-closed 全行 sweep + allowlist へ pivot、4 reviewer が独立 worktree-only mutation で TC-3/TC-4/TC-5/TC-025 の非 vacuity を再実証 (0 findings / 2 cycle mergeable)](../../raw/reviews/20260610T003030Z-pr-1337-c2.md)
- [PR #1663 review results — 回帰防止テストの grep token が旧コードの remediation hint 文言にもマッチし修正前でも PASS する non-discriminating 構造を指摘、修正パス固有 literal への絞り込みと修正前 base revert test での discrimination 実証を canonical 対策化 (適用 24)](../../raw/reviews/20260626T031814Z-pr-1663.md)
- [PR #1736 review results (cycle 2) — timeout bypass 対策テストで、state-mutating payload (checkout) が cap 有無に関わらず deny され vacuous になる問題と、構造 pin をコメントでなく実行文 (trap 行出現回数) で行う指摘 (F-04/F-05 MEDIUM)](../../raw/reviews/20260703T073719Z-pr-1736.md)
- [PR #1736 fix results (cycle 2) — read-only verb payload で allow→deny flip を作り mutation 帰属を成立させる / huge command は --rawfile で argv 制限回避](../../raw/fixes/20260703T075749Z-pr-1736.md)
- [PR #1736 fix results (cycle 3) — vacuous の 2 典型 (独立 deny される verb / `<<` 先頭で `%%<<*` fast path) を read-only heredoc payload で非 vacuous 化、guard 除去 mutant で FAIL 実証、inert 共有 tag 代入の除去](../../raw/fixes/20260703T081555Z-pr-1736.md)
- [PR #1742 review results (cycle 1) — CAS 二段ガード + PID 再利用検出の bash 実装レビューで、TC-14/15 の platform skip ガード左右対称 / SPEC over-claim 回避 / no-flock 経路カバレッジを指摘 (適用 26)](../../raw/reviews/20260703T140345Z-pr-1742.md)
- [PR #1742 review results (cycle 2) — cycle 1 修正 3 件を該当 reviewer が mutation 検証まで含めて解消確認、対称化 AC の test pin 強度非対称 (汎用 exit≠0 vs warning 文言 pin) を検出](../../raw/reviews/20260703T142317Z-pr-1742.md)
- [PR #1742 review results (cycle 3) — CAS の防御的 revive 分岐が CLI 経由で決定的再現不能・未到達であり「TC-14 でカバー」コメントが mutation で削除しても green の vacuous over-claim になる問題を検出、未到達の正直な文書化 (no-silent-caps) を提示](../../raw/reviews/20260703T144050Z-pr-1742.md)
- [PR #1742 review results (cycle 4/re-review) — 「行実行順序」と「mutation-isolated coverage」の混同による over-claim を実装トレースで確定、2 ガードが論理和構成で単独 isolate は成立しないことを mutation で立証、コメント軟化 fix の正確性を再検証し 0 findings 収束 (適用 26 の核)](../../raw/reviews/20260703T153807Z-pr-1742.md)
- [PR #1742 fix results — TC-16 コメントの mutation-coverage over-claim をコメント軟化 (実行コード不変) で解消 / 未到達分岐の正直な文書化 / 対称 skip ガード / SPEC 条件付き表現による over-claim 回避 の 4 fix パターン](../../raw/fixes/20260703T154111Z-pr-1742.md)
- [PR #1921 review results — 2 段構え fallback の fallback 側成功パス未カバーを mutation (fallback を false 置換 → 全緑) で実測、echo のみの skip 実装によるカウンタ観測不能パターンも併せて検出 (test reviewer 単独 findings / 4 reviewer 中 3 名 0 findings)](../../raw/reviews/20260719T235117Z-pr-1921.md)
- [PR #1969 cycle 1 review — 非 git ディレクトリのテストフィクスチャが対象コマンドの git 早期 exit 経路を素通りし stdout 非汚染検証が false positive になる問題を mutation testing で発覚](../../raw/reviews/20260722T050800Z-pr-1969.md)
- [PR #1969 cycle 1 fix — git 実フィクスチャ + TMPDIR 隔離への統一、mutation testing で teeth の有無を検証する習慣の適用](../../raw/fixes/20260722T051500Z-pr-1969.md)
- [PR #1969 cycle 2 fix — 新規防御ロジック向けテストの teeth 不足 (旧バグでも red にならない観測点を選んでいた) を mutation testing で発見・観測点を選び直し](../../raw/fixes/20260722T054112Z-pr-1969-cycle2.md)
- [PR #1969 cycle 4 review — test の pass-message が実際の assertion coverage より多くを主張 (overclaim) する問題を mutation testing で検出](../../raw/reviews/20260722T063747Z-pr-1969.md)
- [PR #1969 cycle 4 fix — pass-message の文言を実際の assertion coverage に合わせて narrowing (新規 assertion 追加ではなく文言修正で解消)](../../raw/fixes/20260722T064426Z-pr-1969.md)
- [PR #1970 review results (cycle 3, mergeable) — 隔離 scratchpad での mutation test により TC-15 の実効性を実証 (適用 29)](../../raw/reviews/20260722T122232Z-pr-1970-cycle3.md)
- [PR #1972 review results — テストのみ変更 (branch_remote 経路の回帰テスト追加) で 4 reviewer 全員が独立にスクラッチコピーへの mutation で新規テストの検出力を実証、0 findings / 1 cycle mergeable](../../raw/reviews/20260722T133807Z-pr-1972.md)
- [PR #1974 fix results (cycle 2) — producer 側 (recorder + guard) の discriminating assert 欠如を安全ゲート剥がし mutation で実測、consumer 側のみのカバレッジでは無検知で通過することを確認 (適用 30)](../../raw/fixes/20260723T021111Z-pr-1974-cycle2.md)
- [PR #2003 review cycle 1 — 同一 PR 内で TC-6 (識別力あり) と TC-9 (false-positive) が分岐、2 レビュアーが隔離 worktree mutation で独立実証 (適用 31)](../../raw/reviews/20260724T070805Z-pr-2003.md)
- [PR #2003 review cycle 3 — 3 cycle 収束の最終検証と strictly additive availability framing の明文化 (適用 31)](../../raw/reviews/20260724T074215Z-pr-2003.md)
- [PR #2013 review cycle 3 — 守ると宣言した軸そのものが未 pin だった CRITICAL (適用 32)](../../raw/reviews/20260725T032345Z-pr-2013.md)
- [PR #2013 fix results (cycle 2) — 42 assertions 緑でも mutation を検出できない初版](../../raw/fixes/20260725T025323Z-pr-2013.md)
- [PR #2013 fix results (cycle 3) — 9 種 mutation を全て KILLED まで持っていった記録](../../raw/fixes/20260725T033607Z-pr-2013.md)
