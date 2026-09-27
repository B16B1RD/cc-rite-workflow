---
type: "heuristics"
title: "論理式を日本語へ書き起こすときは、正本の括弧構造を文章でも括弧で保つ"
domain: "heuristics"
description: "「A、または B で、C なら」のような書き起こしは、C が B だけに掛かるのか A と B の両方に掛かるのかが一意に決まらない。正本が (A OR B) AND C なら、文章でも「(A、または B) かつ C」と括弧を残して係り先を固定する。"
created: "2026-09-27T03:27:52Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:27:52Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260927T031606Z-pr-3202.md"
tags: ["prose-contract", "logical-formula", "ambiguity"]
confidence: medium
---

# 論理式を日本語へ書き起こすときは、正本の括弧構造を文章でも括弧で保つ

## 概要

「A、または B で、C なら」のような書き起こしは、C が B だけに掛かるのか A と B の両方に掛かるのかが一意に決まらない。正本が (A OR B) AND C なら、文章でも「(A、または B) かつ C」と括弧を残して係り先を固定する。

## 詳細

散文が実行契約になるリポジトリでは、helper が持つ判定式（例: どの指摘を修正対象にするか）を、スキルの説明文へ日本語で書き起こす場面が多い。日本語の読点と「で」「なら」による連結には結合の強さの規則が無い。そのため、読み手が LLM でも人間でも、書き手の意図と違う結合で読みうる。

起点事例では、正本が `(A OR B) AND C` の式を「A、または B で、C なら」と書いていた。レビューはこれを読み違いの余地として PR 内の推奨事項に登録した。修正は 1 行の差し替えで、「(A、または B) かつ C」と文章側にも括弧を置いた。

書き起こしの手順:

- 正本（helper の実装や定義表）の括弧構造を先に確認し、文章でも同じ位置に括弧を置く
- AND / OR は「かつ」「または」に固定し、読点や「で」で結合を表現しない
- 書き起こした後は、条件の各項を切り替えた入力で helper を実行し、出力が文章の括弧構造と一致するかを照合する（[散文が引用する実装は文字一致・帰属・behavioral test の 3 点で裏取りする](./prose-cited-implementation-behavioral-verification.md)）

## 関連ページ

- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](./prose-cited-implementation-behavioral-verification.md)

## ソース

- [条件式の書き起こしを括弧付きに直した fix 結果](../../raw/fixes/20260927T031606Z-pr-3202.md)
