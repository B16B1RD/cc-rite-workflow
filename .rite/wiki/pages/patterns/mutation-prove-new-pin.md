---
type: "patterns"
title: "追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない"
domain: "patterns"
description: "非回帰 pin を足した直後に、当の欠陥へ戻す変異を一時コピーへ当てて当該 assert だけが赤くなることを確かめる。prefix 一致の pin や、守るべき値ではなく行の存在だけを見る pin は、変異を当てるまで無害に見え、当てた瞬間に無力だと分かる。"
created: "2026-09-01T20:27:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260901T092936Z-pr-2498.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T095150Z-pr-2498.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T110702Z-pr-2498.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T140807Z-pr-2500.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T165319Z-pr-2500.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T173133Z-pr-2500.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T225105Z-pr-2503.md"
  - type: "reviews"
    resource: "raw/reviews/20260902T044110Z-pr-2505.md"
  - type: "fixes"
    resource: "raw/fixes/20260902T044502Z-pr-2505.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T04:58:47Z" }
verified:
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T00:50:00Z" }
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T04:58:47Z" }
---

# 追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない

## 概要

非回帰 pin を足した直後に、当の欠陥へ戻す変異を一時コピーへ当てて当該 assert だけが赤くなることを確かめる。prefix 一致の pin や、守るべき値ではなく行の存在だけを見る pin は、変異を当てるまで無害に見え、当てた瞬間に無力だと分かる。

## 詳細

**素通りする pin の 2 類型**（いずれも実際に生存した変異）:

1. **prefix までしか見ない pin**: `rc=` までの一致は、実 rc を取り落として常に 0 を出す実装を素通しする。値で pin する（`rc=127`）。
2. **行の存在だけ見て、守るべき値の列を見ない pin**: 判定表の受け皿行に対して行キーと警告文言だけを pin したところ、当の行の check 列を `x` に反転させる変異が素通りした。行キーと値の列を 1 本の assert で同時に固定する。

```bash
# 行キーと check 列を同時に固定する（片方だけでは変異が生存する）
assert "Step 12 wiki_ingest_check has an unchecked marker-absence row" "1" \
  "$(grep -F '<行キー>' "$FILE" | grep -cF '| ` ` |')"
```

**手順**: 対象ファイルを一時 worktree または一時コピーへ取り、修正前の形（あるいは marker 値の反転）へ戻し、テストを走らせて**当該 assert だけが**赤くなることを見る。他の assert まで赤くなるなら変異が大きすぎるか、pin の範囲が広すぎる。

**効果**: pin を強めた側が自分で 1 回当てておくと、reviewer 側で同じ確認が重複しない。観測された事例の cycle 2 では 3 名の reviewer がそれぞれ独立に同じ変異を当て直していた。逆に当てずに出すと、次 cycle で同じ pin に対する指摘が再発行される。

**sibling が既に同じ列を固定しているなら target set を継承する**: 同型の pin が別ファイルに既にあるなら、その pin が何を固定しているか（どの列・どの値）を見て同じ集合を守る。自分だけ弱い集合を選ぶと、その差分がそのまま変異の生存経路になる。

**「件数だけの pin」は配線を守らない**: 抽出の完了ゲートを helper 呼び出しの**件数**で pin すると、呼び出しの引数を literal へ潰す変異が素通りする。引数がガードを駆動する入力である場合、件数の pin は「配線は検査済み」という false confidence を生む。観測された事例の mutation では 3 変異すべてがスイート全体 green だった。

**routing 表のリテラルは bash elif の削除を検出しない**: 分岐表に `P461_DECISION=skip_cancelled_children` があることと、同一行に `proceed_to_confirmation` が無いことだけを pin すると、routing 表を残したまま bash の `elif cancelled_count` を消してもスイートは green のままになる。LLM が読むのは stdout の marker なので、実行経路の elif 形（`elif [ "$cancelled_count" -gt 0` と続く `P461_DECISION=skip_cancelled_children; numbers=` が proceed の else より前）を pin する。判定表の generic 行も同じ穴で、skip 行と互いに素な条件（`none NOT_PLANNED` / `no unavailable stateReason`）を generic 行自身に書かないと、上から評価しても両行が同時マッチする。

**部分文字列関係（`X` ⊂ `REMOTE_X`）は pin の空振り源**: `BRANCH_CHECK_FAILED` は同一セクションの `REMOTE_BRANCH_CHECK_FAILED` に部分文字列一致し、規則を削除しても反転しても緑。pin は規則の述語まで含めた 1 行 literal にアンカーする。golden / byte-identical を主張する fixture を部分文字列で自己参照する形も同じ穴で、期待値そのものが pin 対象に含まれる。

**negative control は行スコープの盲点を持つ**: `grep` は行単位なので、`<helper>.*2>"$` の形は helper 名とリダイレクトが同一物理行にある場合しか赤くしない。長い helper 呼び出しを `\` で折るのが家風のリポジトリでは、退行が取る自然な形がちょうど死角に入る。negative control の積み増しではなく、呼び出し行そのものを固定する positive pin（`^bash <helper> ... 2>&1`）を置く。cycle 2 で同じ欠陥クラスを潰した修正が、その修正で導入した control に同じ盲点を持っていた。

禁止したい退行を**別名で**隔離コピーへ再投入し、それでも赤くなることを確認する。名前を変えただけで緑になるなら、その assertion は名前に束縛されている。赤くならなければその assertion は削除するのが正しい。

## 関連ページ

- [absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する](./absence-pin-base-present-head-absent-single-line.md)
- [Fix の完成判定は shell script 単体動作ではなく実ワークフロー発火実績で行う](../heuristics/fix-verification-requires-natural-workflow-firing.md)

## ソース

- [PR #2498 fix results](../../raw/fixes/20260901T092936Z-pr-2498.md)
- [PR #2498 review results (cycle 2)](../../raw/reviews/20260901T095150Z-pr-2498.md)
- [PR #2498 review results (cycle 5)](../../raw/reviews/20260901T110702Z-pr-2498.md)
- [PR #2500 review results (cycle 2)](../../raw/reviews/20260901T140807Z-pr-2500.md)
- [PR #2500 review results (cycle 2)](../../raw/reviews/20260901T165319Z-pr-2500.md)
- [PR #2500 review results (cycle 3)](../../raw/reviews/20260901T173133Z-pr-2500.md)
- [PR #2503 review results](../../raw/reviews/20260901T225105Z-pr-2503.md)
- [PR #2505 review results](../../raw/reviews/20260902T044110Z-pr-2505.md)
- [PR #2505 fix results](../../raw/fixes/20260902T044502Z-pr-2505.md)
