---
type: "heuristics"
title: "散文を契約とする設計では規約を強化するたび「まだ塞げていない入力クラス」が出るため、review-fix ループに終端がない"
domain: "heuristics"
promote: rite-plugin
description: "過去のレビュー事例の指摘推移は 5→5→6→6→1→1→4→6→4→7 で収束しなかった。"
created: "2026-07-26T10:05:51Z"
updated: "2026-07-29T02:10:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260726T044237Z-pr-2022.md"
  - type: "reviews"
    ref: "raw/reviews/20260726T035338Z-pr-2022.md"
  - type: "reviews"
    ref: "raw/reviews/20260726T020559Z-pr-2022.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T040115Z-pr-2022.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T021138Z-pr-2022.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T160636Z-pr-2043.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T163233Z-pr-2043.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T165431Z-pr-2043.md"
tags: []
confidence: high
---

# 散文を契約とする設計では規約を強化するたび「まだ塞げていない入力クラス」が出るため、review-fix ループに終端がない

## 概要

起点事例の指摘推移は 5→5→6→6→1→1→4→6→4→7 で収束しなかった。原因は品質不足ではなく構造にある。marker 照合の規約を段階的に強化するたびに、その規約が塞げていない入力クラスが新たに可視化され、次 cycle の指摘になった。いずれの指摘も正しく runtime 実測を伴っていたが、この階段には終端がない。

## 詳細

### 観測された階段

1. prefix アンカーを導入 → 「行頭も要る」（行中の偽 marker）
2. 行頭一致を導入 → 「複数行 stderr の 2 行目は列 0 に着地するのでデリミタが要る」
3. `branch=` スコープを導入 → 「同一ブランチ再実行では `branch=` が一致するので recency が要る」
4. pin を 2 family に追加 → 「3 個目の family に pin がない」

### 終端判断のシグナル

**指摘の主成分が「前 cycle の修正が作った欠陥」または「規約の適用範囲」に移ったら、ループが価値を生まなくなった合図。** cycle 8 では 6 件のうち 3 件が直前 cycle の修正自身が作った欠陥だった。AC が全充足済みなら、自作の矛盾だけ解消し、残りを Decision Log に記録して終端するのが正しい判断。

サーキットブレーカーはこの判断をユーザーへ委ねる仕組みであり、機械的な cycle 数だけでなく **指摘の性質の変化** を観察材料として提示すべきである。

### 上限を伝えると収束方向に働く

cycle 5 で「次サイクルはサーキットブレーカーが発火する」と reviewer に明示したところ、5 名中 4 名が前 cycle の推奨を follow-up へ落として「マージ可」を出し、1 名だけが新規の false-negative を実測で見つけた。**判定の厳格さを求める文脈を与えると、Observed Likelihood Gate の判定が厳格化して真にブロックすべきものだけが残る。**

### 「規約を新設する修正」は自己適用の検査を同時に要求する

規約を新設した同じコミットで、その規約を破る実装を作る事故が繰り返し起きた:

- リモート側 fallback を「marker 不在 = 未確認」へ反転し禁止文まで書きながら、7 行上のローカル側 fallback を `x`（= marker 不在を成功と読む形）のまま残した。同一 bash fence 内の 2 family は同じ条件で同時に不在になるため、同一到達条件に正反対の意味を割り当てる矛盾になった。3 reviewer が独立に指摘。
- 「負の assertion は非アンカーにする」規約をファイル冒頭に新設した同一コミットで、追加した TC の負 assertion にアンカーを付けた。2 reviewer が独立に指摘。

対処: **規約を新設したら、同一ファイル内の類似箇所すべてに適用したかを機械的に確認する。**「2 箇所に適用して 3 個目を落とす」は 3 cycle 連続で起きた。また **規約の適用範囲を自己限定する書き方（「以下のルールで『X』と書いた箇所」）は否定形（fallback）に届かない穴を作る** ため、肯定・否定の両方を明示的に含める。

### 収束シグナルとしての reviewer 合意

- **複数 reviewer の design_confirmation が同じ解に収束したら、それは設計上の実欠陥のシグナル。** cycle 7 では 6 名中 3 名が独立に success marker の追加へ到達した。
- **レビュアーの自己訂正を歓迎する。** security reviewer は前 cycle の「アンカー化により marker 偽造は構造的に不可能」という positive finding を、`git check-ref-format` の実測に基づき「偽造不能なのは literal 注入に限られる」と下方修正した。過大な安全主張は次サイクルの探索を止める点で、誤った rationale と同じ害を持つ。
- **「規約が割れている」という主張は、割れている両側を数え直してから出す。** cycle 4 の「3 対 1 の少数派」という design_confirmation は、実際には 2 対 2 であったとして次 cycle で本人が取り下げた。

### 実測必須ゲート下では docs PR の終端が構造的に「人間の打ち切り」になる

実測必須ゲート（`Verification:` アンカーの無い指摘を non-blocking へ降格する）を通すと、**ドキュメント精度の指摘は構造的に non-blocking へ寄る**。散文の不正確さは runtime 実測を添付できる性質のものが少なく、reviewer が誠実であるほどアンカーを捏造せず `measured=false` として報告するためである。

散文 2 行の docs PR 事例は 3 cycle 連続で MEDIUM 指摘が出たが、いずれも `Likelihood-Evidence` は持ち `Verification` は持たないため毎回 non-blocking に降格され、blocking 指摘 0 件で `[review:mergeable]` に到達した。指摘の中身は cycle ごとに別（cycle 1 = 記録先の部分列挙、cycle 2 = cycle 1 の修正が落とした強度 qualifier、cycle 3 = SoT の 4 経路中 3 経路）で、内容としては本ページ冒頭の「階段」と同じ構造だった。

**帰結**: サーキットブレーカー（`safety.max_review_cycles`）は blocking 指摘の有無を見ないため、この形の振動では発火しない。ループは毎回「正常終了」する。終端は人間が打ち切るしかない。指摘が non-blocking のまま cycle ごとに別の側面へ移り始めたら、AC 充足を確認して打ち切り、残りを non-blocking 記録に委ねる。

**加えて cycle counter のリセット挙動に注意する。** `/rite:ready` を挟んで `/rite:iterate` へ再入場すると、flow-state の phase が `review`/`fix` 以外（`ready`）になっているため cycle counter が fresh 判定で 0 リセットされる（仕様どおり）。ready → 再レビューを繰り返す運用では、ブレーカーは累積レビュー回数を数えない。完了通知の cycle 表示（`cycle 1/5`）を累積回数と読まないこと。

### CI の赤は flake と回帰を切り分ける

赤を見たら (1) 失敗テストが本 PR の変更ファイルに含まれるか、(2) 直前コミットの同一ワークフロー、(3) 同一 SHA の別ワークフロー、(4) ログの `Broken pipe` 等、の 4 点を比べる。推定で済ませず **同一 SHA で再実行** し、failure → success なら flake が確定し以後のサイクルで蒸し返さない。

なお `gh run list` の run 結論は `continue-on-error` のレグを隠すため、matrix CI では `gh run view <id> --json jobs` で job 単位の結論まで見る。ローカルのフルスイート green を「テスト green」と報告してはいけない。

## 関連ページ

- [累積対策 PR の 3 cycle 収束記録: cross-validation boost + cycle 2 minor drift + cycle 3 mergeable](./accumulated-pr-three-cycle-convergence.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [reviewer の regression 主張は revert test (git show / git diff) で PR 由来か pre-existing かを独立検証する](./reviewer-regression-claim-revert-test-attribution.md)
- [SoT から事実を 1 つ引くとき、その事実に付いた強度 qualifier ごと持ってこないと別種の不正確さを新設する](../anti-patterns/sot-quote-drops-strength-qualifier.md)
- [「SoT が N 個と書いている」だけでは load-bearing 性は決まらない — 依存側が名指ししている要素を読む](./load-bearing-by-named-dependency-not-count.md)

## ソース

- [PR #2022 review results (cycle 10)](../../raw/reviews/20260726T044237Z-pr-2022.md)
- [PR #2022 review results (cycle 8)](../../raw/reviews/20260726T035338Z-pr-2022.md)
- [PR #2022 review results (cycle 5)](../../raw/reviews/20260726T020559Z-pr-2022.md)
- [PR #2043 review results](../../raw/reviews/20260728T160636Z-pr-2043.md)
- [PR #2043 review results (cycle 2)](../../raw/reviews/20260728T163233Z-pr-2043.md)
- [PR #2043 review results (cycle 3)](../../raw/reviews/20260728T165431Z-pr-2043.md)
