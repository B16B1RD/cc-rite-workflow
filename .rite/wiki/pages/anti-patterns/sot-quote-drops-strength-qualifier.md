---
type: "anti-patterns"
title: "SoT から事実を 1 つ引くとき、その事実に付いた強度 qualifier ごと持ってこないと別種の不正確さを新設する"
domain: "anti-patterns"
description: "SoT が「無条件 / best-effort / 実行モード依存」のような強度分類を要素ごとに持つとき、consumer 側が事実だけを抜き出すと強度が落ちて無条件の保証に化ける。部分列挙も同型で、列挙した根拠が結論を支えない状態になる。「SoT を複製しない」方針を掲げた文書では方針との自己矛盾にもなるため、引用ではなく件数 + ポインタに寄せる。"
created: "2026-07-29T02:10:00+09:00"
updated: "2026-07-29T02:10:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260728T160636Z-pr-2043.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T163233Z-pr-2043.md"
tags: ["sot", "drift", "documentation", "dry"]
confidence: high
---

# SoT から事実を 1 つ引くとき、その事実に付いた強度 qualifier ごと持ってこないと別種の不正確さを新設する

## 概要

SoT が複数の要素を列挙し、要素ごとに「無条件」「best-effort」「実行モード依存」のような**強度分類**を持っているとき、consumer 側の文書がそこから事実だけを抜き出すと強度が脱落する。抜き出した瞬間は正しく見えるが、SoT が付けていた条件が消えているため**無条件の保証**として読まれ、元の不正確さとは別種の不正確さになる。

PR #2043 はこれを 2 cycle 連続で踏んだ。cycle 1 は SoT の 4 経路のうち 2 経路だけを列挙し、その 2 経路がどちらも結論（「draft PR の人間レビューに委ねる」）を支えない状態だった。cycle 1 の指摘を直す過程で補った括弧書きが、今度は SoT が best-effort と明記している経路を「draft PR 上に残る」と無条件に言い切り、cycle 2 の指摘になった。

## 詳細

### 2 つの形

同じ「部分引用」でも現れ方が 2 つある。どちらも SoT の要素集合から一部を取り出す操作で起きる。

1. **部分列挙**: SoT が N 要素と書いているものを M 個（M < N）だけ列挙する。列挙自体が誤りとは限らないが、**その列挙が支えるはずの結論**と噛み合っているかは別問題。cycle 1 では列挙した 2 経路がいずれも draft PR 上に現れず（片方は条件付き出力、片方は gitignore 対象）、結論の根拠になっていなかった。
2. **強度 qualifier の脱落**: 要素は正しく挙げたが、SoT がその要素に付けている条件（best-effort / 失敗経路あり / 実行モード依存）を落とす。cycle 2 の括弧書き「(`pr_review.post_comment` 非依存で draft PR 上に残る)」は、前半（設定非依存）は SoT と一致していたが、後半の「残る」が SoT の best-effort 分類（失敗経路 7 種 + degraded 縮退）を落としていた。

### 方針との自己矛盾になる

PR #2043 の該当 bullet は冒頭で「blocking の定義式は本ファイルに複製せず SoT とする」と宣言していた。式は実際に複製していないが、同じ文の後段で SoT が持つ**別の**事実（記録先チャネル一覧）を部分複製していた。宣言した drift 回避方針と非対称な複製が同居している状態で、レビュアーはこれを「自己矛盾かつ新規 drift site」として指摘した。

方針を掲げた文書ほど、方針の適用範囲を「定義式だけ」に狭めていないかを見る。SoT から引くもの全般に効かせるつもりなら、事実の引用も同じ扱いにする。

### 修正の向き

**件数 + SoT ポインタに寄せる**のが最も drift しにくい。

- 悪い: `ステップ 6.1.d の PR 記録コメント（post_comment 非依存で draft PR 上に残る）・ステップ 5.4 統合レポート・永続 JSON に記録される`
- ましな最小修正: 括弧を落として経路名だけ残す（強度を主張しない）
- 良い: `記録先 4 経路（SoT: severity-levels.md §実測必須ゲート）に記録される`

件数だけを持つ形なら、SoT 側で経路の条件が変わっても consumer は陳腐化しない。経路名まで書くと「どれが無条件でどれが best-effort か」を書かない限り不完全なままになり、書けば書いたで drift site が太る。

### 検出の手掛かり

consumer 側の文に**断定形の述語**（「残る」「必ず記録される」「保証される」）が現れたら、SoT の当該要素にその強度が実際に書かれているかを確認する。SoT が「(1) は無条件、(2) は best-effort」のような明示的な分類文を持つ場合は特に、その分類文を読まずに要素名だけ転記していないかを疑う。

## 関連ページ

- [SoT-reviewer 表現 drift: pos/neg 方向の差で派生記述が silent drift する](./sot-reviewer-expression-drift.md)
- [カテゴリ列挙の圧縮はブロッキング/informational の分類を SoT で確認してから削る](../heuristics/enumeration-compression-verify-blocking-classification.md)
- [doc の例示語彙は定義元 (SoT) と突合してから書く](../heuristics/illustrative-example-vocabulary-sot-check.md)

## ソース

- [PR #2043 review results](../../raw/reviews/20260728T160636Z-pr-2043.md)
- [PR #2043 review results (cycle 2)](../../raw/reviews/20260728T163233Z-pr-2043.md)
