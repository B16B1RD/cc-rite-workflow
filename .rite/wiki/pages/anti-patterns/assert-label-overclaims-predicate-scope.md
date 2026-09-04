---
type: "anti-patterns"
title: "assert のラベルが述語より広い範囲を名乗ると「虚偽主張」クラスの欠陥になる"
domain: "anti-patterns"
description: "assert のラベル（テスト名・メッセージ）は、その assert が守る契約の宣言である。"
created: "2026-08-08T14:00:41+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260808T013358Z-pr-2142.md"
  - type: "fixes"
    resource: "raw/fixes/20260808T014357Z-pr-2142.md"
  - type: "reviews"
    resource: "raw/reviews/20260830T033236Z-pr-2471.md"
  - type: "fixes"
    resource: "raw/fixes/20260830T034210Z-pr-2471.md"
tags: ["test", "mutation-testing", "assertion-strength", "contract", "review-fix-loop"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-30T12:50:00+09:00" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-08-30T12:50:00+09:00"
---

# assert のラベルが述語より広い範囲を名乗ると「虚偽主張」クラスの欠陥になる

## 概要

assert のラベル（テスト名・メッセージ）は、その assert が守る契約の宣言である。述語が実際に見ている範囲がラベルより狭いと、**suite は green のまま読み手に「3 条件すべてが守られている」と誤認させる**。これは検出力不足ではなく虚偽主張であり、pin が無い状態より悪い（無ければ「守られていない」と分かる）。

ある PR の cycle 3 では、前 cycle で「番人を立てる」ために新設した assert 自身に 2 件の指摘が付いた。cycle 3 の blocking 6 件のうち 4 件が、前 cycle が書いたコメントと assert の欠陥だった。

## 詳細

### 実測された 2 形

1. **`all three` と名乗って 1 対しか見ない**: `grep -A1 <2 行目>` で 2→3 の隣接だけを検査したため 1→2 が無防備だった。**隣接性を「対」で検査すると、検査していない対が必ず残る** — 表ヘッダ直後の N 行を 1 回の抽出で取り出し、期待値とまとめて照合すれば、対の数だけ assert を足す必要がなく、条件が増えても期待値を 1 箇所直せば済む
2. **counterweight が固定部分を needle にしている**: 「制御文字が出ない」の裏返しに「可読部分は残る」を置いたが、needle が script 側の**固定接頭辞**だったため、出力から payload を丸ごと削除しても両方 green になった。`assert_not_contains` の counterweight は、行番号・抽出値のように**実装が壊れれば変わる可変部分**を needle にしなければ counterweight として機能しない

### ラベルを書いたら mutant を当てる

新しい assert を書いた直後に、**ラベルが約束する全ての壊れ方**を 1 つずつ再現して落ちるかを見る。1 つでも生存したら選択肢は 2 つしかない。

- **ラベルを狭める**: 「2→3 の隣接を検査する」と正直に書く
- **述語を広げる**: ブロックごと 1 回の照合に置き換える

「後で強化する」は選べない。ラベルが残る限り、読み手はその範囲が守られていると信じ続ける。

### 共有ヘルパーの欠陥を主張するときは範囲を数えてから書く

同 cycle では「`assert_grep_in_section` は escape が剥がれて **assert が常に PASS する**」「**全 caller** に同じ縮退がある」と書いたが、実測では (i) start が一致しなければ empty section を検出して FAIL する、(ii) 縮退するのは**終端**パターンに意味を変える escape を含む caller だけで、既存 28 caller 中 0 件だった。**誤った一般化は「28 箇所の一斉修正」か「正常な assert 全体への不信」のどちらかを誘発する**。主張の範囲は grep で数え、数えた結果を主張に書く。手段の判断（この helper を使わない）が正しくても、理由が誤っていれば別の欠陥として残る。

### テスト名が契約を宣言し、述語がそれを守らない 2 形

ラベルと述語の乖離は「範囲」だけでなく「強度」と「方向」でも起きる。どちらもテスト名だけ読むと守られているように見え、mutation でしか露見しない。

**強度の乖離** — テスト名 `notifies on every phase change` に対し assert は `[ "$n" -ge 1 ]`。3 回の phase 変化をループしながら 1 回で通る。実行時は 3/3 で PASS するので pass メッセージ自身が `3/3` と出すが、閾値は 1 のまま。「1 回鳴って以後沈黙」する退行——まさにそのテストが塞いだはずの障害——が緑で通り抜ける。**観測値より弱い閾値を書いた時点で、テスト名の契約は守られていない**。

**方向の乖離** — テスト名 `#246 が #2463 に前方一致しない` に対し、実際に検証していたのは target=2463 / cached=246 の組。文字列等価な現行実装ではこの向きは自明に通る。危険な向きは逆（target=246 / cached=2463）で、部分一致実装なら「含む」と誤判定する。実際に `grep -c "^- \*\*Issue\*\*: #$issue"` へ mutate すると 31 passed / 0 failed で誰も検出しなかった。**境界テストは「壊れた実装が通ってしまう側」を書く**。名前が境界を主張しているなら、その主張を偽にできる向きが検証対象である。

いずれも修正は名前を弱めることではなく述語を強めること（`-eq 3` にする / 逆方向のケースを足す）。名前が正しい契約を述べているなら、直すのは述語のほうである。

## 関連ページ

- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)
- [テスト pin の protection theater](./test-pin-protection-theater.md)
- [`assert_not_contains` には可変部分を needle にした positive control を対で置く](../patterns/negative-assertion-positive-control.md)
- [テスト検出力の回復は個別 assert の増築より golden 全文比較への置換を先に検討する](../patterns/golden-full-comparison-over-assert-accretion.md)

## ソース

- [レビュー結果](../../raw/reviews/20260808T013358Z-pr-2142.md)
- [fix 結果](../../raw/fixes/20260808T014357Z-pr-2142.md)
