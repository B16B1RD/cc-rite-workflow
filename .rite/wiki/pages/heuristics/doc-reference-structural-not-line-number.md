---
type: "heuristics"
title: "参照先が「将来編集される前提の行」なら行番号でなく構造（TC 名・見出し）で指す"
domain: "heuristics"
description: "文書の行番号参照は、参照先が「編集を促している行」ほど速く腐る。PR #2013 の `timeout-shim.test.sh:243` / `:276` は「統合したら下げろ」と読者に編集を促す行そのもので、TC が 1 つ増えるだけで両方が silent にずれる。3 レビュアーが独立に指摘した。参照は TC 名・見出し・関数名など編集で動かない構造単位で書く。"
created: "2026-07-25T07:05:21Z"
updated: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260725T041328Z-pr-2013.md"
tags: ["documentation", "reference-drift", "semantic-anchor", "line-number"]
confidence: high
---

# 参照先が「将来編集される前提の行」なら行番号でなく構造（TC 名・見出し）で指す

## 概要

文書やコメントから他ファイルの特定行を指す参照は、コード変更で silent に腐る。腐り方には濃淡があり、**参照先が「編集を促している行」であるほど速く腐る** — 読者にその行を編集させる指示と、その行の位置を固定する参照が同居しているため、指示に従った瞬間に参照が壊れる。PR #2013 cycle 4 で 3 レビュアーが独立に指摘した唯一の修正がこれだった。

## 詳細

### 実例

`timeout-shim.test.sh:243` / `:276` への参照が、「統合したら（floor 値を）下げろ」と読者に編集を促す行そのものを指していた。TC が 1 つ増えるだけで両方の行番号がずれるが、**ずれても何も壊れない**（テストは通る）ため silent に誤誘導する参照になる。

### 腐りやすさの階層

| 参照先の性質 | 腐りやすさ |
|---|---|
| 「ここを編集せよ」と促している行 | **最速**（指示に従うと即座に壊れる） |
| 頻繁に TC が追加されるファイルの中盤 | 高 |
| 安定した定義行（関数シグネチャ等） | 中 |
| ファイル冒頭の shebang / ヘッダ | 低 |

### 構造参照への置き換え

```markdown
<!-- ❌ 行番号 -->
floor 値は timeout-shim.test.sh:243 と :276 にある

<!-- ✅ 構造単位 -->
floor 値は timeout-shim.test.sh の TC-7 (byte-identity) と TC-8 (guard 存在) の
各先頭にある `EXPECTED_COPIES` 宣言
```

TC 名・見出し・関数名・一意な識別子リテラルは、編集で位置が動いても **grep で追える**。行番号は追えない。

### rite における既存の規範

このリポジトリでは既に「semantic anchor 規範」として同じ結論に到達しており、`work-memory-update.sh` のコメントには旧参照が code shift で drift 済みであることが明記されている（`旧 "line 130 / line 72" は code shift で drift 済み`）。本ページはその規範を **「編集を促す行への参照が最も速く腐る」** という優先順位付きで補強する。

### レビュー時のチェック

新規に行番号参照を書いたら、参照先が次のどれかに当てはまらないか確認する:

1. 読者にその行の編集を促している（floor 値・閾値・TODO）
2. 同じファイルに今後 TC / case arm が追加される見込みがある
3. 参照元と参照先が別 PR で独立に更新されうる

1 つでも当てはまるなら構造参照に置き換える。

## 関連ページ

- [機械的制裁を伴う規約は「何をすると」「何がどこまで」落ちるかを書く](./mechanical-sanction-rule-documents-blast-radius.md)
- [SoT 文書の path 参照は本 PR マージ時点の origin/develop で existence check する](./sot-path-reference-existence-check.md)
- [Issue 対応案の番号参照を未検証のまま転記すると事実誤認が伝播する](../anti-patterns/unverified-issue-proposal-reference-transcription.md)

## ソース

- [PR #2013 review cycle 4 — 文書の行番号参照は「編集を促している行」ほど腐る（3 レビュアーが独立指摘）](../../raw/reviews/20260725T041328Z-pr-2013.md)
