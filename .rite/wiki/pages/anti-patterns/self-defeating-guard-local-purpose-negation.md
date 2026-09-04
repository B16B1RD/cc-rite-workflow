---
type: "anti-patterns"
title: "新設した検証機構が、その機構自身の目的を局所的に打ち消す"
domain: "anti-patterns"
promote: rite-plugin
description: "過去のレビュー事例（macOS/BSD 対応でテストスイートを green 化）の 4 cycle・累積 26 指摘のうち **最多の型が本パターン（5 件）**だった。"
created: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260725T003541Z-pr-2013.md"
  - type: "reviews"
    resource: "raw/reviews/20260725T024207Z-pr-2013.md"
  - type: "reviews"
    resource: "raw/reviews/20260725T041328Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260725T004542Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260725T025323Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260812T133631Z-pr-2278.md"
tags: ["fail-closed", "self-defeating", "observability", "parser", "diagnostics"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-12T18:34:40Z" }
---

# 新設した検証機構が、その機構自身の目的を局所的に打ち消す

## 概要

起点事例（macOS/BSD 対応でテストスイートを green 化）の 4 cycle・累積 26 指摘のうち **最多の型が本パターン（5 件）**だった。fail-closed ガード・集計 parser・SKIP 可視化カウンタはいずれも「緑の意味を痩せさせない」ために導入されたが、導入と同じ PR の中で、その機構自身の目的を局所的に無効化していた。個別の実装ミスではなく、**「機構を足したら、その機構の周辺を監査していない」という単一の構造的欠落**から生じる。

## 詳細

### 形態 1: fail-closed ガードが既存の診断出力を先食いする

skip 会計の drift 検出という新しい `exit 1` を、既存の「失敗ファイル一覧」出力より **前** に置いた。drift と実失敗が同時成立すると失敗ファイル名が一切出なくなる。しかも同時成立は偶発ではなく構造的で、`set -e` のテストが `skip()` 呼び出し後・summary 到達前に abort すると必ず両立する。

> **規則**: ガードを追加するときは (a) 既存の診断より **後ろ** に置き、(b) 両方を出してから exit する。exit code は変えずに診断だけを足す形にする。

### 形態 2: parser が、同じ PR が新設した診断文を食う

`run-tests.sh` の skip 会計は「診断文が `SKIP: N` に見えるのを防ぐため、サマリ行に anchor する」とコメントで明言していた。ところが**同じ PR が新設した** `_test-helpers.test.sh` TC-15.1 の失敗診断が `print_summary` の生出力を改行込みで echo するため、`SKIP: 2` が行頭に着地して自分の parser に食われた。結果、テストが 1 件落ちただけなのに「summary format drift」という誤った原因が表示され、skip 総数も 0 件が 2 件と表示された（実測再現済み）。

> **規則**: parser を書いたら、同じ PR 内で「その parser の入力になりうる文字列を出力する箇所」を grep する。特に **変数の生出力を診断に埋める箇所は改行を潰す**（`tr '\n' '|'`）。parser 側を緩めて解決しない — 壊すべきは診断側の漏出。

### 形態 3: 可視化を入れたのに成功メッセージが無条件のまま

SKIP カウンタを導入して集計行には gated group 数を出したのに、最終行は無条件 `All tests passed!` のままだった。しかも同 PR 内のもう一方のランナー（`run-all.sh`）は注記付きに直しており、**gated group を持つ側だけが未対応**という非対称が残った。

> **規則**: 「緑を正直にする」目的の可視化は、集計行だけでなく **成功メッセージにも通す**。類似コンポーネントが 2 つあるなら両方を同時に直す。

### 形態 4: 新しい診断行を消費側に登録し忘れる

ランナー側に新設した 2 種の診断行が `.github/workflows/ci.yml` の job-summary 用 grep にマッチせず、drift だけでジョブが落ちた場合にサマリーが `Results: N/N passed, 0 failed` **だけ** を「Test failures」見出しの下に表示した。**赤いジョブが「全件 pass」と主張する**状態（合成ログで再現確認済み）。

> **規則**: ランナーの出力を増やしたら、そのログを **消費する側**（CI summary の grep 等）を同じ PR で更新する。消費側は grep 1 行なので忘れやすい。

### 導入時チェックリスト

検証機構（ガード / parser / カウンタ / マーカー）を新設したら、その場で以下を確認する:

1. **順序**: 新しい `exit` は既存の診断出力より後ろか
2. **自己入力**: この parser の入力になりうる文字列を、同じ PR が新たに出力していないか（grep）
3. **一貫性**: 集計だけでなく成功/失敗メッセージ、姉妹コンポーネントまで通しているか
4. **消費側**: この出力を読む側（CI の grep、log 抽出、下流 parser）を同じ PR で更新したか

### 形態 5: 証明そのものが空回りしても緑になる

「証明する機構」を新規に足す PR では、証明が成立しない経路が複数同時に残る。起点事例（機械レールの逐語一致チェッカー新設）では、1 cycle の 14 件中 7 件が「checker が green を返すが実際には何も検証していない」形だった:

- 抽出述語が行頭 0 桁アンカーで対象の大半を取りこぼす
- base ref 未解決を clean skip に潰す
- 空 base ref が git index (`:path`) と比較して常に一致する
- 抽出結果が 0 行でも等値比較が成立する
- テストの assertion が exit code のみで「一致」と「not applicable」を区別しない

いずれも単体では小さいが、合成すると「証明が空回りしても緑」という同一の帰結に収束する。形態 1〜4 が「機構の周辺を監査していない」欠落なのに対し、本形態は**機構の中心が空でも成立してしまう**点が異なる。

> **規則**: 証明機構を新設したら、証明が**成立しない入力**（対象 0 件 / base ref 未解決 / 空文字列 / 抽出 0 行）を列挙し、そのそれぞれが緑を返さないことを確認する。guard を積み増すより、証明対象を一度も読めていない状態で停止する（exit 2）方が短く、fail-loud 原則とも一致する。

## 関連ページ

- [`2>&1` と `2>&1 | head -N` で sentinel/exit code が silent suppression される (self-defeating observability)](./stderr-merge-silent-sentinel-suppression.md)
- [Self-contradicting rule declaration: 新規ルール宣言時にルール本文自身がルール違反を含む](./self-contradicting-rule-declaration.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [fail-closed ガードが診断を先食い / 新診断行の CI grep 未登録](../../raw/reviews/20260725T003541Z-pr-2013.md)
- [parser が同 PR の診断文に食われる反例を実測再現](../../raw/reviews/20260725T024207Z-pr-2013.md)
- [累積 26 指摘の型別集計で本型が最多（5 件）と確定](../../raw/reviews/20260725T041328Z-pr-2013.md)
- [4 件すべてが本型に収まった cycle](../../raw/fixes/20260725T004542Z-pr-2013.md)
- [検証機構の周辺に同型の穴が残る構造](../../raw/fixes/20260725T025323Z-pr-2013.md)
- [証明機構の新設で「緑だが何も検証していない」経路が 14 件中 7 件](../../raw/fixes/20260812T133631Z-pr-2278.md)
