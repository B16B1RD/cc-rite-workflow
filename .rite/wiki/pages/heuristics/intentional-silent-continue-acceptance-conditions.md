---
type: "heuristics"
title: "意図的 silent-continue は「無視する理由」と「真の失敗の顕在化ポイント」のコメント明記で許容される"
domain: "heuristics"
description: "`cmd 2>/dev/null || true` の意図的 silent-continue は、(a) なぜ無視してよいか (既存リソース / 権限不足等) と (b) 真の失敗がどこで顕在化するか (後続コマンド + エラー surface 機構) をコメントに明記し、仕様のエラー方針と対応させれば error-handling レビューの許容条件を満たし 1 cycle で収束する。"
created: "2026-07-13T01:00:24+09:00"
updated: "2026-07-13T01:00:24+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260712T155421Z-pr-1837.md"
tags: ["error-handling", "silent-continue", "idempotent", "comment-why", "one-cycle-convergence"]
confidence: medium
---

# 意図的 silent-continue は「無視する理由」と「真の失敗の顕在化ポイント」のコメント明記で許容される

## 概要

`cmd 2>/dev/null || true` の意図的 silent-continue は、無条件では silent failure として指摘対象になるが、(a) なぜ無視してよいか (既存リソースの冪等スキップ / 権限不足は後段で顕在化する等) と (b) 真の失敗がどこで顕在化するか (後続コマンドとそのエラー surface 機構) をコメントに明記し、Issue 仕様のエラー方針と対応させれば、error-handling レビューの許容条件を満たす。

## 詳細

### 成立条件（実測）

`gh label create "$label" --description ... --color ... 2>/dev/null || true` によるラベル冪等事前作成が cycle 1 / 0 findings で mergeable になった。成立した条件:

1. **既存パターンの踏襲**: リポジトリ内で既に確立済みの同型パターン (cleanup skill のラベル事前作成) を precedent としてコメントで参照した
2. **無視する理由の明記**: 「既存ラベル / 権限不足の失敗は無視して続行し」— 期待されるエラー条件を列挙
3. **顕在化ポイントの明記**: 「真の失敗は gh issue create 側で helper の $result (warnings) として surface される」— silent-continue が握り潰した失敗が後段のどこで・どの機構により可視化されるかを specific に指す
4. **仕様との対応**: Issue のエラー方針テーブル (Error Condition → Expected Behavior) がこの挙動を明文化しており、実装コメントと仕様が一致

error-handling reviewer の許容条件は「explicit comment + 期待エラー条件の記載」であり、上記 2-3 がそれを直接満たす。逆に、顕在化ポイントの主張が実装と一致しない場合 (例: 顕在化するはずの経路が実際には結果を破棄している) はコメント精度の指摘対象になる — 顕在化ポイントを書く前に、その経路が本当に surface するかを実装で確認する。

### 併せて成立していた前提

- silent-continue の下流にある「真の失敗の surface 機構」自体が本物であること。PR #1837 では helper が失敗時も stdout JSON (warnings 付き) を出力して exit 1 する契約を全レビュアーが独立に実装確認した。顕在化ポイントが機能しない場合、silent-continue は本当の silent failure になる
- 観測性の修正を 1 経路に入れると、同型の未修正経路 (本件では decompose の親 Issue 失敗経路の result 破棄) がレビューで surface される。これは scope 境界 (revert test) で調査推奨に分離し、別 Issue 化判断に回すのが正しい処理

## 関連ページ

- [stderr ノイズ削減: truncate ではなく selective surface で解く](./stderr-selective-surface-over-truncate.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1837 review results](../../raw/reviews/20260712T155421Z-pr-1837.md)
