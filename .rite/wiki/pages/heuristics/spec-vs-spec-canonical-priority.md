---
title: "Spec-vs-spec 矛盾は canonical SoT 表記のある側を優先する"
domain: "heuristics"
promote: rite-plugin
created: "2026-05-19T17:45:00Z"
updated: "2026-05-19T17:45:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260519T153513Z-pr-1064.md"
  - type: "fixes"
    ref: "raw/fixes/20260519T154330Z-pr-1064-cycle1.md"
tags: []
confidence: high
---

# Spec-vs-spec 矛盾は canonical SoT 表記のある側を優先する

## 概要

Issue body などの specification 入力と schema doc などの canonical SoT 表記のある文書で、同一フィールドの仕様が正面から矛盾した場合、`canonical SoT` 側を採用する。Issue body は要求の発生時点における spec 案であり、canonical SoT 文書（schema 定義・契約 doc）は plugin 横断の実装契約であるという非対称性を尊重する。

## 詳細

### 観測された矛盾

- **Issue body** (`feat(artifacts): migration script + schema-version hook + bats test`): `findings[].pre_existing` を migration スクリプトで `false` 初期化する仕様を記載
- **canonical SoT** (`docs/SPEC.md` または `references/review-result-schema.md` §後方互換性): 同 PR で schema 1.1.0 化が完了する場面において `pre_existing` フィールド自体を schema から削除し、scope=`nit-noted` × pre_existing 自動降格の代替経路へ移行する canonical 表記
- **正面衝突**: Issue body 通りに migration で `pre_existing=false` を全 finding に付与すると、canonical 側で schema 削除された無効フィールドを permanent に注入することになる

### Cycle 1 review の解決方向 (3 reviewer 合議)

review (cycle 1) で 3 reviewer が独立に `pre_existing` フィールドの取扱い不整合を検出した。reviewers は **canonical SoT 表記のある文書 (schema doc) 側を信用すべき** という判定を一致して提示し、Issue body 記載の `pre_existing=false` 初期化は migration script から削除する方針が採用された。

### Cycle 1 fix の resolution

cycle 1 fix で migration script の `pre_existing` 関連処理は除去され、schema 1.1.0 canonical (フィールド非存在) と整合する形で 14 findings 全件が解決した。

### 経験則の抽象化

1. **canonical SoT 表記の存在**: 文書冒頭に `canonical SoT` / `Single Source of Truth` / `本仕様が canonical である` 旨が明記された文書は、他文書の同名フィールド記述に優先する
2. **発生時点の非対称性**: Issue body は spec 草案、canonical doc は実装契約。同一トピックで両者が矛盾した場合、後発の canonical 側で起きた変更 (スキーマ更新・廃止) が Issue body の記述を obsolete 化している可能性を最初に疑う
3. **判定の hand-off**: 矛盾を観測した reviewer / implementer は、勝手に Issue body 通りに実装せず、canonical 側採用の妥当性を blocker finding として上げる (本ケースでは 3 reviewer 独立 cross-validation で boost)

### Anti-Patterns Avoided

- **Issue body 盲従**: Issue 起票時の spec が最新の canonical 表記を反映していない可能性を見ない実装は、canonical 文書の更新があった瞬間に silent drift を生む
- **片方向 SoT 検証**: 「canonical 文書」と「Issue body」の片方だけを見て実装する誤り。両方を読み、矛盾の存在を検出した時点で blocker として上げる必要がある

### 適用条件

- 関係文書のうち少なくとも 1 つが明示的に `canonical` / `SoT` を宣言している
- 矛盾は同一フィールド / 同一仕様レベルの正面衝突であり、解釈差異ではない
- canonical 側の表記が PR 直前の最新 HEAD で確認できる (古い canonical 表記を引用していないか確認すること — 関連: `[[design-doc-current-head-verification]]`)

## 関連ページ

- [Design doc は現 HEAD の SoT (registration / writer-reader grep) を verify してから書く](../heuristics/design-doc-current-head-verification.md)
- [References 抽出時は引用先 SoT の内容を Read tool で verify する](../heuristics/references-extraction-content-fidelity.md)

## ソース

- [PR #1064 review cycle 1 — spec-vs-spec contradiction 検出 (3 reviewer 独立、CRITICAL × 2 / HIGH × 4 / MEDIUM × 6)](../../raw/reviews/20260519T153513Z-pr-1064.md)
- [PR #1064 fix cycle 1 — spec-vs-spec resolution (schema doc canonical 優先で pre_existing 削除、14 findings 全件 fix)](../../raw/fixes/20260519T154330Z-pr-1064-cycle1.md)
