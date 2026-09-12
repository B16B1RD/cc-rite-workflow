---
type: "heuristics"
title: "テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する"
domain: "heuristics"
description: "複数の不変量（集合差分 I1/I2 + 行内整合 I3 等）を持つ検証スクリプトのテストでは、fixture 変異の設計を誤ると「テストは green だが特定の不変量・guard を削除しても green のまま」という vacuous coverage が生まれる。"
created: "2026-07-03T18:30:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260703T164934Z-pr-1743.md"
  - type: "fixes"
    resource: "raw/fixes/20260703T165654Z-pr-1743.md"
  - type: "reviews"
    resource: "raw/reviews/20260703T180609Z-pr-1743.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T033632Z-pr-2112.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T040711Z-pr-2112.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T043752Z-pr-2112.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T050456Z-pr-2112.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T182103Z-pr-2751.md"
  - type: "fixes"
    resource: "raw/fixes/20260912T182702Z-pr-2751.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T183826Z-pr-2751.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T225833Z-pr-2753.md"
tags: ["test", "fixture", "mutation", "invariant", "coverage"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-12T23:20:00+00:00" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-12T18:43:00+00:00" }
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-12T23:20:00+00:00" }
---

# テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する

## 概要

複数の不変量（集合差分 I1/I2 + 行内整合 I3 等）を持つ検証スクリプトのテストでは、fixture 変異の設計を誤ると「テストは green だが特定の不変量・guard を削除しても green のまま」という vacuous coverage が生まれる。変異がどの不変量を発火させるかは推測せず実行で確認し、各不変量・guard を**単独で** kill する配置（均衡入替 / reverse 方向の明示 pin / guard 射程内への decoy 配置）を採る。

## 詳細

起点事例（reviewer-registry-drift-check.test.sh、TC-1〜TC-11）の設計・レビューで実測した 3 つの配置原則。

### 1. 行内整合の分離検証には均衡入替（双方向 swap）を使う

- 一方向差し替え（charlie 行の Agent セルだけを delta に変更）は、charlie-reviewer.md が集合から消えるため**集合系不変量（I1/I2）も同時に発火**し、行内整合チェック（I3）の固有価値を分離検証できない
- 均衡入替（charlie 行 Agent=delta かつ delta 行 Agent=charlie）なら集合が保存され、I3 のみが発火する。さらに「集合差分 finding（"only in ..."）が混入しない」ことを負の assert で確認すると真に I3-isolated になる（TC-6）
- fixture 変異のコメントに「どの不変量が発火するか」を書く場合は、実行して観測してから書く（推測コメントは cycle 1 で事実不一致 MEDIUM として検出された）

### 2. 双方向チェックの reverse 方向は明示 TC で pin する

- I1 が「agents/ ⇔ Type Identifiers 双方向」でも、テストが forward 方向（agent 追加 → 表に無い）しか無いと、reverse 方向の report_diff 呼び出しを削除しても全 TC が green のまま（未 pin）
- reverse 方向（表に行があるのに agent プロファイルが無い = 存在しない subagent を spawn する failure mode）を単独で発火させる fixture（orphan 行の挿入）+ 方向ラベルの grep assert を明示 TC として追加する（TC-9）

### 3. guard を exercise する decoy は guard の射程内に置く

- 「セクション内散文がテーブル比較へ bleed しない」ための行フィルタ（`/^\|/`）を検証するつもりの decoy を**独立セクション外**に置くと、セクション境界除外だけで decoy が落ち、行フィルタを削除する mutation が生き残る（cycle 2 レビューで検出された coverage gap）
- decoy は検証したい guard だけが除外を担う位置（= 抽出対象セクションの内側の非テーブル行）に置き、負の assert で「decoy が finding に出ない」ことを固定する

### 4. 連言述語 `A ∧ B` の fixture は項の数だけ用意する

ある PR の cycle 2 / cycle 3 で、この原則が **連言述語** に対して繰り返し破られた。negative control を 2 本置いても、**どちらも 2 つの conjunct を同時に false にしていた**ため、検出できるのは連言全体の削除だけだった。片側だけを弱める mutation は全部生存する。

- 行アンカー `^` と `$` を pin した fixture は decoy の**両側**に非空白を置いていた → 両方を同時に外す mutation しか落とせず、片方だけを外した 4 mutant が生存
- 「1 行目が marker ∧ 最終非空行が sentinel」の 2 連言でも同じ形が再発 → conjunct 削除 / 前方一致の弱化 / 等値の弱化、3 mutant が生存

正しい配置は次の 2 点。

- **各項を独立に殺す fixture を項の数だけ作る**。`A ∧ B` に対し「A のみ false」「B のみ false」の 2 本。行アンカーなら「行頭に対象 + 後ろに散文」（`$` を殺す）と「前に散文 + 行末に対象」（`^` を殺す）の 2 形状
- **位置固定を持つ述語（前方一致 / 最終行の等値）には「値は含むが位置が違う」形をさらに足す**。前方一致を部分一致へ弱める mutation はそれでしか落ちない

この失敗が cycle をまたいで 2 度起きた点が重要 — cycle 1 で「fixture が failure mode を再現していない」を学んだ直後に、**その学びで追加した fixture 自身が同じ穴を持っていた**。原則を知っていることと、追加した fixture に mutation を当てて確かめることは別である。

### 5. 観測経路が片方しか通っていないと、もう片方の mutation が生存する

同一の形状定義を read 側（抽出）と write 側（除去）で共有している場合、read 側の TC だけでは write 側を狭める mutation が落ちない。write 側が別経路（fallback 等）を通らないと発火しないためである。**形状定義を共有しているなら、pin も両方の経路で張る。**

定義が共有ではなく**複製**されている場合はさらに弱い。手順書の fenced bash で、同じ境界の条件式を「番号を数える範囲を切り出す awk」と「追記位置を決める awk」の 2 か所に書いた例では、「数える範囲と書き込む範囲が一致する」という不変条件をコメントと設計理由の文でしか支えていなかった。テストの境界ループは追記側の awk しか通しておらず、新しい fixture にもその境界の種類が無かったため、切り出し側から境界を 1 つ消す変異を当ててもスイートは緑のままだった。

- 複製した条件式は、文書から両方を抜き出して**件数と内容の一致を assert する**か、**両方の awk を同じ境界 fixture で回す**
- 境界 fixture は、条件式が列挙する境界の種類をすべて 1 つずつ含める（1 種類でも欠けると、その境界を消す変異が生き残る）

### 6. negative control は「到達したうえで発火しない」ことを確認する

「誤検出しないこと」を assert する TC が、fixture の都合で目的の分岐へ一度も到達していないケースが同 PR で 2 件見つかった。正規の入力を併記した fixture では前段の判定が成功してしまい、検証したい分岐に入らない。assert は常に真になり識別力はゼロ。

negative control の fixture は、**検証したい分岐に確実に入る形にする**（前段が成功する要素を併記しない）。追加時に対応する mutation を当て、落ちなければ到達していないと判断する。

### 7. 同じコマンドを複数回呼ぶ手順の失敗注入は、呼び出し回数ごとに分ける

1 つの手順が同じコマンドを 2 回呼び、それぞれの終了コードを別々に捕捉していることがある（例: 挿入位置を awk で決め、本文を awk で組み立てる）。このとき失敗注入の mock が**そのコマンドの全呼び出しを失敗させる**と、1 回目で必ず失敗が立つ。そのため 2 回目の捕捉を消してもテストは緑のままになり、2 回目だけが途中で落ちる実害（本文の切り詰めと成功 marker）を検出できない。

- mock に呼び出し回数を数えさせ、**指定回目だけ失敗させ、それ以外は実コマンドへ exec する**。ケースは「何回目を・どの形（異常終了 / 空出力）で落とすか」の組で並べる
- 単独固定できたかは、捕捉を 1 つずつ外す変異で**各変異がちょうど 1 ケースだけを落とす**ことで判定する。修正前のテストに同じ変異を当てて素通りすることも示すと、欠陥が実在したことまで裏付けられる
- この形の mock の正しさは 3 点で決まる。回数ログを実行ごとに空にしていること、実コマンドのパスを mock が PATH に入る**前**に解決していること（mock が自分を exec する再帰を防ぐ）、関数呼び出しの前に置いた一時代入が子プロセスまで届くこと

### 検証の決定打

guard・不変量の TC を追加したら、worktree-only mutation（当該 guard / report_diff 呼び出しの削除、列挿入等）を実機注入して「その TC だけが FAIL する」ことを確認する。見た目の構造同型ではなく mutation の kill 実績が non-vacuous coverage の証明になる。

**mutation は意味だけを弱める形で書く。** 括弧の対応を崩す変異は FAIL 数が跳ね上がる（同 PR では 31）が、それは構文エラーが全 TC を巻き込んだだけで、意味的な弱化が検出されている証拠にはならない。実行ログに構文エラーが 0 件であることを確認したうえで FAIL 数を読む。

**修正した箇所の mutation は、修正後の軸で取り直す。** 修正でアンカーの形が変われば前 cycle の mutant 定義は無効になる。同じラベルの mutation でも中身が変わるため、`^` の除去と `[[:space:]]*` の除去を別軸として測り直して初めて生存が見つかった。

## 関連ページ

- [位置依存の表パースには検査行数ガードを対にする（silent false-pass 遮断）](../patterns/positional-parse-row-count-guard.md)
- [静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く](./static-pin-semantic-allowlist-not-notation-denylist.md)
- [抽出述語の厳格化は「壊れた入力」と「入力なし」を同一経路へ畳み、fail-loud を構造的に壊す](../anti-patterns/strict-predicate-collapses-broken-into-absent.md)

## ソース

- [一方向差し替えの不変量誤帰属 + reverse 未 pin を検出](../../raw/reviews/20260703T164934Z-pr-1743.md)
- [均衡入替 TC-6 + reverse pin TC-9 を適用](../../raw/fixes/20260703T165654Z-pr-1743.md)
- [pipe-filter decoy 配置の coverage gap を推奨事項として検出](../../raw/reviews/20260703T180609Z-pr-1743.md)
- [行アンカー `^` / `$` の片側 mutant が 4 件生存](../../raw/reviews/20260805T033632Z-pr-2112.md)
- [項ごとの fixture と read/write 両経路の pin を適用](../../raw/fixes/20260805T040711Z-pr-2112.md)
- [連言 2 項の同時 false による識別力ゼロと、到達しない negative control を検出](../../raw/reviews/20260805T043752Z-pr-2112.md)
- [項ごとの pin 分割と mutation 軸の取り直しを適用](../../raw/fixes/20260805T050456Z-pr-2112.md)
- [全呼び出しを失敗させる mock が 2 つ目の終了コード捕捉を固定していないことを検出](../../raw/reviews/20260912T182103Z-pr-2751.md)
- [失敗注入を呼び出し回数ごとに分けた修正](../../raw/fixes/20260912T182702Z-pr-2751.md)
- [各捕捉の単独固定を変異表で確認したレビュー結果](../../raw/reviews/20260912T183826Z-pr-2751.md)
- [複製した境界条件式の同一性がテストで固定されていないことを検出したレビュー結果](../../raw/reviews/20260912T225833Z-pr-2753.md)
