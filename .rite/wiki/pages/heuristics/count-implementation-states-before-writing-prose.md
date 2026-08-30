---
type: "heuristics"
title: "実装の分岐を散文へ落とす前に、フラグの状態数と観測ラベルの値域を機械的に数える"
domain: "heuristics"
description: "hook や helper の挙動を仕様書の散文に書き下ろすとき、boolean に見えるフラグが実は 3 状態を取り、観測ラベルが 3 値を出しているのに「主経路 + 例外 1 つ」の二分岐として書いてしまう。この誤りは経路追加による腐りではなく執筆時点で既に偽であり、書く前にフラグの状態数と観測ラベルの値域を grep で数えれば機械的に防げる。"
created: "2026-08-30T04:57:39Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-30T04:57:39Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260830T043014Z-pr-2475.md"
  - type: "fixes"
    resource: "raw/fixes/20260830T043310Z-pr-2475.md"
  - type: "reviews"
    resource: "raw/reviews/20260830T044223Z-pr-2475.md"
tags: ["doc-implementation-sync", "branch-enumeration", "observability-label", "birth-defect", "spec-prose", "three-state-flag"]
confidence: high
---

# 実装の分岐を散文へ落とす前に、フラグの状態数と観測ラベルの値域を機械的に数える

## 概要

hook や helper の挙動を仕様書の散文に書き下ろすとき、boolean に見えるフラグが実は 3 状態を取り、観測ラベルが 3 値を出しているのに「主経路 + 例外 1 つ」の二分岐として書いてしまう。この誤りは経路追加による腐りではなく執筆時点で既に偽であり、書く前にフラグの状態数と観測ラベルの値域を grep で数えれば機械的に防げる。

## 詳細

### 事象 — docs 単独 PR の cycle 1 で HIGH 2 件が同一段落から出た

hook の未記載経路を仕様書へ追記する docs 単独 PR（+16 −5 行）で、cycle 1 のレビューが HIGH 2 件を返した。2 件はいずれも**新規に追記した段落**にあり、既存記述の腐りではなく執筆時点からの誤りだった。どちらも「実装が取りうる状態を 1 つ数え落とした」という同じ原因を持つ。

| 書いた主張 | 実体 |
|---|---|
| 「全同期成功時のみ前進する。部分失敗は再試行される」 | 実装には「失敗」と「skip」の 2 種があり、skip 側は成功フラグを落とさないまま PATCH を通して前進する。skip された transform はその phase で二度と走らない |
| 「短絡（往復 0）でなければ fetch して単一 PATCH（往復 2）」 | fetch の戻り値は 3 種あり、`no_comment` 初回検知は PATCH を発行せず（往復 1）負キャッシュを書いて前進する |

### 見落としを機械的に潰す 3 つの検査

1. **boolean に見えるフラグの状態数を数える**: 成功フラグを落とす経路（`_xf_ok=0`）だけを見て「成功 / 失敗」の 2 値と決めない。**フラグを落とさずに処理だけを飛ばす経路**（`_skip_progress=1`）があれば実質 3 状態であり、散文でも failed と skipped を別の言葉で書き分ける。契約を「全成功時のみ」と書くと skip が失敗側へ丸められ、読者は「次回再試行される」と誤解する

2. **観測ラベルの取りうる値を grep で列挙する**: `round_trips` のような観測ラベルを散文に書くなら、書く前に `grep -n 'round_trips=' <impl>` で実装中の全出現を数える。0 と 2 だけを書いて 1 を落としたことは、この 1 コマンドで検出できた。**ラベルの値域は網羅性を機械検出できる数少ない手掛かり**であり、分岐の数え落としに対する最も安いガードになる

3. **自分が言及した用語の定義が同じ節にあるか確認する**: 「`no_comment` fetch のあとに書かれる負キャッシュ」と書いたのに、その `no_comment` fetch 自体の帰結が節のどこにも無い、という参照の宙吊りが起きる。**新規追記を書き終えた直後に、自分が使った経路名・状態名がその節で定義されているかを読み返す**

### アンカーを持てない字面整合クラスは cycle を跨いで non-blocking のまま残る

同一文書内の矛盾（新規追記の断定が別の節の定義と食い違う）は、実行して観測できる誤動作を伴わないため `Verification:` の実測アンカーを構造的に持てない。実測必須ゲートは cycle 1 でこれを non-blocking へ降格し、cycle 2 で reviewer が指摘事項側に格上げして出し直しても再び降格した。**アンカーを持てない指摘に無理やりアンカーを付けさせるのではなく、mergeable 到達後の消化経路（NB digest sweep）で拾うのが設計上の受け皿**であり、reviewer 側は素直にアンカーなしで報告してよい。

### 「ついでの限定」が over-fix にならない判定基準

cycle 1 で両 reviewer が推奨事項として挙げた全称量化の限定（`Every failure along this path (A, B, C, D)` → `Each of the four failures listed here`）を、blocking fix と同じ文の中で同時に直した。cycle 2 の Over-fix Check はこれを over-fix ではないと判定した。**判定基準は「指摘 1 件に対し変更 1 箇所か」ではなく「機構が増えたか」**であり、新しい契約もガードも増えず surface area が net-flat で、しかも過剰主張が減る方向の変更なら、同一文への同時修正は妥当な最小差分に含まれる。

### 番号付きリストへの挿入は列挙変更として扱う

節の途中へステップを 1 つ挿入すると以降の番号が繰り下がる。これは Cross-File Impact Check の「列挙の変更」に当たり、**他ファイルから当該節のステップ番号を序数で参照している箇所が無いか grep で確認する**（本事例では 0 件だった）。コード側の enum に値を挿入するのと同じ扱いにする。

## 関連ページ

- [全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin](./universal-claim-prose-invalidated-by-path-addition.md)
- [汎用契約の表に経路固有の詳細を書かず下位節へ委譲する。ただし委譲は委譲先の網羅性を load-bearing にする](./generic-contract-table-delegates-path-specific-detail.md)
- [Step 番号参照は relative (Step N + 1) ではなく absolute (heading title 名 + Step 番号) で書く](../patterns/step-reference-absolute-heading-over-relative.md)

## ソース

- [PR #2475 review cycle 1 (前進契約の skip 経路取りこぼしと round_trips の値域欠落)](../../raw/reviews/20260830T043014Z-pr-2475.md)
- [PR #2475 fix results (状態数を数える / ラベル値域を grep で列挙する / 参照の宙吊りを検出する)](../../raw/fixes/20260830T043310Z-pr-2475.md)
- [PR #2475 review cycle 2 (ついでの限定は over-fix ではない / 番号繰り下げは列挙変更)](../../raw/reviews/20260830T044223Z-pr-2475.md)
