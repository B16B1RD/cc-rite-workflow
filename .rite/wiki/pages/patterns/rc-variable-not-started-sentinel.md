---
type: "patterns"
title: "rc 変数を 0 で初期化すると、未起動の段を「起動して成功した」と断定する"
domain: "patterns"
promote: rite-plugin
description: "多段 pipeline の rc を診断へ載せるとき、0 は「実行して成功」の意味を持つ。実行されうるが実行されない段の初期値には非数値 sentinel を使い、実際に走る経路でのみ rc を代入する。"
created: "2026-08-03T07:46:56Z"
updated: "2026-08-03T07:46:56Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260803T013513Z-pr-2094.md"
  - type: "fixes"
    ref: "raw/fixes/20260803T005938Z-pr-2094.md"
  - type: "reviews"
    ref: "raw/reviews/20260803T004941Z-pr-2094.md"
  - type: "reviews"
    ref: "raw/reviews/20260803T012646Z-pr-2094.md"
tags: []
confidence: high
---

# rc 変数を 0 で初期化すると、未起動の段を「起動して成功した」と断定する

## 概要

多段 pipeline（例: `python3 ... | jq ...`）の各段の rc を診断メッセージへ載せる設計で、後段の rc 変数を `0` で初期化すると、**後段が一度も起動しない経路で「起動して成功した」と能動的に断定する**。`0` は「実行して成功」の意味を持つため、実行されうるが実行されない段の初期値には使えない。非数値 sentinel（`n/a` 等）で初期化し、実際に走る経路でのみ rc を代入する。

## 詳細

### 3 段階で現れた失敗

この形は 1 回の修正では終わらず、鏡像の誤りを経て確定した。

| 段階 | 状態 | 診断が出す嘘 |
|---|---|---|
| 初期 | 前段と後段の stderr を両方 `2>/dev/null` に捨て、WARNING に前段の rc だけを載せる | 後段が失敗した経路で「前段は成功した」と表示 → triage が誤った component へ誘導される |
| 修正 1 | 後段の rc も載せるが `0` で初期化 | 後段が未起動の経路で「起動して成功した」と断定 |
| 修正 2 | 非数値 sentinel で初期化し、走る経路でのみ代入 | — |

**沈黙より悪い。** 診断が何も言わなければ triage は自分で調べるが、誤った component を名指しすると調査が明後日の方向へ向かう。

### stderr を両方捨てた pipeline は診断の材料を持たない

そもそも両段の stderr を捨てていると、WARNING が載せられるのは rc だけになる。修正は姉妹 hook の既存実装をそのまま写せば済んだ — **リポジトリ内に確立済みの doctrine がある場合、新規コードがそこから外れているかを機械的に確認する価値がある**。実例では同じ pipeline を回す姉妹 hook が stderr capture を実装しており、コメントに理由まで書いてあった。

### 実装の型

```bash
# ✗ 0 初期化: 未起動を「成功」と読める
_stage2_rc=0
out=$(stage1 2>"$e1") && _stage2_rc=0 || _stage1_rc=$?
# stage2 が走らない経路でも _stage2_rc=0 のまま診断へ載る

# ✓ 非数値 sentinel: 未起動が未起動として表示される
_stage1_rc="n/a"; _stage2_rc="n/a"
mid=$(stage1 2>"$e1"); _stage1_rc=$?
if [ "$_stage1_rc" -eq 0 ]; then
  out=$(printf '%s' "$mid" | stage2 2>"$e2"); _stage2_rc=$?
fi
echo "WARNING: ... (stage1 rc=$_stage1_rc, stage2 rc=$_stage2_rc)" >&2
```

sentinel は数値比較へ流れないよう、診断の表示専用に留めるか、比較前に数値判定を挟む（[bash の算術比較は非数値入力で rc=2 を返す](../anti-patterns/bash-numeric-test-fail-open-on-nonnumeric.md) 参照）。

### 一般化: sentinel を持つ上流から値を引き継ぐ機構

同じ PR で、逆方向の sentinel 事故も起きている。flow-state は「PR 未作成」を `0` で表すが、carry-forward のガードが env の空 / 非空しか見ないため、`0` を実値として採用し恒久化させた（変更前は次の更新で `null` に戻っていた）。

**sentinel を持つ上流から値を引き継ぐ機構を足すときは、sentinel が「値あり」と判定されないかを確認する。** ただし除外は片側だけに置くこと — 同じ `0` でも `loop_count` 側は「まだ 1 周もしていない」という実値なので、除外を波及させると別の退行になる。**この非対称は回帰テストで固定する**（除外の適用側と非適用側を両方 assert する）。

## 関連ページ

- [診断メッセージの主語と射程は、その文が発火する条件が保証している対象に限る](../heuristics/diagnostic-claim-scoped-to-firing-condition.md)
- [`[ "$x" -eq 0 ]` は非数値入力で rc=2 を返し、fail-closed の意図が else 側へ倒れる](../anti-patterns/bash-numeric-test-fail-open-on-nonnumeric.md)
- [PIPESTATUS はコマンド置換 `$(...)` のサブシェル境界を越えない](../heuristics/pipestatus-subshell-scoping-command-substitution.md)

## ソース

- [PR #2094 fix results (cycle 3)](../../raw/fixes/20260803T013513Z-pr-2094.md)
