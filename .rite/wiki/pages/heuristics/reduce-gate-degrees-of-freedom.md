---
type: "heuristics"
title: "ゲートに検査を足すより、実行者が選べる自由度を削る"
domain: "heuristics"
description: "新設した commit 前ゲートに指摘が集中したとき、ガードを個別に足すと検査面が増えて次サイクルで再生産する。効くのは対象の列挙・ラベル・本文・marker routing を実行者が選べない形へ単純化すること。自由度が消えると複数の指摘が同時に成立しなくなる。"
created: "2026-09-04T13:54:13Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-04T13:54:13Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260904T091303Z-pr-2549.md"
  - type: "fixes"
    resource: "raw/fixes/20260904T092650Z-pr-2549.md"
tags: [skill-authoring, gate, simplification-first]
confidence: high
promote: rite-plugin
---

# ゲートに検査を足すより、実行者が選べる自由度を削る

## 概要

新設した commit 前ゲートに指摘が集中したとき、ガードを個別に足すと検査面が増えて次サイクルで再生産する。効くのは対象の列挙・ラベル・本文・marker routing を実行者が選べない形へ単純化すること。自由度が消えると複数の指摘が同時に成立しなくなる。

## 詳細

Wiki ingest の commit 前ゲートを新設したサイクルで、placeholder 残留・heredoc 終端子衝突・完了レポートの受け皿欠落・呼び出し元ゲート欠落・hit 時の Edit 契約矛盾・blob 相対の行番号・raw ラベルによる無条件 clean が一度に出た。個別にガードを足す修正は、指摘 1 件ごとに新しい検査面を増やして次サイクルで再生産する。

実際に効いたのは逆で、ゲートが持っていた自由度を削ったことだった。対象の列挙・ラベル・本文・marker routing を実行者が選べる状態をやめ、未 commit の差分を 1 回走査する形へ畳んだ。heredoc と per-target ループが消えることで衝突・行番号・受け皿欠落が構造的に成立しなくなり、error を fail-loud にしたことで「検査していないのに commit へ進む」経路が消えた。完了レポートに受け皿を足す必要もなくなった。

新しい検査を足す前に、ゲートが実行者に選ばせている入力（パス一覧、ラベル、走査範囲、成功 marker の解釈）を列挙する。その入力を git の差分や固定の走査根のように実行者が触れない値へ置き換えられるなら、ガードを足さずに自由度を削る。

## 関連ページ

- [ゲートの判定基準を被検査側が選べると検査は自己無効化する](../anti-patterns/gate-subject-chooses-anchor-self-invalidates.md)
- [LLM substitute placeholder は bash residue gate で fail-fast 化する](../patterns/placeholder-residue-gate-bash-fail-fast.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [レビュー結果](../../raw/reviews/20260904T091303Z-pr-2549.md)
- [fix 結果](../../raw/fixes/20260904T092650Z-pr-2549.md)
