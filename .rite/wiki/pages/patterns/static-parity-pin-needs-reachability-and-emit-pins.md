---
type: "patterns"
title: "静的 parity テストには到達性 pin と emit pin を対で足す — 出現数 + 行順だけでは semantics を守れない"
domain: "patterns"
description: "markdown 埋め込み bash のように実行テスト不能なコードを守る静的 parity テスト（述語文字列の出現数 + 行順）は、site 間の drift は検出するが semantics は守らない。3 site を一貫改修する mutation で素通りする（実測: 112 pass のまま正準形状が fallback に落ちた）。直前行が live な分岐であることを pin する到達性 pin と、reason / >&2 の固定文字列を pin する emit pin を対で追加する。"
created: "2026-07-27T10:57:51+09:00"
updated: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260726T150008Z-pr-2030-cycle5.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T161811Z-pr-2030.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T150940Z-pr-2030-cycle5.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T134912Z-pr-2030.md"
tags: []
confidence: high
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

PR #2030 cycle 5 では、この 2 種を追加したうえで「死に分岐化」「emit 改変」の 2 変異を実際に当てて FAIL を実測している。

### 静的 pin の位置づけ

helper 抽出（bash を実ファイルに切り出して hermetic にテストする）が本 PR のスコープを超える場合でも、述語・marker・gate の存在を grep で pin すれば drift は検出できる。**完全な hermetic テストは follow-up に切り出し、静的 pin で最低限の網を張る**のが現実的な運用。ただし「静的 pin があるから semantics も守られている」と主張してはならない。

### 追加時に mutation を当てる

静的 pin は追加時に mutation を当てないと tautology になりやすい。PR #2030 では「旧形状を検索する pin」を「旧形状を消した同じ commit」で追加したため、一度も失敗しえない状態だった（git 履歴で確定）。

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [mutation は述語軸だけでなく配置・routing・副作用・到達の各軸に当てる](../heuristics/mutation-axes-beyond-predicate.md)
- [散文契約の静的 pin には weakened probe による positive control を課す](./prose-pin-requires-positive-control.md)
- [検出 grep と mutation (Edit old_string) は同一の文字列 strictness で実装する](./detection-mutation-strictness-symmetry.md)

## ソース

- [PR #2030 review results (cycle 5)](../../raw/reviews/20260726T150008Z-pr-2030-cycle5.md)
