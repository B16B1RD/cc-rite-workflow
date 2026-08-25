---
title: "Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する"
domain: "anti-patterns"
created: "2026-04-24T14:55:00+00:00"
description: "test ファイルのコメントが「cleanup arm 3 site (L383/L409/L412) の完全一致を pin」のように **複数 site pin** を claim していても、実際の `assert_contains` が 1 site しか pin していない (または canonical phrase が実在 site と factually 一致しない) 場合、regression 検出インフラへの信頼を破壊する false-sense-of-security。"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260722T221143Z-pr-1973.md"
  - type: "reviews"
    resource: "raw/reviews/20260722T222828Z-pr-1973.md"
  - type: "fixes"
    resource: "raw/fixes/20260722T223211Z-pr-1973.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T095118Z-pr-2114.md"
  - type: "reviews"
    resource: "raw/reviews/20260424T095915Z-pr-655-cycle6.md"
  - type: "reviews"
    resource: "raw/reviews/20260424T085837Z-pr-655.md"
  - type: "reviews"
    resource: "raw/reviews/20260501T140844Z-pr-759.md"
  - type: "reviews"
    resource: "raw/reviews/20260505T185107Z-pr-848.md"
  - type: "fixes"
    resource: "raw/fixes/20260505T185354Z-pr-848.md"
  - type: "reviews"
    resource: "raw/reviews/20260509T014302Z-pr-909.md"
  - type: "fixes"
    resource: "raw/fixes/20260509T014534Z-pr-909.md"
  - type: "fixes"
    resource: "raw/fixes/20260509T015613Z-pr-909.md"
  - type: "reviews"
    resource: "raw/reviews/20260520T011841Z-pr-1066.md"
  - type: "fixes"
    resource: "raw/fixes/20260520T022118Z-pr-1066-cycle1.md"
  - type: "reviews"
    resource: "raw/reviews/20260520T061355Z-pr-1069.md"
  - type: "reviews"
    resource: "raw/reviews/20260801T003521Z-pr-2078.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T005429Z-pr-2078.md"
  - type: "reviews"
    resource: "raw/reviews/20260803T004941Z-pr-2094.md"
  - type: "reviews"
    resource: "raw/reviews/20260802T163111Z-pr-2094.md"
  - type: "reviews"
    resource: "raw/reviews/20260807T141527Z-pr-2137.md"
  - type: "reviews"
    resource: "raw/reviews/20260810T073435Z-pr-2229.md"
  - type: "reviews"
    resource: "raw/reviews/20260810T080754Z-pr-2229.md"
  - type: "fixes"
    resource: "raw/fixes/20260810T100637Z-pr-2229.md"
  - type: "reviews"
    resource: "raw/reviews/20260825T152548Z-pr-2361.md"
  - type: "fixes"
    resource: "raw/fixes/20260825T153842Z-pr-2361.md"
  - type: "fixes"
    resource: "raw/fixes/20260825T162042Z-pr-2361.md"
tags: [test-pin, mutation-test, drift-check, protection-theater, canonical-phrase, same-file-3-site-sync, subsidiary-claim-empirical-verification, cross-file-cross-site-coverage, multi-axis-mutation-verification, channel-collision, negative-control, twin-site-satisfaction, anchor-uniqueness, occurrence-count-pin]
confidence: high
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-25T16:50:12Z" }
verified:
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-25T16:50:12Z" }
---

# Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する

## 概要

test ファイルのコメントが「cleanup arm 3 site (L383/L409/L412) の完全一致を pin」のように **複数 site pin** を claim していても、実際の `assert_contains` が 1 site しか pin していない (または canonical phrase が実在 site と factually 一致しない) 場合、regression 検出インフラへの信頼を破壊する false-sense-of-security。mutation test (`sed` で canonical phrase を 1 文字 drift させて test suite を再実行) で pin claim と実 catch 能力の gap を **empirical に実証**するのが canonical 検証手法。起点事例の cycle 6 F-C6-03 で実測。

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

の scenario breakdown を empirical 確認できる。pin claim の信憑性を「読者信頼」ではなく「mutation test PASS/FAIL 差分」で担保する pattern。起点事例の cycle 11 では L383/L412/L415 の 3 scenario を独立に mutation + 再実行し、factual accuracy を commit body で明示追跡した (cycle 9 の scope 拡大型 fix で F-C10-04 regression を生んだ教訓から、cycle 11 は comment-only edit の minimal fix にスコープ制限)。

### 防止策

1. **pin claim のコメントは実 assert と exact match 検証する**: 「N site pin」と書くなら `assert_contains` 呼び出しを N 回配置するか、N 回分の stderr を scan する設計にする
2. **実在 site を grep で検証する**: コメントに書く行番号参照はコミット前に `grep -n "canonical phrase" file.sh` で実 line を確認する (factual accuracy)
3. **mutation test を review プロトコルに組み込む**: `sed` で 1 文字 drift → test suite 再実行 → PASS/FAIL 差分確認の 3 step を independent reviewer が実施する
4. **canonical phrase は arm-wide に適用する**: sibling arm (cleanup vs ingest / pre vs post) の片側だけで unify すると drift が凍結するため、arm 全体を scope とする (関連: [Canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md))
5. **line 番号 literal を test コメントから排除する**: 実在 site を semantic name (`primary_pre_ingest HINT` / `primary_post_ingest HINT` / `post_ingest escalation HINT`) で参照することで、行番号 drift の factual error 経路自体を消す（行番号 literal 禁止規約の test 層への拡張）

### 累積対策 PR の特性

Protection theater は「cumulative defense」型 PR (同種 regression への累積対策) で特に顕在化する。起点事例は turn-boundary 系 regression への累積対策 12 回目で、cycle 6 で初めて F-C6-03 として明文化された。[累積対策 PR の review-fix loop で fix 自体が drift を導入する](fix-induced-drift-in-cumulative-defense.md) の fractal pattern の一部として扱うべき anti-pattern。

### Self-application: Wiki 経験則を作った PR 自身が踏むケース

hooks test スイートを整備した PR では `migrate-flow-state.test.sh` TC-20 が **本 anti-pattern を test 自身が踏んでいる** 事例として cross-validation で検出された。canonical 防御策を SoT 化した経験則ページを参照しつつも、test 実装で同じ anti-pattern を再演する self-application failure mode:

```bash
# TC-20 旧実装 (cycle 1 で HIGH 検出)
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

### Wording-revision drift sub-pattern

本 anti-pattern は「pin claim の factual accuracy gap」(coverage 角度) と「pin が一切失敗しない silent pass」(false-sense-of-security 角度) を主に扱うが、wording-revision drift 事例で **対称的な失敗モード** が顕在化した: pin が壊れていなかった (`grep -q "boolean リテラル値"` は実 WARNING text に対して有効に機能していた) が、**pin される側 (本文) を改訂したときに同期が取れない asymmetric drift** によって CI red が確実発火する。

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

#### 修正戦略の選択

wording-revision drift 事例では 3 戦略を比較し WARNING 側に「リテラル値」を復元する戦略 1 を採用:

| 戦略 | 内容 | 採否 | 理由 |
|------|------|------|------|
| 1 | WARNING に「リテラル値」を復元 (test pin 側は触らない) | **採用** | (a) 自然な日本語表現を保てる、(b) test の false-positive guard 文字列同時更新が不要、(c) mutation kill power を維持 |
| 2 | test pin を「boolean リテラル」に短縮 | non-採用 | test 側の false-positive guard も同時更新する scope 拡大 |
| 3 | TAG 文字列を定数化して test と本文を decouple | non-採用 | 設計改善だが当該 Issue の SoT 統一スコープ外 |

戦略 1 の妥当性は cross-validation 効果で実測される: code-quality (CRITICAL) + error-handling (HIGH) の 2 reviewer 独立検出により、CI red を確定させた状態でマージ承認される silent regression を防げた。

#### 防止策 (Wording-revision drift サブカテゴリ)

1. **文言改訂時の test pin 同期義務を docstring に明記する**: WARNING や ERROR 文言を持つ helper では「文言改訂時に `tests/<helper>.test.sh` の `grep_q` pattern も同時更新する」を docstring に記述する（SoT 統一 refactor で本義務を docstring に組み込んだ）
2. **正規化された anchor pattern を test 側に採用する**: 文言の細部 drift に耐性を持たせるため、`grep -q "boolean リテラル値です。"` ではなく `grep -qE "boolean リテラル(値)?"` のような optional matcher にする、または `--default '$DEFAULT' は boolean` までの安定 prefix で pin する
3. **WARNING 文言改訂を含む PR では事前に `bash <test>.test.sh` を local で実行する**: PR 作成前の標準 verification gate として組み込む (CI red 顕在化を待たずに PR 内で fix できる)
4. **docstring SoT 統一 refactor では「caller pattern guidance を WARNING text に二重記載しない」だけでなく、「WARNING 文言と test pin の依存関係」も併せて明記する**: 二重記載を解消する scope と、test との依存関係を明示する scope を分離せず同 PR 内で 1 回で達成する（cycle 1 fix で実装）

### Same-file 3-site sync sub-pattern

wording-revision drift 事例で抽出された drift は cross-file (helper 本体 ↔ test pin) の asymmetric drift だったが、same-file 3-site 事例で **同一ファイル内の 3 site sync** に同型 pattern が発現することが実測された。`plugins/rite/hooks/tests/start-md-charter.test.sh` 内で:

- **site 1 (line 17)**: ファイル冒頭の「Assertions」一覧に `Mandatory After ≥ 30` という旧仕様の記述
- **site 2 (line 102-106)**: 実装 (heading-anchor 限定 regex + 閾値 17)
- **site 3 (inline comment)**: 実装直近のコメント (内訳 h3 14 + h4 3 = 17)

の 3 箇所が同一 invariant (heading 数 17 件) を表現するが、cycle 1 で line 17 が旧 `≥ 30` のまま残置 → reviewer が「冒頭サマリと実装のどちらが SoT か判断不能」状態を MEDIUM finding として検出。wording-revision drift 事例の cross-file asymmetric drift と surface は同一だが、scope が same-file に縮小しても **dead reference として後続 reviewer / 改修者を誤導する liability** が生じる。

#### 暗黙メンテナンスルール明文化（cycle 2 で追加）

3-site sync invariant が same-file 内に存在する場合、コメント末尾に **1 行の同期更新ルール明文化** を canonical 化する:

```bash
# heading 追加/削除時は内訳 (h3 N / h4 M / 合計 K) と閾値 `-ge K` / `>=K` を同期更新
mandatory_count=$(grep -oE '^#+ .*🚨 (Mandatory After|After )' "$START_MD" | wc -l | tr -d ' ')
if [ "$mandatory_count" -ge 17 ]; then
  pass "Lower: heading-anchor count >= 17 (actual=$mandatory_count)"
fi
```

暗黙ルールは drift 要因。`grep -nE '内訳|sync|同期更新'` で codified ルールの存在を grep 検証可能にすることで、改修者が「数値変更時の同期義務」を見落とす silent regression を構造的に防ぐ。本 codification は「暗黙メンテナンスルールの明文化」pattern の単一ファイル版 sub-application として位置付ける。

#### 副次的主張のファクト検証 (POSIX ERE empirical verification)

same-file 3-site 事例の cycle 2 F-02 で「`After [A-Za-z]` で `### 🚨 After-Review` (hyphen) の取りこぼしも防ぐ」という副次的主張がコメントに混入していたが、`After [A-Za-z]` は POSIX ERE で **literal 空白** を要求するため hyphen 形式にはマッチしない (実証: `echo "### 🚨 After-Review" | grep -oE '...After [A-Za-z]' → NO MATCH`)。検証なしの副次的主張は将来「守れているはず」誤前提を生み、後続 reviewer / 改修者の判断を誤らせる liability。

canonical pattern: 「将来的な X 取りこぼし防止」型の副次的主張を test pin / 実装コメントに書く際は、必ず POSIX ERE / regex engine の literal 動作で empirical 実証する。検証できない副次的主張は削除し「必要時に `After[ -][A-Za-z]` 等への拡張を検討」と open-ended に書き換える方が dead claim を残すよりも honest。

#### 累積対策

| Sub-pattern | scope | codify 方法 |
|-------------|-------|------------|
| Protection theater (claim-actual gap) | 任意 | mutation test の silent PASS 検出 |
| Wording-revision drift (cross-file asymmetric) | helper ↔ test pin | docstring に test 同期義務を明記 |
| **Same-file 3-site sync** | 同一ファイル内 | コメント末尾に sync ルールを 1 行明文化 |
| **副次的主張のファクト誤認** | 任意 | POSIX ERE / regex engine の literal 動作で empirical 検証 |

### Cross-site (cross-file) drift fix の test pin coverage gap sub-pattern

本 anti-pattern の既存 sub-pattern (Same-file 3-site sync) は同一ファイル内 3 site の drift をカバーするが、cross-site pin gap 事例で **cross-file の N-site 対称化 fix が test pin を 1 site のみに配置する** sub-pattern が顕在化した。3 reviewer (prompt-engineer + code-quality + test) が cross-validated HIGH として独立検出した high-confidence case。

#### 失敗の構造

cross-site pin gap 事例は post-compact.sh / start.md / start-finalize.md の 3-site cross-file に同一 regex 判別ロジック (gh CLI 実出力 `Could not resolve to a PullRequest` を `pr_deleted_or_inaccessible` で分類) を対称化する PR。初版 fix は:

- 実装: 3 site すべてに regex を追加
- test: `post-compact-reconciliation.test.sh` の 4 case (post-compact.sh 1 site のみ pin) を追加

| 観点 | 実装 | test |
|------|------|------|
| post-compact.sh | regex 追加 | literal pin + 旧 regex 削除 + positive case |
| start.md (Step 1.5) | regex 追加 | **pin 欠落** |
| start-finalize.md (Step 0) | regex 追加 | **pin 欠落** |

mutation test: start.md / start-finalize.md 側の regex を別 alternative に置換しても `post-compact-reconciliation.test.sh` は全 PASS → cross-file の同型 drift を一切検出できない state。本 PR の主目的「4-site 対称化」(narration、実 3-site) を test layer で担保できていない silent gap。

#### Same-file 3-site sync sub-pattern との差分

| Sub-pattern | scope | symmetry の単位 |
|-------------|-------|---------------|
| Same-file 3-site sync | 同一ファイル内 (`start-md-charter.test.sh` 内 3 箇所) | 同一 invariant を表現する複数 textual site |
| **Cross-file cross-site coverage** | 複数ファイル間 (post-compact.sh / start.md / start-finalize.md の 3 file) | 同型 logic が異なる file に対称配置されている cross-file site |

両者は test pin が「N site claim」と実 assert の数で乖離する point は共通だが、後者は cross-file 対称化 PR 特有の failure mode で、reviewer は cross-file impact check (各 file の test 存在を grep で網羅確認) を test 層に拡張する必要がある。

#### Canonical 対策

1. **Cross-site drift 解消 PR は test pin を全 sites 分独立に配置する**: 1-site pin で全 sites を担保する設計は protection theater。各 site の test target を独立 assertion として配置 (fix では 4 case → 18 case = 3 sites × 2 (literal pin + 旧 regex 削除) + positive 6 + negative 6 に拡張)
2. **cross-file 対称化 PR は test 層でも cross-file 対称化を verify**: PR diff に `-3 file +1 test` のようなパターンが現れたら reviewer は「test 1 file で 3 file の drift を担保できているか」を mechanical に check (test ファイル内の grep を実 logic 配置 file 数と比較)
3. **mutation test を sites ごと独立実行**: post-compact.sh の regex を mutate → どの test が catch するか、start.md の regex を mutate → どの test が catch するか、を独立に verify

#### 累積対策

本ページの sub-pattern 一覧を更新:

| Sub-pattern | scope | codify 方法 |
|-------------|-------|------------|
| Protection theater (claim-actual gap) | 任意 | mutation test の silent PASS 検出 |
| Wording-revision drift (cross-file asymmetric) | helper ↔ test pin | docstring に test 同期義務を明記 |
| Same-file 3-site sync | 同一ファイル内 | コメント末尾に sync ルールを 1 行明文化 |
| 副次的主張のファクト誤認 | 任意 | POSIX ERE / regex engine の literal 動作で empirical 検証 |
| **Cross-file cross-site coverage** | 複数ファイル間の同型 logic 対称化 | test pin を全 sites 分独立配置 + cross-file 対称化 PR の test diff を `-N file +1 test` パターンで reviewer check |

### 3-axis mutation verification の canonical 適用

後続 PR は本ページで codify した「Cross-file cross-site coverage」canonical fix model を **別の context (T-04e regex の docstring false-positive)** に再適用した case として位置付けられる。bug 構造は同型 — `assert_file_contains` が pattern `updated\)` で 4 hit (3 docstring + 1 case arm) し、actual case arm 削除しても docstring match で test pass し続ける silent guard。canonical fix は (1) anchor 化 (`^>[[:space:]]+<arm>\)` で blockquote prefix + 実 case arm に pin) + (2) cross-file 対称 coverage 追加 (ready.md Phase 4.2 への対称 assert) の 2 段。

新規貢献は **3-axis mutation verification** の明示化:

| 軸 | mutation 操作 | 期待結果 |
|----|--------------|---------|
| 1 | start-finalize.md の `>   updated)` を一時削除 | 対応する assert が FAIL → 復元後 PASS |
| 2 | ready.md の `>   updated)` を一時削除 | 対応する assert が FAIL → 復元後 PASS |
| 3 | start-finalize.md の docstring に `(status_result=updated)` を擬似挿入 | test PASS 維持 (false-positive 不発火) |

軸 1-2 は本ページ既出の正方向 mutation (drift 検出可否)、軸 3 は **逆方向 mutation** (docstring に擬似 case arm 文字列を挿入しても anchor 化により false-positive 不発火を verify) で、anchor 化の strictness を independent に検証する追加 axis。canonical な mutation 戦略は「正方向 + 逆方向」の両 axis を独立に check することで、anchor / pattern 設計の二重保証を成立させる。本 axis 追加は本ページ「Mutation test による empirical 検証」セクションの canonical 検証手順に上書きする拡張案として位置付ける。

#### 累積対策

| Sub-pattern | scope | codify 方法 |
|-------------|-------|------------|
| Protection theater (claim-actual gap) | 任意 | mutation test の silent PASS 検出 |
| Wording-revision drift (cross-file asymmetric) | helper ↔ test pin | docstring に test 同期義務を明記 |
| Same-file 3-site sync | 同一ファイル内 | コメント末尾に sync ルールを 1 行明文化 |
| 副次的主張のファクト誤認 | 任意 | POSIX ERE / regex engine の literal 動作で empirical 検証 |
| Cross-file cross-site coverage | 複数ファイル間の同型 logic 対称化 | test pin を全 sites 分独立配置 + cross-file 対称化 PR の test diff を `-N file +1 test` パターンで reviewer check |
| **3-axis mutation verification** | anchor 強化 + cross-file coverage を併用する fix | 正方向 mutation (各 site 削除で FAIL) + 逆方向 mutation (docstring 擬似挿入で PASS 維持 = anchor strictness verify) を独立 axis で実行 |

### Guard-logic-not-just-routing pin gap sub-pattern

本ページの既存 sub-pattern はいずれも「pin claim の site 数」または「pin claim の factual accuracy」の gap を扱うが、snapshot_hash() の実装方式を変更した PR では **pin テストが「ルーティングの存在」のみを検証し「ガードロジック自体の存在」を検証しない** という、より細かい粒度の gap が顕在化した。

markdown skill ファイル (`pr-review/SKILL.md` ステップ 4.0.A) の該当行が `_wth_raw=.*git-status-filtered` という正規表現で pin されていたが、これは「新規 helper へのルーティングが存在するか」だけを検証する。cycle 1 で追加された exit code ガード (`_wth_rc` チェック + WARNING) だけを部分的に revert しても (ルーティング行自体は残したまま) 、この pin は PASS し続ける — ガードロジックの有無を検出できない **partial revert blind spot**。cycle 3 review で test-reviewer が独立に検出し、2 つ目の pin (`_wth_rc.*-ne 0` で guard 自体の存在を検証) を追加することで解消した。

```bash
# ❌ 不十分: ルーティングの存在のみを pin (ガードロジックの有無を検出できない)
assert_grep_in_section "SKILL.md 4.0.A: ORIG_WTH routed through git-status-filtered.sh" \
  "$PR_REVIEW_SKILL" '^### 4\.0\.A ' '^### 4\.0\.W' '_wth_raw=.*git-status-filtered'

# ✅ OK: ガードロジック自体の存在も独立に pin する (2 本目の assert)
assert_grep_in_section "SKILL.md 4.0.A: filter failure guard present (WARNING + skip on non-zero exit)" \
  "$PR_REVIEW_SKILL" '^### 4\.0\.A ' '^### 4\.0\.W' '_wth_rc.*-ne 0'
```

### Non-exercising fixture sub-pattern: happy-path のみの fixture では実装差分が観測不可能

cycle 3 の capture-first fix (前掲) を守るための test helper `snapshot_hash()` も capture-first パターンに書き換えられたが、cycle 4 review で test-reviewer が **既存 4 テストケース (baseline/T-01/T-02/T-02b) がすべて clean tree (filter 出力が空文字列) のみを snapshot している**ことを検出した。capture-first (`$(...)` が末尾改行を strip する) と naive な direct-pipe (末尾改行を保持する) は、**入力が空文字列のときは出力も同一になる** ため、既存 fixture ではこの実装差分を観測できない — 実機検証で `snapshot_hash()` を direct-pipe に戻しても既存 11 assertion は全て PASS したままだった (dirty tree で異なる hash: `d801c2f6…` vs `629f80c2…` を実証)。

```bash
# ❌ 不十分: clean tree のみの fixture — capture-first と direct-pipe が区別不能
sbx0=$(make_sandbox)
wth0=$(snapshot_hash "$sbx0")  # 入力が空文字列 → capture-first も direct-pipe も同一 hash

# ✅ OK: dirty tree で snapshot する fixture を追加 (T-04) — 実装差分が観測可能になる
sbx5=$(make_sandbox)
( cd "$sbx5" && echo already-dirty >> a )  # 非空の filter 出力を作る
wth5=$(snapshot_hash "$sbx5")  # capture-first と direct-pipe で異なる hash になる入力
```

**教訓**: 「本番コードの実装方式変更を守る regression test」を書く際、fixture が **その実装方式の違いが observable になる入力** を最低 1 つ含んでいるかを確認する必要がある。空入力・no-op 入力のみの fixture は、実装方式に依らず同一結果を返すため、実装が正しいことを検証しているように見えて実際には検証していない (protection theater の一種)。

#### 累積対策

| Sub-pattern | scope | codify 方法 |
|-------------|-------|------------|
| Protection theater (claim-actual gap) | 任意 | mutation test の silent PASS 検出 |
| Wording-revision drift (cross-file asymmetric) | helper ↔ test pin | docstring に test 同期義務を明記 |
| Same-file 3-site sync | 同一ファイル内 | コメント末尾に sync ルールを 1 行明文化 |
| 副次的主張のファクト誤認 | 任意 | POSIX ERE / regex engine の literal 動作で empirical 検証 |
| Cross-file cross-site coverage | 複数ファイル間の同型 logic 対称化 | test pin を全 sites 分独立配置 + cross-file 対称化 PR の test diff を `-N file +1 test` パターンで reviewer check |
| 3-axis mutation verification | anchor 強化 + cross-file coverage を併用する fix | 正方向 mutation (各 site 削除で FAIL) + 逆方向 mutation (docstring 擬似挿入で PASS 維持 = anchor strictness verify) を独立 axis で実行 |
| **Guard-logic-not-just-routing pin gap** | 1 site 内の複数要素 (ルーティング vs ガードロジック) | ルーティングの pin とガードロジックの pin を別 assertion に分離配置し、partial revert を独立検出可能にする |
| **Non-exercising fixture** | fixture 設計 | 実装方式の違いが observable になる非空/非デフォルト入力を fixture に最低 1 つ含める |

### 期待値の `.*` ワイルドカードと、assert に使われない診断変数

pin を「張ったつもり」にする 2 つの具体形。どちらも同 PR で新設 gate に対して同時に発生した。

**1. 期待値に置いた `.*` は「そのフィールドは未検証」と同義。** sentinel が出ることは pin されるが、**正しい値を載せていること**は pin されない。値が後段 gate の判定入力そのものである場合、ワイルドカードは検査層の穴と等価になる。同型の弱化が過去に全 assertion green で生き延びた記録が同じテストファイルのコメントに残っていたにもかかわらず、新設 gate へは自動では引き継がれなかった。

**2. assert に使われない診断変数は「pin 済み」の誤った安心を生む。** 未使用変数は shellcheck の warning 帯に出るため、error-only の CI gate を通過して機械検出されない。直後に pass/fail を伴う if/else があると、読み手には検査が成立して見える。**削除するか実効化するかの二択**で、コメントだけ残すのが最悪。

### fixture の置き場所が実装の導出先と食い違うと assertion が恒真になる

実装が `${TMPDIR}` から path を導出するのに、fixture を `mktemp -d` 配下に置くと、実装がどう振る舞っても fixture 側のファイルは残る。結果「削除しない」assertion が**常に pass** する。**fixture は実装が実際に触る場所に置く**（`export TMPDIR="$TMP_ROOT"` のように導出元ごと隔離すると、fixture の式を変えずに塞げて後片付けも既存 trap に載る）。

## 関連ページ

- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](fix-induced-drift-in-cumulative-defense.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](fix-comment-self-drift.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](asymmetric-fix-transcription.md)

## ソース

- [PR #655 cycle 6 review — F-C6-03 protection theater 初明文化 + E-2 経験則](../../raw/reviews/20260424T095915Z-pr-655-cycle6.md)
- [PR #655 cycle 4 review — canonical phrase partial unification の blind spot 指摘](../../raw/reviews/20260424T085837Z-pr-655.md)
- [PR #848 review — WARNING 文言改訂時の test pin asymmetric drift (CRITICAL test regression cross-validated)](../../raw/reviews/20260505T185107Z-pr-848.md)
- [PR #848 fix — 修正戦略 3 択比較と docstring への test 同期義務 codify](../../raw/fixes/20260505T185354Z-pr-848.md)
- [PR #909 review (cycle 1) — same-file 3-site sync drift / regex 副次的主張ファクト誤認 / 暗黙メンテナンスルール](../../raw/reviews/20260509T014302Z-pr-909.md)
- [PR #909 fix (cycle 1) — wording-revision drift 修正 + regex 対称性 (`After [A-Za-z]`)](../../raw/fixes/20260509T014534Z-pr-909.md)
- [PR #909 fix (cycle 2) — same-file 3-site dead reference 解消 + 副次的主張削除 + 暗黙メンテナンスルール明文化](../../raw/fixes/20260509T015613Z-pr-909.md)
- [PR #1066 review — cross-file 3-site 対称化 fix の test pin が 1-site only で cross-file coverage gap (3 reviewer cross-validated HIGH)](../../raw/reviews/20260520T011841Z-pr-1066.md)
- [PR #1066 cycle 1 fix — test を 3-site 拡張 (4-case → 18-case = 3 sites × 2 literal pin + positive 6 + negative 6) し cross-file 対称化を test 層で担保](../../raw/fixes/20260520T022118Z-pr-1066-cycle1.md)
- [PR #1069 review — T-04e anchor 化 + ready.md 対称 coverage + 3-axis mutation verification (正方向 2 軸 + 逆方向 docstring 擬似挿入 1 軸) で canonical fix model を別 context に再適用 (test-reviewer + code-quality-reviewer)](../../raw/reviews/20260520T061355Z-pr-1069.md)
- [PR #1973 cycle 4 review — test-reviewer が snapshot_hash() の全 fixture が clean tree のみで capture-first/direct-pipe の実装差分を observable にしていないと検出、実機検証で direct-pipe に戻しても既存 11 assertion が全 PASS することを実証](../../raw/reviews/20260722T222828Z-pr-1973.md)
- [PR #1973 cycle 4 fix (T-04: dirty tree snapshot fixture を追加し capture-first の実装差分を observable にする regression test を確立)](../../raw/fixes/20260722T223211Z-pr-1973.md)

## 変種: 静的 pin は「その行があるか」ではなく「その行が意図した構造で機能するか」を照合する

静的 pin テストの盲点は claim と assert の件数 gap だけではない。**照合 literal が構造上必須の文字を含んでいないと、「消失」は捕捉できても「drift」は素通りする。**

実例では、skill markdown の env 代入行を pin するテストが、**行末の行継続文字（`\`）を照合 literal に含めていなかった**。継続が落ちると env 代入列が非 export のシェル変数に退化し、次行のコマンドが env を 1 つも受け取らずに実行される — しかも `2>/dev/null || true` がその失敗を握り潰す。

| mutation | 静的 pin の検出 |
|---|---|
| 行を丸ごと削除 | ✅ 捕捉する |
| 行末の `\` 1 文字を削除 | ❌ 素通りする（literal 本体は一致したまま） |

**照合 literal には構造上必須の文字（行継続・閉じ括弧・区切り）を含める。** 「その行がある」ことの確認は、その行が機能することの確認にならない。

### 併発: 既定値と同値を assert する pin は kill power を持たない

同じ PR で、pin の別の空虚化も出ている。`loop_count: 0` の照合は、既定値が `0` である以上、carry-forward の有無を区別できず、carry-forward を丸ごと削除しても Green のままだった。**出力から原理的に判別できない性質（全入力で同じ出力になる等価変異）は、アサーションを強化しても捕捉できない。** 正しい対処は名前とコメントを実態に合わせる relabel であって、TC の追加ではない。

アサーション名に「直接確認」等の強い語を置くと、読み手は守られていると誤認する — これは本ページが扱う protection theater そのものである。

## 変種: assert の pattern が「同じチャネルに出る別の行」に当たっている

PR #2114 cycle 1 では、pin が守る対象を検査していない形が 3 件独立に検出された。いずれも「pin はある・mutation matrix も通っている」のに実質の検出力がゼロだった。

**(1) 部分文字列 match による vacuous assertion（チャネル衝突）**

`assert_grep ... "$ERR" 'mkdir'` は、検査したい「helper の stderr 転送行」ではなく、**同じ stderr に出る reason marker 行**（`reason=..._archive_mkdir_failure`）にも match していた。検査対象を削除しても green。

有効な修正は、転送経路に固有の形へ anchor すること — `sed 's/^/  /'` 由来の先頭 2 スペース + program-name prefix（`^  mkdir`）。

> assert の pattern を書いたら、**同じチャネル（同じファイル / 同じ stderr）に出る別の行に当たらないか**を必ず確認する。substring が別の marker 名の部分文字列になっているケースが最頻。

marker 名の包含関係も同型の罠である（`REMOTE_BRANCH_DELETE_FAILED` は `BRANCH_DELETE_FAILED` を部分文字列として含む）。`[CONTEXT] ` prefix 込みで行頭から一致させると構造的に衝突しない。

**(2) 文字クラスが対象集合を狭めすぎる静的 pin**

placeholder allowlist の抽出正規表現 `\{[^}[:space:]]+\}` は、**空白を含む placeholder**（`{finding full description}`）を 1 件も拾わなかった。pin が守る対象（全文の再掲載禁止）の反例が、pin の抽出 regex の**外側**に落ちていた。

**mutation matrix が「pin が拾える形の mutation」だけで構成されると、この抜けは mutation 実測でも露見しない**。負の対照（旧 regex + 同一 mutation で全 green）を取って初めて blind であることが示せる。

さらに、pin を広げた直後には逆向きの穴が空く — 文字クラスを `[^}]` へ広げたところ、今度は「allowlist 済みの placeholder だけで組んだ表外の再掲載」が捕捉できないことが判明した。**pin を広げたら、広げた後の allowlist 内要素だけで同じ違反を組めないかを必ず試す。**

**(3) 未到達分岐 + 件数申告の不一致**

helper の reason 語彙 4 種のうち 2 種に assertion が 0 本だった。うち 1 つは GNU coreutils の `mv -n` が衝突時に rc=1 を返すため Linux では**構造的に到達不能**で、BSD/macOS 専用の分岐が Linux CI では壊れたまま配布されうる。**platform 限定の assert は shim で置き換える（chmod では置き換えない）** — 実コマンドを chmod で失敗させる形は root leg で無効化され、避けようとした穴を別の軸で再生産する。

**(4) replaced pin にも負の対照が要る**

新規 pin だけでなく、**置換した pin** も「旧 pin ではこの mutation が見えなかった」ことを実測する。PR #2114 cycle 4 では、旧 `grep -cF` の caller pin が呼び出しのコメントアウトを素通しすること、旧 `^  mv` pin が BSD 相当の `mv`（rc=0 / 無 stderr）では mutation の有無に関わらず落ちることを、それぞれ shim で実測した。

## 変種: 実装の「適用箇所数」と test の「pin 箇所数」は別の数字

PR #2137 cycle 2 では、この gap を 3 reviewer（security / error-handling / application）が独立に最大の指摘として検出した。cycle 1 の指摘は「拒否経路の ERROR 文が生値をエコーする」で、fix は**実数 5 箇所すべてに `_marker_scrub` を適用して実装側は 5/5 で網羅的**だった。ところが追加した test が pin したのは 2 箇所だけで、**残り 3 箇所は scrub を外しても 61/61 green のまま生存した**。

生存が実害に届いた 1 箇所は `marker_get` の KEY 拒否経路である。interpolation の直後が `')。英数字と…` という日本語文字列だったため、`X<改行>[CONTEXT] ITERATE_CB=fire; x=` を渡すと列 0 に完全な偽 marker 行が立ち、`marker_get ITERATE_CB` が主値を `fire` として読み戻せた。「実装は全部直した」と「守られている」の距離が、そのまま偽 marker の成立余地になっていた。

> **fix の完了条件に「適用箇所数 == pin 箇所数」を含める。** 実装側の網羅を数えたら、同じ数え方で pin 側も数える。片側だけの網羅は [Asymmetric Fix Transcription](./asymmetric-fix-transcription.md) の test 軸での現れ方である。

### 併発: 新規 assertion 自身が空振り経路を持つ（counting assertion の 0 件）

同 cycle の fix が追加した偽造検出 assertion 2 本は `$(... 2>&1 >/dev/null)` で **stderr のみ**を捕捉し、`grep -c '^\[CONTEXT\] '` が 0 であることを assert していた。この形は「ERROR が出ない」も「ERROR が stdout へ移る」も合格として読む。実測では `>&2` を外すだけで green のままで、しかも `>&2` 除去と scrub 素通しを併せると偽 marker が **stdout**（marker 消費者が grep する側）へ実際に出るのに、その経路を名乗る当の assertion が pass した。

直前の commit が別のテストに対して「A count of 0 only means something if the pattern can reach 1」として positive/negative pin を入れたばかりで、その規約が新規 assertion へ伝播していなかった — 規約の伝播漏れもまた同 PR 内で起きる。

> **`grep -c ... == 0` を書くときは、同じ commit 内で pattern が 1 に到達しうることを in-suite で示す。** 到達性を示さない 0 件 assertion は、対象が存在しないのかチャネルが違うのかを区別できない（[absence pin は「base に存在・head に不在」の両側を単一行トークンで検証する](../patterns/absence-pin-base-present-head-absent-single-line.md) と同じ非 vacuous 性の要求）。

### 派生: 「fix したか」と「fix を守る test があるか」を分けて判定すると cycle が焼き直しにならない

同 cycle の 5 reviewer は全員が前 cycle の指摘 9 件すべてに FIXED / NOT_FIXED / PARTIAL を明示し、うち複数が **「実装は FIXED、pin は PARTIAL」**という分解を行った。この分解があると次 cycle の fix 対象が「もう一度同じ実装を直す」ではなく「テストを足す」に確定し、同一指摘の循環を避けられる。

### 併発: 新設コメントが同一ファイル内の契約を誤って引用する

同じ fix が新設したコメントは「emit の拒否経路は空値を契約違反として扱う」と書いたが、実測では `marker_emit KEY ""` は rc 0 で成功する（同ファイルの Contract 節が「値は空でよい」と明記し、テスト 3 本が固定している）。emit が拒否するのは空の **field 名**であって空の**値**ではない。新しいガードを入れる根拠として書かれた文だったため、**存在しない対称性を根拠にしている**状態になった。

> 「既存の X に合わせた」と書くときは X の実挙動を実測してから書く（[散文が引用する実装は文字一致・帰属・behavioral test の 3 点で裏取りする](../heuristics/prose-cited-implementation-behavioral-verification.md)）。

## 変種: pin の充足サイトが「守りたいサイト」と別でも緑になる（双子サイト成立）

ファイル全体を対象にした `assert_grep` は「ファイルのどこかにこの文字列がある」しか見ない。同じ文言が 2 サイトに存在すると、**片方が残っていれば pin は緑**になり、守ろうとしていた側を削除しても検出できない。

起点 PR ではこの形が 1 つの PR 内で 2 度、場所を変えて現れた。

1. 実装が同じ述語を「強制用」と「診断用」に複製 → ファイル全体 grep の pin が診断側の複製で満たされ、**強制側を削除しても緑**のまま通った
2. 上を修正した cycle で、同一文言を新設した doc pin にそのまま再現 — helper 側から消えた双子が doc 側へ移動しただけだった

**pin を足すときは「その pin が守ろうとしているサイトに固有の文字列か」を確認する**（区間限定 grep、またはサイト固有 prefix を含めた pattern）。

ただし修正の第一手は pin の書き方ではない。起点 PR は区間限定 grep へ賢くする案を試して **mutation で検出できないことを実測し棄却**、代わりに実装側の複製を消した（判定を 1 箇所にし、pass/fail も診断もそこから導く）。テストの検出力は複製が消えた結果として自然に回復した。

> **pin が効かないときは、pin の書き方より先に「pin する対象が 1 箇所か」を疑う。**

### 併発: 錨を「前置リテラル + 任意」で作ると同リテラルの別行が代替成立する

双子サイト問題への対策としてサイト固有化を図り、`Required JSON fields.*` のように**前置リテラル + `.*`** で錨を作ると、同じ前置リテラルを含む別行が pin を満たす。起点 PR では当該リテラルがファイル内に 3 行あり、**対象行から定義が消えても参照行が pin を満たす** mutation が実測で緑になった。

錨は「その行だけに一意な形」（行頭アンカー + コロン等）まで狭める。前置リテラルを足した時点で満足せず、**その pattern がファイル内で何行にマッチするかを数える**。

### 併発: 否定 assert は肯定側の双子と同一リテラルにしないと黙って空振りする

`assert_not_grep` による否定 assert は、対応する肯定 assert が同じリテラルを固定していないと、**実装側のリテラルを書き換えるだけで黙って空振りする**（禁止対象が存在しなくなるので常に緑）。否定 assert は必ず肯定側の双子と同一リテラルで書く。

さらに、禁止語 pin に文脈語を足して「誤発火を防ぐ」方向へ狭めると、**実際に除去された表記形を取りこぼす**ことがある（起点 PR では禁止語と文脈語の間に markdown 強調記号が挟まる形が抜け、5 名のレビュアーが「実証済みの検出力を未観測の誤発火リスクと交換している」と指摘した）。狭める判断の手順は [変更・削除の掃き出しは旧語彙・置換した条件式・別記法トークンまで広げる](../heuristics/change-sweep-spans-old-vocabulary-and-notations.md) を参照。

### 「この drift はテストが検出する」という宣言は実測してから書く

起点 PR では同一クラスの主張が 3 cycle 連続で形を変えて再発した — cycle 1 は「同期漏れ」、cycle 2 は「目視で検出する」と宣言した文がその宣言を追加した commit 自身で drift、cycle 3 は「契約テストが検出する」と格上げしたが実際に pin されていたのは **5 条件中 1 条件**だった。

> **検出保証を散文で宣言するのは、その保証が機械的に成立していることを実測してからにする。** 実測しないなら主張自体を書かない方が安全（起点 PR では 4 reviewer 全員が「主張を狭める」を推奨した）。

### Occurrence-count pin は一意行削除を素通りする

`assert_grep` の `count=2` のような部分文字列出現回数 pin は、同じ部分文字列が ERROR fence 分割や decoy HTML コメントで残れば、**producer echo・MUST 文・ACTION 行を消しても緑のまま通る**。consumer 側の部分文字列存在だけを見る pin も同型で、producer を削除しても consumer 残渣で合格する。

| mutation | count=2 / consumer 部分文字列 pin |
|---|---|
| producer echo 行を削除 | ❌ 素通り（consumer 側に同じ部分文字列が残る） |
| ACTION を cycle 1 の「7.1 へ戻れ」に差し替え | ❌ 素通り（他 fence に同じ語が残る） |
| consumer 3 欄を decoy HTML コメント化 | ❌ 素通り（count=2 は別サイトで満たされる） |

対策: 出現回数 pin をやめ、**一意の producer 行 / consumer 行 / ACTION 文**をそれぞれ独立に pin する。decoy（HTML コメント化、cycle 1 ACTION 差し替え）で緑が残る経路を mutation で塞ぐ。ERROR fence を経路ごとに分割したあとは、Routing 表の行数 pin を同時更新する。

## ソース（追記分）

- [PR #2094 review results (cycle 2) — 静的 pin が行継続文字を照合せず 1 文字 drift を素通り](../../raw/reviews/20260803T004941Z-pr-2094.md)
- [PR #2094 review results — load-bearing なコードコメントに対応するテストが無い](../../raw/reviews/20260802T163111Z-pr-2094.md)
- [PR #2114 review results — チャネル衝突による vacuous assertion と抽出 regex の外に落ちる反例](../../raw/reviews/20260805T095118Z-pr-2114.md)
- [PR #2137 review results (cycle 2) — 実装 5/5 適用に対し pin は 2/5、counting assertion 自身の空振り経路](../../raw/reviews/20260807T141527Z-pr-2137.md)
- [PR #2229 review results (cycle 2) — 述語の複製で pin が代替成立、否定 assert の空振り](../../raw/reviews/20260810T073435Z-pr-2229.md)
- [PR #2229 review results (cycle 3) — 双子サイトが doc 側へ移動、「契約テストが検出する」宣言が 5 条件中 1 条件](../../raw/reviews/20260810T080754Z-pr-2229.md)
- [PR #2229 fix results (cycle 4) — 前置リテラル錨が同リテラルの別行で代替成立](../../raw/fixes/20260810T100637Z-pr-2229.md)
- [PR #2361 review (cycle 1) — 8.0.2 ACTION 非対称と producer/fail-safe の pin 欠落](../../raw/reviews/20260825T152548Z-pr-2361.md)
- [PR #2361 fix (cycle 1) — producer / fail-safe を直接 pin し 8.0.2 ACTION を 7.7 と対称化](../../raw/fixes/20260825T153842Z-pr-2361.md)
- [PR #2361 fix (cycle 2) — count=2 部分文字列 pin を一意 pin に置換し decoy mutation で緑経路を塞ぐ](../../raw/fixes/20260825T162042Z-pr-2361.md)
