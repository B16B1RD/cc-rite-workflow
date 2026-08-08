---
type: "anti-patterns"
title: "配布テンプレートへの内部参照流入は 1 箇所直しても閉じない — 同一配布単位の sibling を base 件数と比較する"
domain: "anti-patterns"
promote: rite-plugin
description: "ユーザープロジェクトへ展開されるテンプレートに repo 相対パスや Issue 番号を書くと、展開先で解決できない参照になる。lint の走査対象外のファイルだと番号参照が永続する。指摘は 1 箇所でも、同じ配布単位の sibling を同一 grep で走査すると追加箇所が出る。base branch 側の件数を git show で確認すると「0 件」が暗黙の不変条件だったことを機械的に復元でき、伝播範囲を推測ではなく確定できる。"
created: "2026-08-02T22:05:00+09:00"
updated: "2026-08-02T22:05:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260802T102657Z-pr-2052.md"
  - type: "fixes"
    ref: "raw/fixes/20260802T103655Z-pr-2052.md"
tags: ["distribution-boundary", "template", "propagation-scan", "implicit-invariant", "lint-blind-spot"]
confidence: high
---

# 配布テンプレートへの内部参照流入は 1 箇所直しても閉じない — 同一配布単位の sibling を base 件数と比較する

## 概要

`templates/` 配下のように **ユーザープロジェクトへ展開される成果物** は、開発リポジトリの内部とは別の名前空間に着地する。ここに repo 相対パス（`docs/SPEC.md`）や Issue 番号（`#2053`）を書くと、展開先では解決できない参照になる。

この種の流入は 1 箇所を直しても閉じない。**同じ配布単位の sibling を同一 grep で走査し、base branch 側の件数と比較する**ことで、伝播範囲を推測ではなく機械的に確定する。

## 詳細

### 発生構造

起点事例では `templates/wiki/*.md` が対象だった。これらは `/rite:wiki-init` が placeholder 置換または単純 `cp` でユーザープロジェクトへ展開する。開発中は同じリポジトリのファイルとして見えるため、隣接ドキュメントと同じ感覚で内部参照を書いてしまう。

指摘は `schema-template.md` の 1 箇所だった。しかし伝播スキャン（同一パターンで sibling を走査）が `index-template.md` にもう 1 箇所を検出した。**指摘箇所と実際の流入範囲は一致しない。**

### lint の届かない場所に永続する

`SCHEMA.md` は説明的番号参照 lint の走査対象から**意図的に外されている**。そのため、ここに書かれた Issue 番号参照は検出器に掛からず永続する。

「lint が緑だから規約を守れている」という判断は成立しない。**検出器の非検出範囲を知らずに緑を根拠にしてはいけない**。同じ PR では別の形でも同じ誤りが出ている — 番号参照の除去を 4 箇所で行いながら別ファイルへ 8 箇所を新規追加し、検出器が裸の `#N` を意図的に非検出とする設計のため緑のまま通った。

### 暗黙の不変条件を base 件数から復元する

伝播範囲を決めるとき、「どこまで直すべきか」は主観になりやすい。起点事例では機械的に確定できた。

```bash
git show develop:plugins/rite/templates/wiki/<file>.md | grep -c '<pattern>'
```

develop 時点で全 4 テンプレートが **0 件** だったことを確認できたため、「配布テンプレートに内部参照を書かない」が暗黙の不変条件として成立していたと確定した。不変条件が確定すれば、直すべき範囲は「0 件に戻す」で自動的に決まる。

> 配布成果物への変更をレビューするときは、指摘箇所だけでなく同じ配布単位の sibling を必ず同一 grep で走査し、base branch 側の件数と比較して不変条件を復元する。

暗黙の不変条件は、明文化されていなくても **base branch の実測値として存在する**。それを復元すれば、推測に頼らず伝播範囲を決められる。

### 同根の指摘が blocking / non-blocking に割れる

起点事例では、同じ根因の 2 件が blocking と non-blocking に分かれた。差は「既存 lint helper で再現できたかどうか」であって、**指摘の重要度の差ではない**。

`Verification:` アンカーを伴わない指摘は実測必須ゲートで non-blocking へ降格する。設計どおりの挙動だが、配布境界の問題は runtime 再現手段が構造的に存在しないことが多いため、この降格が起きやすい。降格した指摘を捨てずに記録経路（PR 記録コメント / 永続 JSON）へ流すことが、「merge を止めない」判断の前提になる。

### チェックリスト

配布成果物（`templates/` など）を変更するとき:

| 確認 | 方法 |
|---|---|
| 内部参照が入っていないか | repo 相対パス・Issue 番号・内部ドキュメント名を grep |
| sibling にも同じ流入がないか | 同一配布単位を同じパターンで走査 |
| 直すべき範囲はどこまでか | `git show <base>:<path>` で base 件数を測り不変条件を復元 |
| lint が走査しているか | 走査対象外のファイル（SCHEMA.md 等）は緑を根拠にしない |

## 関連ページ

- [自 repo 固有 anchor を Edit old_string に hardcode すると consumer project で hard fail する (dogfooding bias)](./dogfooding-anchor-hardcode.md)
- [pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する](../patterns/pin-literal-uniqueness-verified-by-mutation.md)
- [散文で機械的述語を定義したら、字義どおりの実装を実データ全件へ当ててから書く](../heuristics/prose-predicate-must-be-run-against-full-real-data.md)

## ソース

- [PR #2052 review results](../../raw/reviews/20260802T102657Z-pr-2052.md)
- [PR #2052 fix results](../../raw/fixes/20260802T103655Z-pr-2052.md)
