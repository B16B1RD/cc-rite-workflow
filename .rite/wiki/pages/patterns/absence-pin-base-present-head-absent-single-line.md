---
type: "patterns"
title: "absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する"
domain: "patterns"
description: "旧文面の除去を drift ガードとして固定する `assert_not_grep` pin には 2 つの構造的な罠がある。"
created: "2026-07-21T18:30:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260721T175725Z-pr-1959.md"
  - type: "fixes"
    resource: "raw/fixes/20260721T175931Z-pr-1959.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T093135Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260828T035444Z-pr-2426.md"
  - type: "fixes"
    resource: "raw/fixes/20260828T035827Z-pr-2426.md"
  - type: "reviews"
    resource: "raw/reviews/20260828T040534Z-pr-2426.md"
tags: ["assert-not-grep", "vacuous-pin", "ere-portability", "test-pin", "fixture-scope", "count-zero-assertion"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-28T13:10:00+09:00" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-08-28T13:10:00+09:00"
---

# absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する

## 概要

旧文面の除去を drift ガードとして固定する `assert_not_grep` pin には 2 つの構造的な罠がある。(1) **空虚 pin**: 2 語を `.*` で橋渡しするパターンは、旧文面が複数行に跨っていた場合、行指向 grep が一度もマッチせず「常に pass する幻のガード」になる（狙った regression を検出できない）。(2) **ERE 可搬性**: パターン内の literal `{...}` を未エスケープで書くと、GNU grep は不正 interval を literal 扱いするが、strict ERE 実装（macOS/BSD grep・ugrep）は regcomp エラー（rc=2）で拒否し suite を偽 FAIL させる。起点事例の cycle 3 で両方が runtime 実証つきで検出された。

## 詳細

### absence pin の正しい revert-test セマンティクス

absence pin が実効であるための条件は 2 つで、**両側を grep で確認してから commit する**:

1. **base に単一行トークンとして存在する** — revert（旧文面の復活）で pin が落ちることの保証。base に存在しないパターンは何も守っていない
2. **post-PR に不在である** — pin が現状で pass することの保証（新文面への誤マッチがないこと）

確認コマンド例:

```bash
git show develop:path/to/file.md | grep -E '<token>'   # base 存在 → 非空であること
grep -E '<token>' path/to/file.md                       # head 不在 → 空であること
```

### トークンの選び方

- 複数行に跨る旧文面には、**行を跨がない単一の識別トークン**（旧文面の先頭句など）を使う。「二行形・一行形いずれの regression も検出できる」トークンが理想
- `{placeholder}` literal を含む pin は `\{placeholder\}` とエスケープする（ERE で `\{` はリテラル中括弧。GNU / BSD / ugrep すべてで well-defined）

### 同一出力内の「件数 0」検証も片側では足りない

同じ非対称は時間軸（base / head）だけでなく**同一出力内**にも現れる。「望ましくない形が 0 件であること」を数える assertion は、**対象が正しい形で在る**場合と**対象が丸ごと無い**場合の両方で 0 を返す。

```bash
# 「原因行が列 0 に漏れていないこと」だけを見る — 原因行が一切出力されなくても 0 件で pass する
[ "$(printf '%s\n' "$err" | LC_ALL=C grep -cE '^[^ ].*/\.gitignore: ')" -ne 0 ] && fail
```

fail-loud 実装（WARNING + 原因の字下げ併記）を pin するつもりでこれだけを置くと、後日 cause 出力行が簡略化リファクタで消えても検出できない。**在ることの正の表明と、誤った位置に無いことの負の表明を対で置く**:

```bash
printf '%s\n' "$err" | LC_ALL=C grep -qE '^  .*/\.gitignore: ' || fail   # 在る（字下げ済み）
[ "$(printf '%s\n' "$err" | LC_ALL=C grep -cE '^[^ ].*/\.gitignore: ')" -ne 0 ] && fail  # 列 0 に無い
```

`LC_ALL=C` は必須。原因文字列は locale 依存の OS メッセージであり、UTF-8 locale の grep はデコードできない行を諦めて ASCII の anchor まで拾えなくなる。

**同じリポジトリに正しい先例があるなら、新規テストはその片側だけを写していないか確認する** — 起点事例では既存の同型 assertion が `indented>=1 && bare==0` を対で表明していたのに、新規テストが負側だけを写していた。先例探索を挟めばレビュー往復を 1 回減らせた。

### 検証は mutation で

pin の非空虚性は「守っている行をストリーム上で削除（または旧文面を復活）して pin が落ちるか」の mutation で実証できる。pass し続ける pin は theater。

mutation の実施者は**主張する側と独立**であることが望ましい。起点事例では reviewer が orchestrator 側の実測を鵜呑みにせず、修正前後の両方（旧テストで rc=0、新テストで rc=1）を自分で再現した。「直したこと」だけでなく「直す前は本当に検出できなかったこと」の再現が、修正の妥当性主張には要る。

正規表現の pin は**実バイト列**でも突き合わせる。`cat -A` 等で実際の出力を見て、意図した文字列に本当にマッチするかを確認しないと、regex そのものが空振りしていても mutation テストは「検出できた」と誤って報告しうる。

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin](../heuristics/universal-claim-prose-invalidated-by-path-addition.md)

> **補強**: 空虚 pin には**第 3 の軸**がある — 本ページが扱う「複数行に跨る旧文面」「ERE 未エスケープ」に加え、**その run の fixture に対象が存在しない**ケース。直前の run のログを読む形の `assert_not_grep` は、間に別のテストを挿入した瞬間に fixture がずれて恒真化する。対処（自前 run + positive control）は [assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる](../anti-patterns/assert-not-grep-vacuous-without-fixture-scope.md) を参照。

## ソース

- [空虚 pin + ERE 未エスケープの runtime 実証](../../raw/reviews/20260721T175725Z-pr-1959.md)
- [単一行トークン化 + エスケープ統一](../../raw/fixes/20260721T175931Z-pr-1959.md)
- [fixture スコープ由来の恒真化](../../raw/fixes/20260728T093135Z-pr-2038.md)
- [件数 0 検証が「正しく在る」と「丸ごと無い」を区別できない](../../raw/reviews/20260828T035444Z-pr-2426.md)
- [正負の対で pin + ミューテーション実測 + 先例探索](../../raw/fixes/20260828T035827Z-pr-2426.md)
- [解消検証の独立再現と実バイト列の確認](../../raw/reviews/20260828T040534Z-pr-2426.md)
