---
type: "heuristics"
title: "「SoT が N 個と書いている」だけでは load-bearing 性は決まらない — 依存側が名指ししている要素を読む"
domain: "heuristics"
description: "consumer 側の文書が SoT の N 要素のうち M 個（M < N）しか列挙していないとき、「SoT は N と書いているから欠落は欠陥だ」という推論は一段飛ばしになっている。"
created: "2026-07-29T02:10:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260728T165431Z-pr-2043.md"
tags: ["sot", "review", "cross-validation", "documentation"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-29T02:10:00+09:00" }
---

# 「SoT が N 個と書いている」だけでは load-bearing 性は決まらない — 依存側が名指ししている要素を読む

## 概要

consumer 側の文書が SoT の N 要素のうち M 個（M < N）しか列挙していないとき、「SoT は N と書いているから欠落は欠陥だ」という推論は一段飛ばしになっている。欠落が実際に効くかどうかは、**その N 要素に依存していると宣言している側の文**が、根拠としてどの要素を名指ししているかで決まる。名指しされている要素がすべて列挙済みなら、件数の不一致は精度の問題であって依存関係の欠損ではない。

## 詳細

### 決着した実例

起点事例の cycle 3 でレビュアー 2 名が同一箇所について正反対の結論を出した。

- **prompt-engineer**: SoT は「4 経路すべてに記録する」と明記し、3 ファイル 5 箇所が 4 経路で一致している。欠落した (4) は iterate 自身の実行文脈で有効な経路であり、`assessment-rules.md` が「記録先 4 経路が機能していることが前提」と宣言しているため load-bearing → MEDIUM finding
- **code-quality**: 欠落した (4) は件数 suffix であり「PR 上に残存して人間レビューに委ねる」という当該文の論旨に寄与しない補助経路。省略は妥当 → finding なし

決着は SoT の実テキストを読むことで付いた。`assessment-rules.md` の「4 経路が機能していることが前提」という宣言文は、根拠として実際には次のように書いている:

> それが許されるのは (a) 降格が必ず WARNING で報告され、(b) 降格した指摘が **永続 JSON に必ず残り、ステップ 6.1.d の PR 記録コメントに best-effort で残る**ため

名指しされているのは (1) と (2) の 2 経路だけで、どちらも consumer 側に列挙済みだった。さらに SoT 自身が (3)(4) を「実行モードと件数に依存する補助経路」と分類していた。したがって欠落は依存関係の欠損ではなく、code-quality の主張が優勢と判定できた。

### 手順

1. consumer の列挙と SoT の列挙を突き合わせ、欠落要素を特定する
2. **「N 要素に依存する」と宣言している文を探し、その文が根拠として名指ししている要素を列挙する**（宣言文の件数ではなく、宣言文の中身）
3. 名指し集合 ⊆ consumer の列挙 なら load-bearing ではない。名指し集合に欠落要素が含まれるなら load-bearing
4. SoT が要素に強度分類（無条件 / best-effort / 条件依存）を付けているなら、それも判定材料に加える

### 逆方向の注意との関係

件数を drift 検出アンカーとして使う手法（「N site 対称化」の counter 宣言など）とは**目的が逆**であることに注意する。件数アンカーは「N が合っているか」を機械的に見るための道具で、合っていないこと自体を欠陥として扱う。本ページは「N が合っていないこと」から自動的に欠陥を導かない、という判定の話であり、適用場面が異なる。件数が契約として宣言されている（同期義務が明記されている）なら前者、consumer 側の説明文が SoT を要約しているだけなら後者。

### レビュアー間の割れに使う

同一箇所について finding / 非 finding に割れたとき、severity の高低で決めるより先に本判定を通す。両者の対応方針（fix / accept）が一致するなら合意として高い severity を採り、割れたままなら決着不能としてユーザーへエスカレーションする。起点事例の cycle 3 では本判定で「merge-blocking ではない」点が一致したため、エスカレーションせず合意扱いにできた。

## 関連ページ

- [SoT から事実を 1 つ引くとき、その事実に付いた強度 qualifier ごと持ってこないと別種の不正確さを新設する](../anti-patterns/sot-quote-drops-strength-qualifier.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](./canonical-list-count-claim-drift-anchor.md)
- [Spec-vs-spec 矛盾は canonical SoT 表記のある側を優先する](./spec-vs-spec-canonical-priority.md)

## ソース

- [PR #2043 review results (cycle 3)](../../raw/reviews/20260728T165431Z-pr-2043.md)
