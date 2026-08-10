---
type: "heuristics"
title: "シェル層で閉じられない注入防御は値を substitute する側（LLM）の実行前ゲートとして書く"
domain: "heuristics"
description: "LLM が値を literal substitute する bash block では、**防御の層を 1 つ塞ぐたびに同じ機構の中の「次の層」が露出する**。"
created: "2026-08-05T09:26:00+09:00"
updated: "2026-08-05T09:26:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260804T235430Z-pr-2111.md"
  - type: "fixes"
    ref: "raw/fixes/20260805T000150Z-pr-2111.md"
tags: ["quoted-heredoc", "delimiter-escape", "llm-pre-gate", "silent-success", "producer-consumer", "injection"]
confidence: medium
---

# シェル層で閉じられない注入防御は値を substitute する側（LLM）の実行前ゲートとして書く

## 概要

LLM が値を literal substitute する bash block では、**防御の層を 1 つ塞ぐたびに同じ機構の中の「次の層」が露出する**。quoted heredoc は `"` 経由の注入を塞ぐが、値に終端子（`WIU_EOF` 等）だけの行が含まれると heredoc が早期終了し、残りがコマンドとして実行される。この脱出はシェル層では閉じられない — **block 内のシェルは実行時には既に parse 済みで手遅れ**。substitute 時点でしか検査できない値の性質は、bash を実行しない**事前ゲート**として手順書の LLM 責務に置くしかない。

## 詳細

### 失敗の構造（PR #2111 run 2 cycle 3）

1. cycle 2 で 6 値すべてを quoted heredoc 受けに統一し `"` 経由の任意コマンド実行を塞いだ
2. cycle 3 のレビューで終端子行の脱出口が残っていることが判明: 6 heredoc が同一終端子を共有するため、脱出してもクォート均衡が保たれ、後続の `$(cat <<'WIU_EOF'` が再度開いて構文が通る
3. 脱出後も helper 呼び出し行は正常に走るため、**rc=0 + 3 marker 揃いの silent success** になる — cycle 2 で追加した「exit 0 だが marker が出ない」検出行でも捕捉できない

### Canonical fix

- **実行前ゲート（LLM 責務）**: substitute する値のいずれかが複数行、またはいずれかの行が終端子と完全一致する場合、**その bash を実行してはならない**と手順書に明記する。該当時は当該処理をスキップして未完了事項として報告する
- ゲートの配置は「シェルに渡る前」しかない。helper 側の検査（C0 検査等）は「bash を実行できた場合」にしか働かない

### 付随した教訓: 受け皿を作る修正は producer 側の同時追加を要求する

同 cycle で「consumer だけ足して producer が無い」非対称が複数検出された:

- 完了レポートに `dedup_removed` 合計の消費者を足したが、カウンタの生産者（カウンタ初期化表）を足していなかった
- `{ERROR 1 行目}` の引用を義務化したが、引用元が存在しないケース（signal 中断は出力ゼロ、127 は非 ERROR 行）の文言を規定していなかった
- helper docstring の invariant（「毎回実行」）に対し、呼び出し側の呼び出し条件（skip 決定 Raw Source での扱い）が未定義だった

**受け皿だけ作ると次 cycle で「埋められない欄」として返ってくる**。consumer を足すときは producer・発火条件・引用元を同時に足す。

### 判別子の教訓: 同一チャネルに複数の発行元があるなら条件は literal で閉じる

`stats_sync=synced` + 「stderr に WARNING がある」という判別子は、同じ呼び出しで出る別種の WARNING（重複中止）を部分未同期と誤判定する。同一チャネル（stderr)に複数の発行元がある場合、判定条件は特定 WARNING の literal で閉じる。

## 関連ページ

- [LLM が読む出力ストリームで marker を契約にするには prefix・行頭・デリミタ・識別子スコープの 4 条件すべてが要る](../patterns/llm-read-marker-contract-four-conditions.md)
- [LLM substitute placeholder は bash residue gate で fail-fast 化する](../patterns/placeholder-residue-gate-bash-fail-fast.md)

## ソース

- [PR #2111 review results (cycle 3)](../../raw/reviews/20260804T235430Z-pr-2111.md)
- [PR #2111 fix results (cycle 4)](../../raw/fixes/20260805T000150Z-pr-2111.md)
