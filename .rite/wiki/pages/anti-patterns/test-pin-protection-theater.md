---
title: "Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する"
domain: "anti-patterns"
created: "2026-04-24T14:55:00+00:00"
updated: "2026-05-06T04:00:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260424T095915Z-pr-655-cycle6.md"
  - type: "reviews"
    ref: "raw/reviews/20260424T085837Z-pr-655.md"
  - type: "reviews"
    ref: "raw/reviews/20260501T140844Z-pr-759.md"
  - type: "reviews"
    ref: "raw/reviews/20260505T185107Z-pr-848.md"
  - type: "fixes"
    ref: "raw/fixes/20260505T185354Z-pr-848.md"
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

### Self-application: Wiki 経験則を作った PR 自身が踏むケース (PR #759 で実測)

PR #759 (Issue #684 hooks test スイート) では `migrate-flow-state.test.sh` TC-20 が **本 anti-pattern を test 自身が踏んでいる** 事例として cross-validation で検出された。canonical 防御策を SoT 化した経験則ページを参照しつつも、test 実装で同じ anti-pattern を再演する self-application failure mode:

```bash
# TC-20 旧実装 (PR #759 cycle 1 で HIGH 検出)
canonical_phrase=".rite-flow-state.legacy.*"
exception_token="-not -name"

if grep -qF -- "$exception_token" "$session_start" \
    && grep -qF -- "$canonical_phrase" "$session_start"; then
  _assert "TC-20.session-start-has-legacy-exception" "true"
fi
```

問題: 2 つの token を独立した `grep -qF` で検査するため、refactor で実 find 行を削除しても **コメント中に同 token が残っていれば PASS** する。session-start.sh の旧実装ではコメント行と実 find 行の両方に `-not -name` と `.rite-flow-state.legacy.*` が出現しており、test は drift 保護として機能しない。

canonical fix (combined regex で実コード行に絞る):

```bash
# combined regex: `find ` で始まる行に絞り、両 token が同一行内に併記されていることを assert
combined_regex='find .* -not -name [^[:space:]]*\.rite-flow-state\.legacy\.\*'
if grep -qE -- "$combined_regex" "$session_start"; then
  _assert "TC-20.session-start-has-legacy-exception" "true"
fi
```

これにより refactor で実 find 行を削除して comment だけ残しても TC-20 は **fail** し、本来の drift 検出機能を取り戻す。

self-application failure mode の教訓: 経験則ページを書くだけでは self-application は防げない。**新規 test 追加 PR の reviewer は『本 PR の test 自身が anti-pattern を踏んでいないか』を mechanical に verify する step を必須化する** (mutation test を independent reviewer が走らせるなど)。

### Wording-revision drift sub-pattern (PR #848 で実測)

本 anti-pattern は「pin claim の factual accuracy gap」(coverage 角度) と「pin が一切失敗しない silent pass」(false-sense-of-security 角度) を主に扱うが、PR #848 で **対称的な失敗モード** が顕在化した: pin が壊れていなかった (`grep -q "boolean リテラル値"` は実 WARNING text に対して有効に機能していた) が、**pin される側 (本文) を改訂したときに同期が取れない asymmetric drift** によって CI red が確実発火する。

具体例: `state-read.sh:246` の Mechanical guard WARNING を docstring SoT 統一 refactor で短縮した:

```diff
- echo "WARNING: --default の値が boolean リテラル値です。caller 側で..." >&2
+ echo "WARNING: --default の値が boolean リテラルです。caller 側は..." >&2
```

`tests/state-read.test.sh:448/462` の `grep -q "boolean リテラル値"` は本文側の「リテラル値」→「リテラル」短縮で外れ、TC-14.3.a/b が確定的 FAIL。CI red を 2 reviewer (code-quality + error-handling) が cross-validate で CRITICAL 検出。

差分:

| Sub-pattern | 検出契機 | mutation test 結果 | 修復方向 |
|-------------|---------|------------------|---------|
| Protection theater (claim-actual gap) | mutation test の silent PASS (本来 FAIL すべき) | PASS=25 FAIL=0 (false negative) | pin claim と実 assert の数を一致させる、行番号を semantic name に |
| Wording-revision drift (sync asymmetric) | CI red の確定発火 (本来 PASS すべき) | PASS=N-2 FAIL=2 (true positive) | 本文側を test 互換の語に復元 / docstring に「文言改訂時の test 同期義務」を明記 |

両 sub-pattern は test 文字列依存リスクを共有するが surface は対称的: 前者は「test が壊れているのに気付かない」、後者は「実装を直したら test が壊れる」。

#### 修正戦略の選択 (PR #848)

PR #848 では 3 戦略を比較し WARNING 側に「リテラル値」を復元する戦略 1 を採用:

| 戦略 | 内容 | 採否 | 理由 |
|------|------|------|------|
| 1 | WARNING に「リテラル値」を復元 (test pin 側は触らない) | **採用** | (a) 自然な日本語表現を保てる、(b) test の false-positive guard 文字列同時更新が不要、(c) mutation kill power を維持 |
| 2 | test pin を「boolean リテラル」に短縮 | non-採用 | test 側の false-positive guard も同時更新する scope 拡大 |
| 3 | TAG 文字列を定数化して test と本文を decouple | non-採用 | 設計改善だが Issue #842 の SoT 統一スコープ外 |

戦略 1 の妥当性は cross-validation 効果で実測される: code-quality (CRITICAL) + error-handling (HIGH) の 2 reviewer 独立検出により、CI red を確定させた状態でマージ承認される silent regression を防げた。

#### 防止策 (Wording-revision drift サブカテゴリ)

1. **文言改訂時の test pin 同期義務を docstring に明記する**: WARNING や ERROR 文言を持つ helper では「文言改訂時に `tests/<helper>.test.sh` の `grep_q` pattern も同時更新する」を docstring に記述する (Issue #842 の SoT 統一 refactor で本義務を docstring に組み込んだ)
2. **正規化された anchor pattern を test 側に採用する**: 文言の細部 drift に耐性を持たせるため、`grep -q "boolean リテラル値です。"` ではなく `grep -qE "boolean リテラル(値)?"` のような optional matcher にする、または `--default '$DEFAULT' は boolean` までの安定 prefix で pin する
3. **WARNING 文言改訂を含む PR では事前に `bash <test>.test.sh` を local で実行する**: PR 作成前の標準 verification gate として組み込む (CI red 顕在化を待たずに PR 内で fix できる)
4. **docstring SoT 統一 refactor では「caller pattern guidance を WARNING text に二重記載しない」だけでなく、「WARNING 文言と test pin の依存関係」も併せて明記する**: 二重記載を解消する scope と、test との依存関係を明示する scope を分離せず同 PR 内で 1 回で達成する (PR #848 cycle 1 fix で実装)

## 関連ページ

- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](fix-induced-drift-in-cumulative-defense.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](fix-comment-self-drift.md)

## ソース

- [PR #655 cycle 6 review — F-C6-03 protection theater 初明文化 + E-2 経験則](../../raw/reviews/20260424T095915Z-pr-655-cycle6.md)
- [PR #655 cycle 4 review — canonical phrase partial unification の blind spot 指摘](../../raw/reviews/20260424T085837Z-pr-655.md)
- [PR #848 review — WARNING 文言改訂時の test pin asymmetric drift (CRITICAL test regression cross-validated)](../../raw/reviews/20260505T185107Z-pr-848.md)
- [PR #848 fix — 修正戦略 3 択比較と docstring への test 同期義務 codify](../../raw/fixes/20260505T185354Z-pr-848.md)
