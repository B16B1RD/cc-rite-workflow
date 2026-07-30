---
type: "heuristics"
title: "mutation は述語軸だけでなく配置・routing・副作用・到達の各軸に当てる"
domain: "heuristics"
description: "「静的 pin を追加したらその場で mutation を当てる」を守っていても、当てる軸が述語（条件式の書き換え）に偏ると、配置（順序）・routing（終端値）・副作用（rename / tempfile）・到達（分岐が生きているか）の退行が生存する。PR #2035 は 5 cycle かけて cycle ごとに「当てていない軸」が新たに発見され、軸の列挙自体をチェックリスト化する必要が判明した。"
created: "2026-07-27T10:57:51+09:00"
updated: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260727T001018Z-pr-2035.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T014642Z-pr-2035.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T004206Z-pr-2035.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T010154Z-pr-2035.md"
  - type: "reviews"
    ref: "raw/reviews/20260726T150008Z-pr-2030-cycle5.md"
tags: []
confidence: high
---

# mutation は述語軸だけでなく配置・routing・副作用・到達の各軸に当てる

## 概要

「静的 pin を追加したらその場で mutation を当てて落ちることを確認する」は既に確立した規約だが、**当てる mutation の軸**が規約に含まれていないと、述語（条件式そのもの）にだけ変異を入れて満足してしまう。起点事例は Issue に上記規約が明記されていたにもかかわらず、cycle ごとに「まだ当てていない軸」が新たに発見された（配置軸 → 上側境界 → 片側性 → positive control）。軸を列挙して初めて網羅が主張できる。

## 詳細

### 5 つの軸

| 軸 | 変異の例 | 生存したときに何が守られていないか |
|---|---|---|
| **述語** | 条件式を反転 / `all()`→`any()` / 型検査を削除 / 必須化 | 判定ロジックそのもの |
| **配置（順序）** | ガードを 1 つ上／下の分岐へ移動 | precedence / 区間制約。fixture 形状が短絡すると観測できない（関連ページの fixture 設計を参照） |
| **routing（終端値）** | 分岐先を別の終端（fallback / 別 Priority）へ差し替え | 「この失敗はすべて Priority N へ」という routing 契約。否定 assert（`assert_err_lacks`）だけでは通過する |
| **副作用** | rename / 削除 / tempfile の cleanup 登録を外す | 破壊的操作の有無、リソースの lifecycle。成功経路（最頻）のリークは特に見落としやすい |
| **到達** | 対象を `exit 0` するだけのスタブに差し替え / 直前の分岐を常時 true 化 | 「不在の確認」が「cleanup が働いた」ではなく「そもそも到達していない」で成立する vacuous pass |

### 軸ごとの pin の形

- **述語**: 通常の assert
- **配置**: 両分岐が発火しうる fixture + どちらの reason が出たかを positive assert。区間制約なら上下 2 fixture
- **routing**: 終端値を positive に assert する（`REVIEW_SOURCE=fallback` が出ること）。「出ないこと」の否定形は routing 変更を通す
- **副作用**: 実行後の残留物を集合で検査（tempfile の glob、rename 後のファイル名）。片側の実装しか実行しない pin は非対称な退行を検出できない
- **到達**: rc と marker を positive に固定してから不在を判定する（positive control）

### 静的 parity テストの限界

述語テキストの出現数 + 行順を pin する静的 parity テストは、**3 site を一貫改修する mutation では素通りする**（実測: 112 pass のまま正準形状が fallback に落ちた）。静的 pin は drift（site 間の不一致）を検出するが semantics は守らない。到達性 pin（直前行が live な `elif` であること）と emit pin（reason + `>&2` の固定文字列）を**対で**追加して初めて、死に分岐化と emit 改変の 2 軸が守れる。

### 運用

pin を追加したら、その場で以下を順に当てる:

1. 述語を反転する → FAIL するか
2. 位置を 1 つ動かす → FAIL するか
3. 分岐先を別の終端に変える → FAIL するか
4. 副作用（rename / cleanup 登録）を外す → FAIL するか
5. ターゲット自体をスタブに差し替える → FAIL するか（到達の確認）

生存した軸があれば、それは fixture 形状か assert 形式の問題であり、pin を足すのではなく既存 pin の観測窓を開ける方向で直す。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [accept fixture と reject fixture は設計目的が逆 — 安全側の形状を両方に適用すると順序契約が pin できなくなる](./accept-vs-reject-fixture-design-inversion.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [散文契約の静的 pin には weakened probe による positive control を課す](../patterns/prose-pin-requires-positive-control.md)

## ソース

- [PR #2035 review results (cycle 5, converged)](../../raw/reviews/20260727T014642Z-pr-2035.md)
