---
type: "heuristics"
title: "既存術語の動詞を別意味に流用せず、新しい意味には別語を立てる"
domain: "heuristics"
description: "同一ファイル内で既に定義済みの術語が使う動詞を、別の意味の説明に流用すると、読み手はどちらの定義が効いているか判別できず、レビューでは術語衝突として指摘される。"
created: "2026-08-25T18:26:48Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-25T18:26:48Z" }
sources:
  - type: "retrospectives"
    resource: "raw/retrospectives/20260825T171831Z-issue-2354.md"
tags: []
confidence: medium
---

# 既存術語の動詞を別意味に流用せず、新しい意味には別語を立てる

## 概要

同一ファイル内で既に定義済みの術語が使う動詞を、別の意味の説明に流用すると、読み手はどちらの定義が効いているか判別できず、レビューでは術語衝突として指摘される。

## 詳細

`review-result-schema.md` の verification 節へ `Measurement-Blocked:` の位置づけを補記した際、新しい marker の説明に「`verification` オブジェクトを設定せず」という言い回しを使った。ところが同じ節は既に **未判定**（helper が `verification` を設定しないことで 3 値判定の第 3 値を表現する状態）を同じ動詞で定義しており、同一動詞が「未判定を表す機構」と「この marker は実測アンカーとして読まれない」という別の主張の両方を指す状態になった。読み手は当該箇所でどちらの定義が効いているかを字面から決められない。

避け方は、新しい意味には既存術語と語幹を共有しない別語を立てること。ここでは「helper はこの marker を実測アンカーとして読まない」「3 値判定に介入しない」のように、既存の「設定する / 設定しない」の語彙圏を踏まない述べ方に置き換えれば衝突しない。

補記のような小さな追記でも、書く前に**同じ節の既存定義が使っている動詞を一度洗い出す**のが安価な予防になる。追記は既存文脈を読み直さずに書かれやすく、術語衝突はまさにその読み飛ばしから生まれる。

なおこの衝突は帰結が可読性に留まるため、レビューでは実測付きでも class B として降格され mergeable を止めない。ゲートに頼らず書き手側で潰す種類の欠陥である。

## 関連ページ

- [機械的な述語を文書化するときは意図の語彙ではなく字句の語彙で書く](./mechanical-predicate-prose-lexical-vocabulary.md)
- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](./identity-reference-documentation-unification.md)

## ソース

- [close retrospective](../../raw/retrospectives/20260825T171831Z-issue-2354.md)
