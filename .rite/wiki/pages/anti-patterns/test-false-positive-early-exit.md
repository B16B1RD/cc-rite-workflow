---
title: "Test が early exit 経路で silent pass する false-positive"
domain: "anti-patterns"
description: "`active=false` / `phase mismatch` 等の guard 条件で fixture が early exit するテストは、検証対象のロジックを一切実行しないまま rc=0 で pass する silent false-positive を生む。"
promote: rite-plugin
created: "2026-04-20T01:10:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260419T230924Z-pr-608-cycle5-review.md"
  - type: "fixes"
    resource: "raw/fixes/20260419T231616Z-pr-608-cycle6.md"
  - type: "reviews"
    resource: "raw/reviews/20260419T232356Z-pr-608-cycle7.md"
  - type: "fixes"
    resource: "raw/fixes/20260419T232739Z-pr-608-cycle8.md"
  - type: "reviews"
    resource: "raw/reviews/20260421T045816Z-pr-636.md"
  - type: "fixes"
    resource: "raw/fixes/20260421T050914Z-pr-636.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T045944Z-pr-3218.md"
tags: ["silent-false-pass", "fault-injection", "test-coverage"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T05:10:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T05:10:00Z" }
---

# Test が early exit 経路で silent pass する false-positive

## 概要

`active=false` / `phase mismatch` 等の guard 条件で fixture が early exit するテストは、検証対象のロジックを一切実行しないまま rc=0 で pass する silent false-positive を生む。regression を検出できない test が「green」として merge される経路になる。独立 counter (例: `diag log reason=not_active`) の assertion を追加するか、terminal acceptance 経由を強制する別 TC を active=true 版として分離するのが canonical。更に**新規 TC 追加時は同 cycle で修正された既知 false-positive TC の self-aware コメントを必ず参照する契約**を置く (same-cycle horizontal propagation)。

## 詳細

### 事象（cycle 5-8）

- **cycle 5**: TC-608-D が `active=false` early exit で抜ける構造のため、active 判定の regression を silent に pass させていた。core transition / fallback path 検証が抜け落ちた Test coverage gap パターン (3/9 findings)。
- **cycle 6**: TC-608-D を修正した際、新規 TC-608-E/F/G を追加したが、これらも rc assertion 不足で active 判定 regression を検出できない同型構造を silent に踏襲。
- **cycle 7**: reviewer が TC-608-E/F/G の false-positive を独立検出し、cycle 6 の fix が「同 cycle 過去 fix の self-aware コメントを参照しない」silent drift を起こしたことが判明。
- **cycle 8**: 修正パターンとして「新規 TC 追加時は同 cycle 過去 fix の self-aware コメントを必ず参照する契約」を確立。

### canonical 対策

1. **独立 counter assertion**: `active=false` early exit が発生した場合、`reason=not_active` 等の diag counter を increment し、TC 側でその counter を assert することで「early exit で抜けたこと自体」を検証する。
2. **HINT / body assertion の 2 段検証**: HINT 文言を前半 phrase + 後半 phrase の両方で grep する (例: `cleanup_pre_ingest` + `Phase 4.W.2`)。片側だけでは改変 regression を見逃す。
3. **active=true 版 TC の分離**: early exit 経路を通らない TC を別 case として作成し、terminal acceptance 経由を強制する。
4. **Same-cycle false-positive horizontal propagation 契約**: 同 cycle 内で過去 TC の false-positive が修正された場合、新規 TC 追加時に「この cycle で XXX の false-positive 修正があったので同型を避けている」と self-aware コメントで宣言する。これにより次 cycle reviewer が grep で drift を検出可能。

### 発動条件

- fixture が guard (active=false / phase mismatch / 機能 disable flag) で early exit する構造
- test の stdout / exit status だけで pass/fail を判定している
- 同 cycle に parity TC を複数追加している (sibling site 増殖 phase)

### review 側の検出手法

- TC が検証する「本体 logic」が実際に実行されるか fixture trace で確認
- 同 cycle の過去 fix コメントに「false-positive 修正」「guard で抜ける」等の self-aware 痕跡があれば parity TC も同型疑いで精査
- `rc=0` 以外の assertion (stderr content / diag counter / state file mutation) が存在するか確認

### Silent-false-pass via pre=post state の 3 条件拡張（cycle 5 の実測）

8 件目の累積対策 PR の cycle 5 review で発見された別系統の silent-false-pass pattern を追加する。subshell ベース test で以下 **3 条件** が揃うとスクリプトが一切実行されなくても事後条件が PASS する false-positive を形成する:

1. **stderr suppress**: `2>/dev/null` で subshell の stderr を握り潰している
2. **exit code 未検査**: `( ... ) || fail` を付けず subshell の非 0 exit を無視している
3. **pre-state = post-state の expected 値**: 例 — `error_count=2` → `error_count=2` 期待値で、script が動かなくても event=0 で PASS する

対策として、事後条件に「**変化する値**」(state transition を伴う field) を含める必要がある。例: `error_count=2` だけでなく `next_action` や `updated_at` など script 実行で変化するフィールドを assert することで「script が呼ばれた証跡」を検証する。

### Fault injection via PATH override (portable で root 不要)

mv / jq write 等の shell builtin やコマンド失敗を test で再現する canonical 手段:

```bash
# fake binary を作成し PATH を prepend
fake_bin_dir=$(mktemp -d)
cat > "$fake_bin_dir/mv" <<'EOF'
#!/bin/bash
echo "mv: simulated failure" >&2
exit 1
EOF
chmod +x "$fake_bin_dir/mv"
PATH="$fake_bin_dir:$PATH" bash target-script.sh
```

**利点**:

- `chmod -w` / `chattr +i` は root 権限や filesystem feature 依存で portable でない
- PATH override は POSIX / BSD / GNU 問わず動作し root 不要
- fake binary で exit code と stderr を完全制御でき、silent failure surface 化の test coverage を mechanical に取れる (TC-634-M/N で `error_count_mv_failed` diag log と flow-state-update.sh の mv failed stderr を verify)

### set -e + subshell exit-code 捕捉

`set -euo pipefail` 下で subshell が非 0 exit する test では以下のイディオムで rc を capture する:

```bash
rc=0  # 事前初期化が必須 (undefined variable で script kill を防ぐ)
( target_logic ) || rc=$?
```

rc を capture せずに `set -e` 下で subshell が失敗すると親 script が即座に kill される (debug が困難)。

### Line-number reference anti-pattern の test コメント対応

test fixture コメントで `file.sh L247-250` 形式の行番号参照を埋め込むと、refactor で silent drift する。canonical 対策:

- **semantic anchor**: "error_count atomic write 後 mv 失敗 path" のような意味論的参照
- **trailer convention**: `(line-number 参照を避ける理由は cycle 8 F-05 参照)` 形式の trailer を付記してリポジトリ内 convention を明示（cycle 5 で確立）

### sandbox の欠落による早期停止と、陰性 assert の陽性対照

複製した入口スクリプトを sandbox で走らせるテストでは、入口が呼ぶ依存（状態 helper や source する lib）が sandbox に無いと、検査を外しても本体は依存の欠落で手前に止まる。「ファイルを作らない」「出力しない」のような陰性 assert は、止まった理由を区別できないので常に緑になる。

- 観測点を「本体に入ったこと」そのものへ移す。本体が最初に呼ぶ外部コマンドを、呼ばれたら記録ファイルに追記するスタブにし、記録が無いことを assert する。その手前で読み込まれ、無ければ停止する依存は実物を置く。
- 陰性 assert は「正しい入力なら本体が記録点まで届く」前提に依存する。同じ sandbox に有効な入力を渡して記録ができることを確かめる陽性対照を置くと、依存が増えて空振りに戻ったときに検出できる。
- sandbox に部品を置く理由をコメントに書くときは、入口ごとの実際の呼び出し順に照らして確かめる。入口によって依存の読み込みと最初の外部呼び出しの順序が違うことがあり、欠けても縮退するだけで止まらない依存もある。
- 空振りの assert を消すときは、その assert のためだけに置いた準備行（fixture）も一緒に掃き出す。

## 関連ページ

- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [Test coverage gap 3/9 findings](../../raw/reviews/20260419T230924Z-pr-608-cycle5-review.md)
- [false-positive 早期露呈パターン](../../raw/fixes/20260419T231616Z-pr-608-cycle6.md)
- [TC-608-E/F/G false-positive 発見](../../raw/reviews/20260419T232356Z-pr-608-cycle7.md)
- [same-cycle 横展開契約](../../raw/fixes/20260419T232739Z-pr-608-cycle8.md)
- [silent-false-pass 3 条件 + line-number reference convention](../../raw/reviews/20260421T045816Z-pr-636.md)
- [silent-false-pass + PATH override fault injection + set -e subshell rc capture](../../raw/fixes/20260421T050914Z-pr-636.md)
- [sandbox の欠落で本体手前に止まる陰性 assert を呼び出し記録に置き換えたレビュー結果](../../raw/reviews/20260927T045944Z-pr-3218.md)
