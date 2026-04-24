---
title: "Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する"
domain: "anti-patterns"
created: "2026-04-24T14:55:00+00:00"
updated: "2026-04-24T14:55:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260424T095915Z-pr-655-cycle6.md"
  - type: "reviews"
    ref: "raw/reviews/20260424T085837Z-pr-655.md"
tags: [test-pin, mutation-test, drift-check, protection-theater, canonical-phrase]
confidence: high
---

# Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する

## 概要

test ファイルのコメントが「cleanup arm 3 site (L383/L409/L412) の完全一致を pin」のように **複数 site pin** を claim していても、実際の `assert_contains` が 1 site しか pin していない (または canonical phrase が実在 site と factually 一致しない) 場合、regression 検出インフラへの信頼を破壊する false-sense-of-security。mutation test (`sed` で canonical phrase を 1 文字 drift させて test suite を再実行) で pin claim と実 catch 能力の gap を **empirical に実証**するのが canonical 検証手法。PR #655 cycle 6 F-C6-03 で実測。

## 詳細

### Protection theater の構造

test ファイルで canonical phrase を pin する目的は「実装側で canonical phrase が drift した時に test が FAIL する」こと。test コメントはその protection scope を読者に伝える contract として機能する。

problematic pattern:

```bash
# Test 2 で canonical phrase を pin: cleanup arm 3 site (L383/L409/L412) の完全一致
assert_contains "Test 2 stderr contains canonical phrase" \
  "the trailing position of the final list item of Phase 5.2 (ordered list)" \
  "$STDERR_CONTENT"
```

このコメントは「3 site の drift 検出」を claim するが:

- `assert_contains` は Test 2 (cleanup_post_ingest primary HINT) の stderr だけを scan
- L383 (cleanup_pre_ingest arm) や L412 vs L415 (escalation vs primary) の drift は catch しない
- mutation test で `sed -i 's|final list item of Phase 5.2 (ordered list)|final list item|g' stop-guard.sh` すると PASS=25 FAIL=0 = silent pass

**test インフラが「防いでいる」と思わせながら実は 1 site しか防いでいない**。fix 済みに見えて再発する cycle 6 型 regression の温床。

### Factual accuracy の追加 layer

cycle 6 F-C6-03 では更に深い問題が発覚:

- test コメントが主張する行番号 `(L383/L409/L412)` のうち **L409 は canonical phrase を含まない boundary comment 行** だった
- 実在 site は L383 (primary_pre) / L412 (primary_post) / L415 (escalation) の 3 箇所
- pin claim は empirical に factual error だが、test 実行は Pass (1 site 検証のため)、コメント読者は drift 保護を誤信

pin claim と実在 site の factual accuracy は独立して verify する必要がある。

### Mutation test による empirical 検証

canonical な検証手順:

```bash
# 1. baseline 取得
bash plugins/rite/hooks/tests/stop-guard-cleanup.test.sh 2>&1 | tail -3
# → PASS=28 FAIL=0

# 2. canonical phrase を 1 文字 drift
sed -i 's|final list item of Phase 5.2 (ordered list)|final list item|g' plugins/rite/hooks/stop-guard.sh

# 3. test 再実行
bash plugins/rite/hooks/tests/stop-guard-cleanup.test.sh 2>&1 | tail -3
# 期待: PASS=N FAIL=M (M >= 1 = drift 検出成功)
# 実測: PASS=25 FAIL=0 (false positive = protection theater)

# 4. baseline 復元
git checkout plugins/rite/hooks/stop-guard.sh
```

複数 site mutation を個別に実施することで:

- L383 drift → どの Test が catch するか
- L412 drift → どの Test が catch するか
- L415 drift → どの Test が catch するか

の scenario breakdown を empirical 確認できる。pin claim の信憑性を「読者信頼」ではなく「mutation test PASS/FAIL 差分」で担保する pattern。PR #655 cycle 11 では L383/L412/L415 の 3 scenario を独立に mutation + 再実行し、factual accuracy を commit body で明示追跡した (cycle 9 の scope 拡大型 fix で F-C10-04 regression を生んだ教訓から、cycle 11 は comment-only edit の minimal fix にスコープ制限)。

### 防止策

1. **pin claim のコメントは実 assert と exact match 検証する**: 「N site pin」と書くなら `assert_contains` 呼び出しを N 回配置するか、N 回分の stderr を scan する設計にする
2. **実在 site を grep で検証する**: コメントに書く行番号参照はコミット前に `grep -n "canonical phrase" file.sh` で実 line を確認する (factual accuracy)
3. **mutation test を review プロトコルに組み込む**: `sed` で 1 文字 drift → test suite 再実行 → PASS/FAIL 差分確認の 3 step を independent reviewer が実施する
4. **canonical phrase は arm-wide に適用する**: sibling arm (cleanup vs ingest / pre vs post) の片側だけで unify すると drift が凍結するため、arm 全体を scope とする (関連: [Canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md))
5. **line 番号 literal を test コメントから排除する**: 実在 site を semantic name (`primary_pre_ingest HINT` / `primary_post_ingest HINT` / `post_ingest escalation HINT`) で参照することで、行番号 drift の factual error 経路自体を消す (PR #617 規約の test 層への拡張)

### 累積対策 PR の特性

Protection theater は「cumulative defense」型 PR (同種 regression への累積対策) で特に顕在化する。PR #655 は Issue #652 = #604/#561 系の turn-boundary 累積対策 12 回目で、cycle 6 で初めて F-C6-03 として明文化された。[累積対策 PR の review-fix loop で fix 自体が drift を導入する](fix-induced-drift-in-cumulative-defense.md) の fractal pattern の一部として扱うべき anti-pattern。

## 関連ページ

- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](fix-induced-drift-in-cumulative-defense.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](fix-comment-self-drift.md)

## ソース

- [PR #655 cycle 6 review — F-C6-03 protection theater 初明文化 + E-2 経験則](../../raw/reviews/20260424T095915Z-pr-655-cycle6.md)
- [PR #655 cycle 4 review — canonical phrase partial unification の blind spot 指摘](../../raw/reviews/20260424T085837Z-pr-655.md)
