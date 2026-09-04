---
type: "heuristics"
title: "機械的制裁を伴う規約は「何をすると」「何がどこまで」落ちるかを書く — 予約グリフ・予約文字列も導入と同時に文書化する"
domain: "heuristics"
description: "規約に機械的な制裁（CI で落ちる）を伴わせるなら、**発火条件と制裁の範囲**を文書に書かなければ、規約どおりに従ったコントリビューターが blocking gate を落とす。"
created: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260725T024207Z-pr-2013.md"
  - type: "reviews"
    resource: "raw/reviews/20260725T032345Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260725T025323Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260725T033607Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260725T004542Z-pr-2013.md"
tags: ["convention", "documentation", "blast-radius", "reserved-token", "blocking-gate"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-25T07:05:21Z" }
---

# 機械的制裁を伴う規約は「何をすると」「何がどこまで」落ちるかを書く

## 概要

規約に機械的な制裁（CI で落ちる）を伴わせるなら、**発火条件と制裁の範囲**を文書に書かなければ、規約どおりに従ったコントリビューターが blocking gate を落とす。起点事例では「skip を使え、bare `echo` は禁止」とだけ書かれた規約の実装が「⏭️ 数とサマリ件数が一致しないと **スイート全体が exit 1**」で、件数抽出は厳密に 2 形のみだった。in-tree には `print_summary` を使わないテストが 48 本、うち 25 本は "skipped" 文字列を持たず、そこへ手順どおり `skip` を足すと blocking gate が落ちる状態だった。

## 詳細

### 書くべき 3 項目

| 項目 | 例（skip 会計の場合） |
|---|---|
| **発火条件** | ⏭️ マーカー数とサマリ行の skip 件数が一致しない |
| **制裁の範囲** | ファイル局所ではなく **スイート全体が exit 1** |
| **前提の所在** | 件数抽出は `SKIP: N` と `Results: ..., N skipped` の厳密に 2 形のみ |

「何が禁止か」だけでは足りない。**従った結果どうなるか**が書かれていないと規約は実行できない。

### 禁止事項は実在するアンチパターンを grep してから書く

規約が禁止したのは bare `echo` だったが、実際のアンチパターンは `pass "... skipped"`（PASS を水増ししたうえで突き合わせも素通りする）で、**こちらが規則の対象外のまま**残った。

> **規則**: 禁止事項を列挙する前に、実際にリポジトリで見つかるアンチパターンを grep する。

### 予約グリフ / 予約文字列の制約

`⏭️` はマーカーとして導入したが、実装は各テストの stdout+stderr **全体** を `grep -c` するため、**被テストスクリプトがこのグリフを出力しただけでスイート全体が落ちる**。実在の供給源（`backfill-sub-issues.sh:171`）があり、それを実行するテストが 1 本追加された瞬間に発火する。しかも失敗メッセージは無関係な自分のサマリ行を疑わせる。

> **規則**: 「この文字列/グリフはスイート横断で予約」という制約は、**導入と同時に** 文書化する。走査範囲（stdout のみか stderr 込みか、行頭 anchor の有無）も併記する。

### 複製を強制する機械的検査も同じ

`_timeout` は 6 ファイルに inline 複製され、TC-7 が byte-identity を、TC-8 が guard 存在を強制する。しかし CONTRIBUTING は「`_test-helpers.sh` が提供し source 時に abort する」としか書いておらず、**6 分の 1 の経路しか説明していなかった**。文書だけを読んで `_test-helpers.sh` を直したコントリビューターは TC-7 で落ちる。

> **規則**: 機械的検査が「複数箇所の同時変更」を要求するなら、その要求と **floor 値のハードコード位置**（統合時に触る場所）まで書く。

### 規約が依拠する前提を同じ文書内で確立する

「blocking gate では fail させよ」という規約を CONTRIBUTING に追加したが、同文書は **クロスプラットフォーム CI マトリクスの存在を一度も説明していなかった**。読者はどの leg が blocking か判断できず、規約を実行できない。

> **規則**: 前提はハードコードせず **SoT へのポインタ** で書く（「どの leg が blocking かは `ci.yml` が宣言する」）。将来 blocking が入れ替わっても文書が陳腐化しない。

ただしこの抽象化を宣言したら、**同じ文書内の他の記述がその抽象を破っていないか grep で確認する**。起点事例では「ci.yml が宣言するのでこの規則は入れ替わっても生き残る」と書いた段落と、「a shadowed or missing tool **on Linux** must not silently drop coverage」と Linux を名指しした手順が同一ブロック内で共存していた（実装は後者に倒れていた）。実装が具体に倒れているなら **宣言を弱める側** に直す。

## 関連ページ

- [プラットフォーム skip を増やすなら「緑の意味」を痩せさせない skip 会計をセットで入れる](./skip-accounting-honest-green.md)
- [同 file 内 MUST NOT vs MUST 衝突: bare form 禁止規約と bare form 出力義務の自己矛盾](../anti-patterns/same-file-must-not-vs-must-conflict.md)
- [「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる](./exhaustiveness-claims-require-mechanical-inventory.md)

## ソース

- [新しい規約が、それを強制する機構より弱く書かれている](../../raw/reviews/20260725T024207Z-pr-2013.md)
- [予約グリフの制約 / 複製強制検査の未文書](../../raw/reviews/20260725T032345Z-pr-2013.md)
- [制裁範囲の明文化 / 実在アンチパターンの grep](../../raw/fixes/20260725T025323Z-pr-2013.md)
- [6 コピーの契約文書化 / 予約グリフ](../../raw/fixes/20260725T033607Z-pr-2013.md)
- [規約が依拠する前提を同じ文書内で確立する](../../raw/fixes/20260725T004542Z-pr-2013.md)
