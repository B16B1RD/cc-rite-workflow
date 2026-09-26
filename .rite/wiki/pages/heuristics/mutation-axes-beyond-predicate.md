---
type: "heuristics"
title: "mutation は述語軸だけでなく配置・routing・副作用・到達の各軸に当てる"
domain: "heuristics"
description: "「静的 pin を追加したらその場で mutation を当てて落ちることを確認する」は既に確立した規約だが、**当てる mutation の軸**が規約に含まれていないと、述語（条件式そのもの）にだけ変異を入れて満足してしまう。"
created: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260727T001018Z-pr-2035.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T014642Z-pr-2035.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T004206Z-pr-2035.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T010154Z-pr-2035.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T150008Z-pr-2030-cycle5.md"
  - type: "reviews"
    resource: "raw/reviews/20260801T131235Z-pr-2081.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T124925Z-pr-2081.md"
  - type: "reviews"
    resource: "raw/reviews/20260913T042914Z-pr-2767.md"
  - type: "fixes"
    resource: "raw/fixes/20260913T043312Z-pr-2767.md"
  - type: "reviews"
    resource: "raw/reviews/20260913T051120Z-pr-2767.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T112003Z-pr-3153.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T11:40:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-13T05:16:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T11:40:00Z" }
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

### 6 つ目の軸: 機械経路 / 人間向け経路の非対称

survivor が「機械経路は pin されているが**人間向け経路が未 pin**」という同一クラスに集中する現象が観測された。判別を 3 値化した事例では 56 変異中 47 kill で、残った survivor 2 件は `gated` 修飾の無保護と RUNTIME_OBS WARNING の未 pin。別 cycle でも survivor 1 件が marker の `cause=` フィールドの pin 欠落だった（前 cycle の編集で assertion を別 TC へ移した際に literal の一部が落ちていた）。

**同じ判定結果を機械可読 marker と人間向け WARNING の 2 経路で出しているとき、pin が marker 側だけに付くことが多い。** 人間向け文言は「表示だけだから」と pin の対象外に見えるが、operator が受け取る唯一の診断であることが多く、実装との乖離は無検出で進行する。**pin の非対称は変異でしか見えない。**

**変異注入は「閉じたこと」も確認できる**: 前 cycle の survivor が今 cycle で kill されることを実測すれば、修正が効いたことを定量的に言える。「テストが落ちることの確認」まで含めて実行すると、pin の形骸化を数値で追跡できる。

### 検査の共通化は配置軸の pin を消しうる

経路ごとに分かれていた検査を「ファイル内にちょうど 1 行ある」のような共通条件へまとめると、分岐は減るが、ある経路にだけあった「その行が特定の節の中にあるか」という配置の検査が一緒に消える。件数だけを数える共通条件は行の**削除**を捉えるが、行の**移動**は捉えない。分岐が減ったことと既存の検査が弱まっていないことは別の問いであり、共通化のたびに両方を確かめる。

- **弱体化の実測**: 変更前のテストを、変更後のソースと「行を節の外へ移した変異ソース」の両方に当てる。変更前のテストでは落ち、変更後のテストでは通る変異があれば、それが消えた検査である。
- **最小の戻し方**: 共通の件数検査は残し、その直後に経路限定の節内検査を追加で戻す。削除は共通の検査が、移動は経路限定の検査が捉える役割分担になり、どちらか一方だけでは片方の変異を取りこぼす。
- **変異の検出は失敗メッセージの完全一致で固定する**: 戻した検査のエラーメッセージを他の検査と区別できる文言にし、変異に対する assert を終了コードではなくそのメッセージとの完全一致にする。終了コードだけを見ると、前段の別の検査で落ちた場合も「検出した」と数えてしまう。
- **変異ファイルの生成も errexit 下で守る**: `set -euo pipefail` のテストで変異ファイルを作る `grep` にガードが無いと、対象行が消える退行が起きたときにスクリプトが生成行で終了し、後続の assertion とサマリーが出ない。失敗は終了コードで検出されるが診断が失われる。同じファイル内のほかの `grep` がガード付きなら、追加する生成行にも揃え、対象行が無い場合は「変異が効いていない」という名前付きの失敗として報告させる。

### 判定を共有化すると、先行ゲートの陰に隠れる呼び出し元が出る

同じ判定式を複数の呼び出し元から使う関数へまとめると、呼び出し元ごとの条件の食い違いは消える。ただし、ある呼び出し元の前で別のゲートが同じ入力を先に拒否している経路では、その呼び出し元の判定は通常のテストで一度も観測されない。実測例では 3 箇所に寄せた判定のうち、完了記録側だけを旧条件に戻す変異がスイート全体を通った。先行するゲートが同じ行を別の理由で先に拒否していたためである。

判定を共有化したら、**呼び出し元ごとに**旧条件へ戻す変異を当て、どの呼び出し元の判定が実際に観測されているかを確かめる。生存した呼び出し元は、その判定が契約上の挙動に現れるかで扱いを分ける。現れないなら、重複した防御として記録して残してよい。現れるなら、先行ゲートを通過する入力で fixture を組み、その呼び出し元に直接到達させる。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [accept fixture と reject fixture は設計目的が逆 — 安全側の形状を両方に適用すると順序契約が pin できなくなる](./accept-vs-reject-fixture-design-inversion.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [散文契約の静的 pin には weakened probe による positive control を課す](../patterns/prose-pin-requires-positive-control.md)

## ソース

- [レビュー結果](../../raw/reviews/20260727T014642Z-pr-2035.md)
- [レビュー結果](../../raw/reviews/20260801T131235Z-pr-2081.md)
- [fix 結果](../../raw/fixes/20260801T124925Z-pr-2081.md)
- [検査の共通化で経路限定の配置検査が消えたことを検出したレビュー結果](../../raw/reviews/20260913T042914Z-pr-2767.md)
- [共通の検査を残して経路限定の検査を戻す対応を示した fix 結果](../../raw/fixes/20260913T043312Z-pr-2767.md)
- [戻した検査を失敗メッセージの完全一致で固定したレビュー結果](../../raw/reviews/20260913T051120Z-pr-2767.md)
- [共有化した判定の一呼び出し元が先行ゲートの陰で観測されないことを変異で確かめたレビュー結果](../../raw/reviews/20260926T112003Z-pr-3153.md)
