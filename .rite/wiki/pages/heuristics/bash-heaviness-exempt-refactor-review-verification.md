---
title: "operational-bash-heaviness の exempt / pipe-refactor レビューは claim を信用せず empirical 検証で gate する"
domain: "heuristics"
created: "2026-06-01T11:39:00+00:00"
updated: "2026-06-01T11:39:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260601T111247Z-pr-1233.md"
tags: ["review-discipline", "bash-heaviness", "drift-check-ignore", "empirical-verification", "pre-existing-gate", "pipe-refactor"]
confidence: medium
---

# operational-bash-heaviness の exempt / pipe-refactor レビューは claim を信用せず empirical 検証で gate する

## 概要

`bash-heaviness-check.sh` が surface した heavy operational bash ブロックを「pipe refactor / `drift-check-ignore` exempt」で解消する PR のレビューは、PR body・marker コメント・先例の主張をそのまま信用すると false-positive (虚偽の指摘) と false-negative (冗長 exempt・未検証 helper の見逃し) の両方を生む。canonical 規範: (1) exempt marker の正当性、(2) pipe refactor 先の helper capability、(3) 「先例との非対称」が本 PR 由来か否か、の 3 点をいずれも **実機 / Read / revert test で empirical に検証してから可否を判定する**。起点事例 (issue/* 3 ブロックを pipe refactor 1 / exempt 2 で解消、0 blocking findings) で 2 reviewer が独立にこの protocol を適用し、claim を裏取りした上で 0 件収束した実例。

## 詳細

### 1. `drift-check-ignore` exempt marker の正当性は 3 点で検証する

exempt marker は「意図的に重さを残す」宣言だが、宣言だけでは正当性を保証しない。以下 3 点を照合して初めて「可」と判定できる:

1. **format 認識の実機確認**: `bash-heaviness-check.sh` が当該 marker を **per-block で認識する書式か**を実機で確認する。marker がブロックに紐付かない位置にあると silent に無効化される。
2. **除去シミュレーション (冗長 exempt 検出)**: marker を一時的に除去すると実際に flag されるかを確認する。除去しても flag されない exempt は **冗長** であり、付けるべきでない (将来の reader に「意図的に残した重さ」という誤った signal を与える)。
3. **参照の fact-check**: marker コメントが参照する Issue 番号・test 名 (例: `create-md-invocation-symmetry.test.sh` の TC-1/TC-2) が **実在し、主張内容が正しいか**を Read で照合する。コメントの主張をそのまま信用しない。

起点事例では `issue/create.md` §4.3 / `issue/close.md` §4.6.3 の 2 exempt がいずれも上記 3 点を満たし、かつ marker 行に**理由コメント**を併記して「単なる silence でなく意図表明」になっていることを確認した上で「可」とした。

### 2. pipe refactor の「可」は helper の stdin 対応を Read で確認してから

入れ子 `$()` を `jq -n … | helper.sh` の pipe 形へ refactor する際は、helper が **stdin 入力に対応済み**であることを Read で実機確認してから「可」とする。positional 引数のみ受理する helper を pipe 化すると silent に空入力で動く。

起点事例では `create-issue-with-projects.sh` が L137-141 で `INPUT_JSON="$(cat)"` により stdin を受理することを Read で確認した。pipe 形の先例 (`pr/review.md` §3992、#1193 #5) が存在することも併せて根拠とした。

### 3. 「先例との非対称」は revert test で pre-existing 判定し、本 PR diff 由来でなければ finding にしない

pipe refactor 先が先例と invocation 形は対称でも、先例側が後から獲得したガード (例: empty-result / write-failure / empty-body の 3 ガード) を欠くことがある。この非対称を見つけても、それが **本 PR の diff で導入されたものでない限り finding にしてはならない**。

判定手順 (revert test): `HEAD~1` (= 本 PR 適用前) の旧コードを確認し、そこにも同じガードが不在なら **pre-existing** と確定する。本 PR が非対称を導入したのでなければ、別 Issue 候補に回す。

起点事例では `fingerprint-cycling.md` §4 の pipe refactor が先例 `pr/review.md` §3992 の 3 ガードを欠いていたが、両 reviewer が独立に revert test を適用して旧 nested 形にもガード不在 (= pre-existing) と判定し、本 PR 指摘から正しく除外して別 Issue 候補に回した。「先例側に後から追加されたガードが旧コードに伝播していない」非対称は [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の shape を持つが、本 PR の diff 由来でなければ「正しく棄却する」運用が機能した実例。

### なぜ 3 点とも empirical 検証が必要か

- exempt marker / PR body / 先例コメントは **author の主張**であり、reviewer の logical reasoning は「もっともらしさ」で高速 confirm しやすい (anchoring / confirmation bias)。
- 実機確認 (format 認識・除去シミュレーション)・Read (helper capability)・revert test (pre-existing 判定) は、reasoning がどれほど logically sound でも **observable な事実**で裏取りする第三者的 gate を提供する。
- この gate を欠くと、虚偽の非対称指摘 (false-positive) と冗長 exempt・未検証 helper (false-negative) が同時に通過する。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [`rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する](./scope-creep-rejection-empirical-gate.md)
- [委譲リファクタの動作保持は原実装との差分テストで機械的に立証する](./delegation-refactor-differential-test-equivalence.md)

## ソース

- [PR #1233 review results](../../raw/reviews/20260601T111247Z-pr-1233.md)
