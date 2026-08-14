---
type: "patterns"
title: "静的 parity テストには到達性 pin と emit pin を対で足す — 出現数 + 行順だけでは semantics を守れない"
domain: "patterns"
promote: rite-plugin
description: "SKILL.md 内の markdown 埋め込み bash は実行テストできないため、grep ベースの静的 parity テスト（述語文字列の出現数 + 行の並び）で drift を pin する運用がある。"
created: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260726T150008Z-pr-2030-cycle5.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T161811Z-pr-2030.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T150940Z-pr-2030-cycle5.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T134912Z-pr-2030.md"
  - type: "reviews"
    resource: "raw/reviews/20260801T170512Z-pr-2070.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T171512Z-pr-2070.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-02T09:53:11+09:00" }
---

# 静的 parity テストには到達性 pin と emit pin を対で足す — 出現数 + 行順だけでは semantics を守れない

## 概要

SKILL.md 内の markdown 埋め込み bash は実行テストできないため、grep ベースの静的 parity テスト（述語文字列の出現数 + 行の並び）で drift を pin する運用がある。これは **site 間の不一致は検出するが semantics は守らない**。3 site を一貫して改修する mutation では素通りする（実測: 112 pass のまま正準形状が fallback に落ちた）。到達性と emit 内容を pin する 2 種を対で追加して初めて実用になる。

## 詳細

### 静的 parity テストが守れないもの

| 変異 | 出現数 + 行順 pin | 到達性 pin | emit pin |
|---|:--:|:--:|:--:|
| 1 site だけ書き換え（drift） | KILL | — | — |
| 3 site を一貫改修 | **生存** | — | KILL（emit 内容が変われば） |
| 直前の `elif` を常時 true にして死に分岐化 | **生存** | KILL | — |
| reason 文字列だけ差し替え | **生存** | — | KILL |
| `>&2` を外して stdout へ | **生存** | — | KILL |

### 追加する 2 種の pin

**到達性 pin**: 対象の述語行の**直前行**が live な分岐（`elif` / 条件付き）であることを assert する。直前の分岐を常時 true にする mutation で、対象が死に分岐化したことを検出できる。

```
# 例: 述語行の直前が elif であることを pin する
assert_grep "elif .*<先行条件>" "<対象ファイル>"
# かつ、対象述語がその直後にあることを行番号比較で pin する
```

**emit pin**: その分岐が出力する reason 語彙と出力先（`>&2`）を固定文字列で assert する。

```
assert_grep 'reason=<canonical-reason-value>' "<対象ファイル>"
assert_grep '<診断メッセージの固定部分>" >&2' "<対象ファイル>"
```

起点事例の cycle 5 では、この 2 種を追加したうえで「死に分岐化」「emit 改変」の 2 変異を実際に当てて FAIL を実測している。

### 静的 pin の位置づけ

helper 抽出（bash を実ファイルに切り出して hermetic にテストする）が本 PR のスコープを超える場合でも、述語・marker・gate の存在を grep で pin すれば drift は検出できる。**完全な hermetic テストは follow-up に切り出し、静的 pin で最低限の網を張る**のが現実的な運用。ただし「静的 pin があるから semantics も守られている」と主張してはならない。

### 追加時に mutation を当てる

静的 pin は追加時に mutation を当てないと tautology になりやすい。起点事例では「旧形状を検索する pin」を「旧形状を消した同じ commit」で追加したため、一度も失敗しえない状態だった（git 履歴で確定）。

### 「2 実装で同一定義」とコメントに書いたら、その literal のバイト一致を突合するテストを対にする

複数の helper が同じ regex・同じ述語を共有するとき、コメントで「〜と同一定義にする」と宣言するだけでは parity は守られない。**片側の振る舞いテスト（自分側がその regex で拾えること）は parity を保証しない。**

PR #2070 の実測では、2 つの helper が共有するリンク regex について、既存テストは自分側が拾えることしか測っていなかった。この状態で kill できる変異とできない変異は次のように割れる。

| 変異 | 片側の振る舞いテスト | literal 突合テスト |
|---|:--:|:--:|
| 自側の regex を**狭める** | KILL（拾えなくなる） | KILL |
| 自側の regex を**広げる** | **生存**（拾えることは変わらない） | KILL |
| **相手側**だけ drift させる | **生存**（自側は無変化） | KILL |

しかも片側だけ drift すると、対象が部分的にしか減らないため `entries >= 1` のような下限ガードが保たれ、同 PR が新設した検出失敗ガード（`entries==0 && linkrows>0`）も skipped_rows も発火しない。**その PR 自身が塞ごうとしていた silent-0 と同型の穴が、ガードの内側に残る。**

対処は「2 実装から regex literal を抽出してバイト比較する」テストを 1 本置くこと。既に同型の前例がリポジトリ内にあるなら、新しい型を作らずそれに揃える（レビュアーも将来の読み手も「既知のパターン」として読める）。

**表記差の正規化は比較前に 1 箇所で行う。** awk プログラム内リテラルは `pages\/`、`grep -oE` は `pages/` とスラッシュのエスケープが違う、といった文脈依存の差がある。どちらかに実装を寄せるのではなく、**テスト側で `\/` → `/` に畳んでからバイト比較する**。実装の可読性（各文脈で自然なエスケープ）を保ったまま parity だけを pin できる。

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [mutation は述語軸だけでなく配置・routing・副作用・到達の各軸に当てる](../heuristics/mutation-axes-beyond-predicate.md)
- [散文契約の静的 pin には weakened probe による positive control を課す](./prose-pin-requires-positive-control.md)
- [検出 grep と mutation (Edit old_string) は同一の文字列 strictness で実装する](./detection-mutation-strictness-symmetry.md)
- [新設した出力フィールドは producer と consumer の両側を pin する — consumer が表なら行単位で pin する](./new-output-field-pin-producer-and-consumer.md)

## ソース

- [PR #2030 review results (cycle 5)](../../raw/reviews/20260726T150008Z-pr-2030-cycle5.md)
- [PR #2070 review results](../../raw/reviews/20260801T170512Z-pr-2070.md)
- [PR #2070 fix results](../../raw/fixes/20260801T171512Z-pr-2070.md)
