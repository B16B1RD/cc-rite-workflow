---
type: "patterns"
title: "実測アンカーの repro に書くパイプは U+00A6 へ置換する"
domain: "patterns"
description: "実測必須ゲートは `Verification:` アンカーの full match に blocking を委ねる。パイプや空の左辺、値域外の種別ラベルは match を壊すか空振りさせ、機械カテゴリまで exclusion なし class B へ倒すと blocking が落ちる。"
created: "2026-08-01T00:21:06+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260731T060239Z-pr-2070.md"
  - type: "fixes"
    resource: "raw/fixes/20260731T060927Z-pr-2070.md"
  - type: "reviews"
    resource: "raw/reviews/20260830T093009Z-pr-2483.md"
  - type: "reviews"
    resource: "raw/reviews/20260904T004239Z-pr-2544.md"
  - type: "fixes"
    resource: "raw/fixes/20260904T005810Z-pr-2544.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-04T01:26:01Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-08-30T09:45:00Z"
  - by: "rite-wiki-ingest/grok-4.6"
    at: "2026-09-04T01:26:01Z"
---

# 実測アンカーの repro に書くパイプは U+00A6 へ置換する

## 概要

実測必須ゲートは `Verification:` アンカーの full match に blocking を委ねる。パイプや空の左辺、値域外の種別ラベルは match を壊すか空振りさせ、機械カテゴリまで exclusion なし class B へ倒すと blocking が落ちる。アンカーは Markdown テーブルのセル内に置かれるため、検出側はセル境界を守る `[^|]` を含む。repro に raw pipe（`|`）を書くと full match が成立せず、実測を伴う指摘が「非実測」として non-blocking へ無音で降格する。

## 詳細

起点事例では test reviewer が変異注入で実測済みだったにもかかわらず、repro に awk の regex 由来の `\|` が残ったためアンカー検出を通らず降格した。markdown のエスケープ `\|` は表のレンダリングには効くが、**検出側の `[^|]` はエスケープを解釈しない**ので通らない。

対処は `¦`（U+00A6 BROKEN BAR）への置換である。視覚的にパイプと判別でき、検出 regex のセル境界判定にも干渉しない。bash / jq 中心のリポジトリでは repro にパイプが入るのが常態であるため、この降格は運用上頻発しうる。

この事象は「機械化は依存を消さず依存先を移す」の具体例でもある（[強制層の機械化は裁量を消すが依存を消さない](../heuristics/mechanization-moves-dependency-not-removes-it.md)）。分類を regex full match へ委ねた瞬間、判定は reviewer の記述忠実性に依存するようになった。実測必須ゲートを helper へ機械化した後続の作業では同種の摩擦がさらに先鋭化し、**アンカー書式そのものについての repro を書くのに hex escape が必要**になっている。書式契約を扱う指摘が、その書式契約の中では表現できないという状況であり、契約の厳しさの傍証になる。

**適用条件**: `Verification:` アンカー付きのレビュー指摘を書くとき。repro にパイプ・改行タグを含める必要がある場合は、パイプを `¦` へ、改行を `<br>` のまま（日本語句点へ潰さない）保つ。

### 種別ラベルの値域も同じ regex に縛られる（`static` は受理されない）

パイプ以外に、`Verification:` の**種別ラベル**も検出 regex の値域に縛られる。受理されるのは `repro` / `failing_test` の 2 値のみで、`Verification: static => ...` のように第 3 の語を書くと full regex に match せず「未判定」として blocking に据え置かれる。帰結クラス降格政策（5.3.0.C）も未判定を class A 固定として扱うため、**静的読解で足りる指摘が降格されないまま blocking 枠を占め、余分な fix cycle を 1 周させる**。

実測: reviewer が `Verification: static => <ファイルを Read して確認>` を添えた LOW 指摘に対し、実測必須ゲートは `MEASURED_UNDETERMINED_ON_ANCHOR=1; count=1; cause=anchor_unparseable` を返し `blocking=1` を維持した。降格ゲートも `CLASS_DEMOTION_UNDETERMINED_MEASURED=1` で class A 側へ固定した。

静的検証で足りる指摘には `Likelihood-Evidence: static_verification => ...` だけを付け、`Verification:` は付けない。実行時の再現手順を持たない指摘にアンカーを付けようとすると、値域外のラベルを発明することになる。

**この失敗は機械検出できる**（reviewer 出力の `Verification:` 行に対する種別ラベルの値域検査）。reviewer prompt の規約だけに頼らず検出器へ移す候補として記録する。

### 左辺が空のアンカーは「書いた」ことにならない

`Verification: repro  => observed` のように矢印の左辺（再現コマンド）が空白だけの形は、見た目はアンカーだが実測手順が無い。検出 regex が `[^|]+` を左辺に許すと、空白だけの左辺でも full match し、未実測の指摘が実測済みとして通る。正規形は左辺が非空で、矢印は 1 つ、右辺も非空。空左辺を reject する検査は機械化できる。

### exclusion なし class B 降格は機械カテゴリを class A 固定する

実測ゲートのあと、除外条件を持たない class B を non-blocking へ倒す政策は、番号参照のような機械検出カテゴリまで飲み込む。機械カテゴリは「除外が無い」こと自体が欠陥の本体なので、category を class A 固定しないと blocking が落ち、検出器があるのに指摘が消える。降格述語は機械カテゴリを先に除外してから exclusion なし class B を見る。

## 関連ページ

- [強制層の機械化は裁量を消すが依存を消さない](../heuristics/mechanization-moves-dependency-not-removes-it.md)
- [緩い検出述語の出力を停止条件へ昇格させてはならない](../anti-patterns/loose-detector-predicate-promoted-to-stop-condition.md)

## ソース

- [レビュー結果](../../raw/reviews/20260731T060239Z-pr-2070.md)
- [fix 結果](../../raw/fixes/20260731T060927Z-pr-2070.md)
- [種別ラベル `static` が未判定に倒れ blocking に残る](../../raw/reviews/20260830T093009Z-pr-2483.md)
- [裸番号検出の cycle 1 レビュー結果](../../raw/reviews/20260904T004239Z-pr-2544.md)
- [裸番号検出の修正結果](../../raw/fixes/20260904T005810Z-pr-2544.md)
