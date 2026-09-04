---
title: "Config parser helper の DRY 化が key 別 subtle 差異を silent に抹消する"
domain: "anti-patterns"
description: "重複した YAML / config パース処理を helper 関数に DRY 化する際、key 別の subtle な差異 (lowercase 変換の有無 / quote 除去の有無 / trim の範囲) を helper 内に一律適用すると、helper 化前に key 単位で異なっていた挙動が silent に抹消される。"
created: "2026-05-27T00:30:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260526T175307Z-pr-1155.md"
  - type: "fixes"
    resource: "raw/fixes/20260526T180309Z-pr-1155.md"
tags: ["dry", "helper-extraction", "yaml-parser", "behavior-preservation", "silent-regression", "case-sensitivity"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-27T00:30:00Z" }
---

# Config parser helper の DRY 化が key 別 subtle 差異を silent に抹消する

## 概要

重複した YAML / config パース処理を helper 関数に DRY 化する際、key 別の subtle な差異 (lowercase 変換の有無 / quote 除去の有無 / trim の範囲) を helper 内に一律適用すると、helper 化前に key 単位で異なっていた挙動が silent に抹消される。「コメント削除のみ許容」「behavior-preserving refactor」を謳う PR でも、helper 抽出は behavior change を内包する **silent regression 経路**。

## 詳細

### 発生条件

YAML パースのような multi-key config 取得処理が複数 site に散在しているとき、DRY 化助手 (例: `extract_yaml_key`) として共通化する refactor で発生する。helper 内に「全 key 共通の前処理」(例: `tr '[:upper:]' '[:lower:]'`) を含めると、helper 化前は key 別に適用範囲が異なっていた前処理が一律適用される。

### 起点事例で実測した failure mode

起点事例の cycle 1 で 3 reviewer 独立 HIGH 検出された:

```bash
# Before (develop): key 別に lowercase 適用の有無が異なる
wiki_enabled=$(... | tr -d '[:space:]"'\''' | tr '[:upper:]' '[:lower:]')  # lowercase 適用
wiki_branch=$(... | tr -d '[:space:]"'\''')                                  # lowercase 適用なし
branch_strategy=$(... | tr -d '[:space:]"'\''')                              # lowercase 適用なし

# After (helper 化): 全 key 一律 lowercase 適用
extract_yaml_key() {
  ... | tr -d '[:space:]"'\''' | tr '[:upper:]' '[:lower:]'  # 全 key に適用
}
wiki_enabled=$(extract_yaml_key enabled)
wiki_branch=$(extract_yaml_key branch_name)         # behavior change!
branch_strategy=$(extract_yaml_key branch_strategy) # behavior change!
```

この helper 化の結果:

- `branch_name: "MyWiki"` のような mixed case branch 名が silent corrupt (`"mywiki"` に変換)
- `branch_strategy: "Separate_Branch"` が silent acceptance に変わる (`"separate_branch"` 同等扱い)
- PR description の「bash 内 functional logic の毀損禁止 (コメント削除のみ許容)」と直接矛盾

### 検出手段

#### 1. Helper 化前後の key 別挙動 diff

helper 化前後で「全 key の挙動が bit-identical」を verify する unit test 相当の作業:

```bash
# 各 key について helper 化前後の値を比較
for key in enabled branch_name branch_strategy auto_ingest; do
  before=$(extract_yaml_key_before "$key")
  after=$(extract_yaml_key_after "$key")
  [ "$before" = "$after" ] || echo "DRIFT: key=$key before='$before' after='$after'"
done
```

#### 2. 「subtle 前処理」の grep 棚卸し

helper 化前のソースコードを `tr '[:upper:]' '[:lower:]'` / `tr -d '"'\'''` / `sed 's/^[[:space:]]*//'` 等の前処理 chain で grep し、key 単位で適用 chain が異なるかを機械検証:

```bash
grep -A 2 "key:" wiki-config.sh | grep -E "tr|sed" | sort -u
```

異なる chain を持つ key が混在していたら、helper 化は behavior change を内包する。

### Canonical 対策

1. **Helper 化前に key 別前処理 chain を表に落とす**: 抽出対象の前処理を「lowercase 適用 / quote 除去 / trim 範囲 / boolean 正規化」の各軸で表化し、全 key が等価か明示する
2. **異なる chain は helper 引数 / 別 helper で受ける**: 一部 key だけ lowercase 適用が必要な場合、`extract_yaml_key key [--lowercase]` のように option flag で behavior を caller-controlled にする。helper 内 unconditional 適用を避ける
3. **boolean 正規化は別 helper に分離**: `enabled` のような boolean 系 key と `branch_name` のような identifier 系 key は別 helper (例: `parse_wiki_bool` / `parse_wiki_scalar`) に分離する。boolean は lowercase 必要、identifier は保持必要、と semantic が明示される
4. **behavior-preserving refactor の verify 義務**: 「コメント削除のみ許容」を謳う PR は、機能 statement の挙動が変わらないことを diff レベルで確認する。helper 抽出は behavior change の経路を持つため例外なく verify 対象

### 一般化

本 anti-pattern は YAML パースに限らず、**「key 別に微妙に異なる前処理を持つ multi-key dispatch」全般** に適用される:

- HTTP header 正規化 (`Content-Type` だけ lowercase 比較、`Authorization` は case 保持)
- env var 取得 (一部だけ default 値あり、一部だけ trim あり)
- CLI flag parsing (一部だけ boolean 解釈、一部だけ list 解釈)

いずれも「helper 化前は key 別に微妙に異なる挙動があった」状態を見落とすと、helper 化が silent behavior change を生む経路を含む。

## 関連ページ

- [[dry-helper-aggregation-effect-overstate]] ([dry-helper-aggregation-effect-overstate.md](./dry-helper-aggregation-effect-overstate.md))
- [[flatten-refactor-deletion-scope-classification]] ([flatten-refactor-deletion-scope-classification.md](../heuristics/flatten-refactor-deletion-scope-classification.md))

## ソース

- [extract_yaml_key helper の一律 lowercase 適用が key 別挙動 silent 抹消、3 reviewer 独立 HIGH 検出](../../raw/reviews/20260526T175307Z-pr-1155.md)
- [helper 化前後の behavior preservation verify ルール確立](../../raw/fixes/20260526T180309Z-pr-1155.md)
