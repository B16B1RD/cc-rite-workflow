---
type: "anti-patterns"
title: "消費側だけに足した allowlist は生成側の値域と食い違い「成功しているのに永久に失敗」の非収束を作る"
domain: "anti-patterns"
description: "「危険な入力を弾く」allowlist を**消費側だけ**に追加すると、生成側が正当に作れる値まで拒否する。"
created: "2026-08-01T05:40:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260801T012055Z-pr-2078.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T013839Z-pr-2078.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T032503Z-pr-2078.md"
  - type: "reviews"
    resource: "raw/reviews/20260813T093122Z-pr-2306.md"
  - type: "fixes"
    resource: "raw/fixes/20260813T093419Z-pr-2306.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T224913Z-pr-2826.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T103101Z-pr-3148.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T10:45:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-14T23:10:01Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T10:45:00Z" }
---

# 消費側だけに足した allowlist は生成側の値域と食い違い「成功しているのに永久に失敗」の非収束を作る

## 概要

「危険な入力を弾く」allowlist を**消費側だけ**に追加すると、生成側が正当に作れる値まで拒否する。単なる false reject で終わらないのが本アンチパターンの核心で、拒否の帰結が「後始末をしない（marker を消さない）」であり、それを別の gate が「残っている = 処理が未実行」と読む構成だと、**処理は成功しているのに毎サイクル失敗と判定される**非収束ループが成立する。

防御は「追加すれば安全側に倒れる」とは限らない。追加した防御が既存 gate と合成された結果、安全側ではなく **wedge**（詰み）に倒れる。

## 詳細

### 実測した非収束の形

実測例では、helper が caller から受け取る marker path に「安全な文字だけ」の allowlist を追加した。生成側は `${TMPDIR:-/tmp}` を基点に path を組み立てるが、実行環境の `TMPDIR` に空白や非 ASCII が含まれると allowlist を通らない。

拒否時の挙動は「marker を削除せずに戻る」だった。一方、後段の実行保証 gate は「marker が残存 = ステップが実行されなかった」と判定する。合成結果:

```
保存は成功 → allowlist が path を拒否 → marker が残る
           → gate が「未実行」と判定 → 差し戻し → 再実行 → 同じ拒否
```

再実行しても同じ値が生成されるため決定論的に収束しない。CRITICAL として検出された。

### 「guard を足す」より「危険な値を受け取らない」

同 PR は 2 サイクルにわたり、この path 受け取り設計に由来する指摘を 8 件受けた（sentinel 偽造 / path traversal / errno 握り潰し / 文字集合 wedge / 各 guard 条件の pin 不足）。個別に塞ぐと guard が増え、その guard 自体が次の指摘面になる。

最終的な解は guard の追加ではなく**インタフェースの差し替え**だった。full path ではなく id token を受け取り、path は helper 内部で導出する形にすると、

- 形状不一致というクラス自体が存在しなくなる
- allowlist・制御文字中和・errno 退避が芋づるで不要になる

結果として net で行数が減った。**sibling helper が同じ処理を別の形で解いているなら、guard を足す前にその形へ揃えられないかを見る。**

### 防御を足す前のチェックリスト

| 確認項目 | 問い |
|---|---|
| 生成側の値域 | その値を作る側が正当に生成しうる全パターンを、この防御は通すか |
| 拒否時の帰結 | 拒否したとき何をしないことになるか（消さない / 書かない / 戻らない） |
| 既存 gate との合成 | その「しないこと」を、別の層が別の意味に読む構成になっていないか |
| 再実行で変わるか | 拒否が決定論的なら、再実行を促す設計は非収束になる |

### fixture が安全側に偏ると構造的に見えない

この wedge は全 assertion（474 件）green のまま素通りした。テスト fixture の path がすべて `mktemp -d` 由来で、空白や非 ASCII を含む値が 1 本も無かったため。

**入力を狭める変更を入れたら、「弾かれる側の正当な入力」を fixture に必ず 1 本入れる。** 攻撃入力（弾かれるべき値）だけを足しても、false reject 側は検出できない。

### 値域の食い違いは「弾きすぎ」だけでなく「発火しない」方向にも出る

同じ非対称は、消費側が **producer が実際には出さない値**を待つ形でも起きる。修復ゲートを新設した際、消費側の判定が helper の出力する値域と 1 語ずれており（helper は `JSON_SAVED=true` を出すのに別表記を待っていた）、**ゲートが主シナリオで一度も発火しなかった**。allowlist 型の wedge が「正当な値を拒否する」のに対し、こちらは「異常値を通す」向きの縮退で、症状は無音である。

どちらの向きも原因は同じ — **消費側の値域を、producer の実装ではなく設計意図から書いた**こと。新設する判定は、必ず producer の出力を実測（または helper の docstring 契約）から引く。加えて、成立を観測する marker を「保存が成功した」ことに限定し、判定不能を成功へ倒さない。

### producer の例外経路が作る名前も値域に含める

ファイル名の形を検査する消費側では、producer の**通常経路**の名前だけを受理形に書きがちである。保存 helper が同秒衝突時にだけ `{ts}~{4 桁 hex}.json` という suffix 付きの名前を作る実装で、消費側の受理 regex が `{ts}.json` しか許さなかったため、衝突経路で保存された結果に載った指摘は識別 key を持てず、解消済みでも毎回転記され続けた。

直すときは次の 3 点を揃える。

- 受理形の上限は producer の生成式から引く。`printf '%04x' "$RANDOM"` なら小文字 hex ちょうど 4 桁で、大文字や桁違いまで広げない
- 同じ形を判定する消費側が複数あれば、同じバイト列で同時に広げ、片方だけの変更を静的 pin で止める
- 説明文にも上限を書く。「4 桁 hex」とだけ書くと、regex より広い範囲を宣言したことになる

### 消費側に新しい必須入力を足すと、その値を運べない producer 経路で停止が必ず起きる

値域の食い違いは値の形だけでなく、**フィールドの有無**でも起きる。判定 helper に新しい入力フィールド（帰結クラスなど）を必須として要求し、欠けていれば fail-loud で止める検証を足した。ところが同じ helper を呼ぶ入力経路のうち、会話や legacy Markdown から JSON を再構成する経路はそのフィールドを運ぶ手段を持たず、その経路では新設の停止が毎回発火した。独立した 3 名の reviewer が同じ根因を指摘している。

consumer 側に検証を足すときは、呼び出し元を 1 本ずつ辿り、**全 producer 経路がその値を渡せるか**を経路ごとに確かめる。渡せない経路があるなら、検証を足す前にその経路へ値を運ぶ手段を作るか、経路ごとに扱いを分ける。

既存テストの fixture に新フィールドを後付けして green に戻すと、本来の producer がその値を渡さない欠落がかえって隠れる。fixture を直す前に、その値を実際に作る producer がどこかを確認する。

## 関連ページ

- [非収束の review ループは個別修正ではなく構造を疑う](../heuristics/non-converging-review-loop-suspect-structure.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md)
- [accept 側と reject 側の fixture 設計を反転させて検証する](../heuristics/accept-vs-reject-fixture-design-inversion.md)

## ソース

- [レビュー結果](../../raw/reviews/20260801T012055Z-pr-2078.md)
- [fix 結果](../../raw/fixes/20260801T013839Z-pr-2078.md)
- [消費側ゲートの値域が helper 契約と食い違い主シナリオで発火しなかった](../../raw/reviews/20260813T093122Z-pr-2306.md)
- [判定を helper 契約の値域へ揃え、保存観測を成功時 marker に限定](../../raw/fixes/20260813T093419Z-pr-2306.md)
- [同秒衝突 suffix を受理形と射影の両方で同時に受け付けたレビュー結果](../../raw/reviews/20260914T224913Z-pr-2826.md)
- [新しい必須入力を運べない producer 経路で停止が必ず発火したレビュー結果](../../raw/reviews/20260926T103101Z-pr-3148.md)
