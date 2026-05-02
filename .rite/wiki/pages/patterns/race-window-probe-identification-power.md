---
title: "Race window probe の identification power: outcome classification で test の真正性を担保する"
domain: "patterns"
created: "2026-05-02T00:30:00+09:00"
updated: "2026-05-02T09:25:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260501T140844Z-pr-759.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T000523Z-pr-761.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T001651Z-pr-761.md"
tags: [test-fidelity, race-window, sigkill, identification-power, mutation-testing, atomic-write, post-condition-redefinition]
confidence: high
---

# Race window probe の identification power: outcome classification で test の真正性を担保する

## 概要

SIGKILL を使った race window probe (write 中に kill して atomic invariant を verify する test) では、`sleep` が短すぎると kill が **write 開始前** に landing し、全 iter で state file が ENOENT (pre-write 状態) のまま「PASS」する false positive 経路を生む。production の atomic write が partial-write を残すバグに退化しても test が PASS するため、test の identification power がゼロになる dead code 化が起きる。canonical な防御は (a) sleep を race window が確実に当たるサイズ (0.05-0.1s) に拡大し、(b) iteration outcome を `pre / mid_or_temp / post / corrupt` に classify し、(c) `mid_or_temp + post >= 1` を assert することで race window が実際に当たったことを実証する設計。

## 詳細

### Protection theater の構造 (race window probe 版)

SIGKILL probe test の典型的な anti-pattern:

```bash
ITERATIONS=100
flake_partial=0
for i in $(seq 1 "$ITERATIONS"); do
  ( bash "$HOOK" create ... ) &
  pid=$!
  sleep 0.003  # ← 短すぎる
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if ! state_file_is_integral "$state_file"; then
    flake_partial=$((flake_partial + 1))
  fi
done

if [ "$flake_partial" -eq 0 ]; then
  pass "100 SIGKILL iterations all integral"
fi
```

このコードは「100 iter 全部で partial-write が起きなかった」を assert するが、実機計測 (Linux WSL2 / 6.6 kernel) では `sleep 0.003` で **全 100 iter 全部 hook write 完了前に SIGKILL が landing** し、`state_file_is_integral()` は 100% ENOENT 経路で early-return する。`jq empty "$state_file"` (実 atomic invariant check) は **dead code** として一度も実行されない。

→ production の `mv` が partial-write を残すバグに退化しても、test は「PASS=100/100」で commit を許可してしまう。**test インフラが「atomic invariant を守っている」と錯覚させながら、実は何も守っていない**。Wiki 経験則 [Test pin protection theater](../anti-patterns/test-pin-protection-theater.md) の race-window 版。

### Outcome classification による identification power 確保

canonical fix:

```bash
# Outcome classifier (4 状態)
classify_outcome() {
  local f="$1"
  if [ -e "$f" ]; then
    if jq empty "$f" 2>/dev/null; then
      echo "post"        # kill が write 完了後 = atomic write 成功
    else
      echo "corrupt"     # partial-write detected (must be 0)
    fi
  else
    if compgen -G "${f}.*" >/dev/null 2>&1; then
      echo "mid_or_temp" # tempfile 残存 = write 中 kill
    else
      echo "pre"         # state file 不在 = write 開始前 kill
    fi
  fi
}

ITERATIONS=50
sleep_duration=0.05  # ← race window が確実に当たるサイズ
flake_partial=0
pre_count=0
mid_or_temp_count=0
post_count=0

for i in $(seq 1 "$ITERATIONS"); do
  ( bash "$HOOK" create ... ) &
  pid=$!
  sleep "$sleep_duration"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  outcome=$(classify_outcome "$state_file")
  case "$outcome" in
    pre)         pre_count=$((pre_count + 1)) ;;
    mid_or_temp) mid_or_temp_count=$((mid_or_temp_count + 1)) ;;
    post)        post_count=$((post_count + 1)) ;;
    corrupt)     flake_partial=$((flake_partial + 1)) ;;
  esac
done

# (1) atomic invariant: partial-write は 0 件
if [ "$flake_partial" -eq 0 ]; then
  pass "${ITERATIONS} iter all integral (partial-write=0)"
fi

# (2) race window 実証: kill が write 中/後に当たった iter >= 1
race_hit=$((mid_or_temp_count + post_count))
if [ "$race_hit" -ge 1 ]; then
  pass "race window hit ${race_hit}/${ITERATIONS} (pre=$pre_count mid_or_temp=$mid_or_temp_count post=$post_count)"
else
  fail "race window 全 miss (pre=$pre_count) — sleep が短すぎ test dead code 化"
fi
```

これにより:
- production の atomic write が partial-write を残すバグに退化 → `flake_partial >= 1` で fail (true positive)
- sleep が短すぎる test infra bug → `race_hit == 0` で fail (test dead code 化を mechanical 検出)
- test が両 invariant を pass → atomic invariant が **実際に exercise された上で** 成立を実証

### 末尾の正常完了 iter で jq empty 経路を mechanical に通す

`pre / mid_or_temp / post` の outcome classification に加えて、ループ末尾に **kill しない 1 iter** を追加し、`jq empty` が確実に成功する pathway を mechanical に通すと defense-in-depth が強化される:

```bash
# ループ後に正常完了 iter
( cd "$TD" && bash "$HOOK" create ... )  # & を付けない、kill しない
state_file=$(state_path "$TD" "$SID" 2)
if [ -f "$state_file" ] && jq empty "$state_file" 2>/dev/null; then
  pass "kill しない iter で state file integral (jq empty 経路を mechanical に通過)"
else
  fail "kill しない iter で state file が integral でない"
fi
```

### sleep 値の適切な範囲

実機 (Linux WSL2 / kernel 6.6) での経験則:

| sleep 値 | 観測される outcome 分布 | 備考 |
|---------|----------------------|------|
| `0.001`-`0.005` | pre=100% | dead code 化 (race window 全 miss) |
| `0.05` | post=100% | hook write が 0.05s 内に完了 — race window 実証としては十分 (atomic mv path 直接実証) |
| `0.01`-`0.03` | mixed (pre/post 混在) | mid_or_temp 観測の確率を最大化したい場合の sweet spot 候補 |

ただし `mid_or_temp` 状態の観測は hook の write speed と sleep の timing 次第で flaky なため、**「mid_or_temp + post >= 1」を assert すれば post-only でも race window 実証として十分** (post 状態 = kill 後に jq parse 成功 = atomic write 完了 = production の atomic mv path が実 exercise された証拠)。

### Dead code 検出と Mutation testing の関係

本 pattern は [Mutation testing で test の真正性を empirical 検証する](mutation-testing-test-fidelity.md) の race-window 特化版。Mutation testing が「実装を mutate → test FAIL を確認」で identification power を verify するのに対し、本 pattern は「test の outcome 分布」自体を assert することで test 内部の dead code を mechanical 検出する。両者は補完関係:

| 検証観点 | Mutation testing | Outcome classification |
|---------|------------------|----------------------|
| 検出対象 | test assert の identification power | race window probe の dead code 化 |
| 検証方法 | 実装を sed で改変 → assert FAIL | iteration outcome を分類 → race-hit assert |
| 適用 timing | review 時 (manual) | test 実行時 (automated) |

PR #759 では atomic-write.test.sh TC-3 で Mutation testing (`mv → false`) を、TC-1/TC-4 で Outcome classification を併用する pair pattern が確立された。

### Post-condition への再定義: sleep 過大による M_mid 経路 dilute (PR #761 で実測)

`sleep 0.05` のような race window が確実に当たるサイズに拡大した結果、production sequence (e.g. 50ms) より sleep が長すぎ場合、観測 outcome が **post=100% に偏り M_mid (= mid_or_temp) 観測が environment-dependent な best-effort になる** ケースが発生する。PR #761 cycle 1 で test reviewer が MEDIUM として検出した sub-pattern。

| 状況 | sleep | 観測分布 | identification power |
|------|-------|---------|---------------------|
| sleep 過小 (`0.001`) | < write 開始 | pre=100% | dead code (race window 全 miss) |
| sleep 適正 (`0.01`-`0.03`) | write 中 | mid_or_temp / post 混在 | strong (mid_or_temp 観測の確率最大化) |
| sleep 過大 (`0.05` for 50ms hook) | > write 完了 | post=100% | partial (atomic mv path 直接実証は OK だが M_mid dead code 化) |

cycle 1 では「mid_or_post 観測経路を確保」と cover letter に記載していたが、production 50ms 時間軸で sleep 50ms は M_mid 観測が偶然依存になる。

**canonical 再定義** (PR #761 cycle 2 で formalize):

- assert 文言を `race-window-hit` から `atomic-completion-observed` に変更し、**post-condition (atomic 正常完了経路の観測) として再定義**する
- `mid+post >= 1` assert は「sleep 短縮による dead code 化を防ぐ post-condition」として位置付ける (mid_or_temp 単独観測は best-effort)
- True mid-state observation (= production sequence と非対称な timing で probe を打つ) は別 test (将来 Issue) で補強する旨を test 側コメントに明記

これにより sleep 値の environment 依存を許容しつつ、test の dead code 化リスクは構造的に防がれる。Mutation testing と Outcome classification の pair pattern は変更なく維持される。

### Test invariant 検証パターンの内部一貫性

PR #761 cycle 1 MEDIUM では同一 test 内で `byte_equal_violations` (loop 内 collected error counter で集計) と orphan reap (最終 iter のみ assert) が混在し、中盤 iter の zombie 化が検出不能だった。

**canonical 統一**: invariant 検証は loop 内 collected error counter (e.g. `unexpected_wait_rc_count`) で集計し、ループ外で全 iter assert する pattern に統一する:

```bash
# Anti-pattern: 最終 iter のみ assert (中盤 iter の異常を検出不能)
for i in $(seq 1 30); do
  ( ... ) &
  pid=$!
  ...
  wait "$pid"
done
[ "$?" -eq 0 ] || fail "wait failed"  # ← 30 iter 目しか見ていない

# Canonical: collected error counter (`byte_equal_violations` 同型)
unexpected_wait_rc_count=0
for i in $(seq 1 30); do
  ( ... ) &
  pid=$!
  ...
  wait "$pid"
  rc=$?
  case "$rc" in
    0|143) ;;  # 0=normal, 143=SIGTERM expected
    *) unexpected_wait_rc_count=$((unexpected_wait_rc_count + 1)) ;;
  esac
done
if [ "$unexpected_wait_rc_count" -eq 0 ]; then
  pass "全 iter zombie-free (unexpected_wait_rc_count=0)"
fi
```

[Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の test invariant pattern 版 sub-pattern として記録 — 同一 test 内で異なる pattern を混在させない契約。

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](mutation-testing-test-fidelity.md)
- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)

## ソース

- [PR #759 review — SIGKILL race window probe identification power 不足の HIGH×2 cross-validation](../../raw/reviews/20260501T140844Z-pr-759.md)
- [PR #761 cycle 1 review — sleep 過大による M_mid dilute MEDIUM + invariant pattern 不一致 MEDIUM](../../raw/reviews/20260502T000523Z-pr-761.md)
- [PR #761 cycle 2 re-review — post-condition 再定義の有効性 empirical 実証 (5 → 0 finding 収束)](../../raw/reviews/20260502T001651Z-pr-761.md)
