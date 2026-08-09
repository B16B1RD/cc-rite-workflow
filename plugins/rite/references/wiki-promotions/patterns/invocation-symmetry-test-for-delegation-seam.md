---
type: "patterns"
title: "委譲リファクタの呼び出しシームは invocation-symmetry test で機械固定する"
domain: "patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/patterns/invocation-symmetry-test-for-delegation-seam.md"
promoted_from: "wiki:/pages/patterns/invocation-symmetry-test-for-delegation-seam.md"
description: "散文手順を helper へ降ろすリファクタでは、helper 単体の品質より SKILL.md→helper 呼び出し契約（フラグ集合・呼び出し行の実体）が残存リスクになる。呼び出し側のフラグ集合を helper の case arm から動的抽出して突合する invocation-symmetry test で両側を pin する。フラグ「名」の集合だけでなく呼び出し行の literal な形（コマンド語・値）まで固定して初めて変異を殺せる。"
created: "2026-08-05T09:26:00+09:00"
updated: "2026-08-05T09:26:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260804T142514Z-pr-2111.md"
  - type: "fixes"
    ref: "raw/fixes/20260804T143100Z-pr-2111.md"
tags: ["delegation-refactor", "invocation-symmetry", "seam-contract", "skill-md", "helper"]
confidence: medium
---

# 委譲リファクタの呼び出しシームは invocation-symmetry test で機械固定する

## 概要

散文手順を helper script へ降ろすリファクタでは、helper 本体はテストで固定できるが、**SKILL.md（呼び出し側）→ helper の呼び出し契約は放置するとどちらか片側の編集で silent に壊れる**。呼び出し側の bash block が渡すフラグ集合を helper の case arm から動的抽出して突合する invocation-symmetry test を置き、シームの両側を 1 本のテストで pin する。

## 詳細

### 失敗の構造

委譲リファクタ（wiki-ingest ステップ 6 → `wiki-index-update.sh`、PR #2111）の cycle 2 レビューで、helper 単体のテストは充実している一方、SKILL.md 側の呼び出し bash が「helper が要求するフラグをすべて渡しているか」を守る機構が無いことが指摘された。委譲リファクタでは**呼び出しの正しさこそが残存リスク**であり、既存先例（`create-md-invocation-symmetry.test.sh`）があるのに未適用だった。

### Canonical fix

既存先例を流用し、以下の両側 pin を実装した:

- **helper 側**: 受理フラグ集合を case arm から動的抽出する（ハードコード列挙ではなく、helper の実装自体を SoT にする）
- **呼び出し側**: SKILL.md の fenced bash から helper 呼び出し行を抽出し、渡しているフラグ集合と突合する

`sed` で片側だけ変えると即 fail する。フラグの増減がどちら側で起きても検出される。

### 進化: フラグ「名」だけでは足りない（cycle 3 の指摘）

フラグ名の集合突合だけでは「呼び出し行の実体」（コマンド語・値の形・継続行の構造）を pin できない。cycle 3 で「契約テストは名前集合だけでなく literal な値の形まで固定して初めて変異を殺せる」と指摘され、継続行を join して 1 論理コマンドへ正規化した上で全フラグの同居を assert する形へ強化された（行断片の列挙は増やすほど保守が重くなるのに変異耐性が上がらない）。

### 付随した教訓: false-coverage の解消はラベル改名 + 分岐別 TC 分割

同 cycle で「TC ラベルが名乗る分岐（pages 0 件）と実際に到達する分岐（find 失敗）の乖離」も検出された。「カバー済みと名乗るが実到達しない分岐」は、TC 名を実到達分岐に合わせて改名した上で、名乗っていた分岐の TC を独立に追加する。

## 関連ページ

- [委譲リファクタの動作保持は原実装との差分テストで機械的に立証する](../heuristics/delegation-refactor-differential-test-equivalence.md)
- [新設した出力フィールドは producer と consumer の両側を pin する — consumer が表なら行単位で pin する](./new-output-field-pin-producer-and-consumer.md)

## ソース

- [PR #2111 review results (cycle 2)](../../raw/reviews/20260804T142514Z-pr-2111.md)
- [PR #2111 fix results (cycle 2)](../../raw/fixes/20260804T143100Z-pr-2111.md)
