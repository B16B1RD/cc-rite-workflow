---
type: "heuristics"
title: "プラットフォーム skip を増やすなら「緑の意味」を痩せさせない skip 会計をセットで入れる"
domain: "heuristics"
description: "クロスプラットフォーム対応は skip を増やす。"
created: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260724T175144Z-pr-2013.md"
  - type: "reviews"
    resource: "raw/reviews/20260725T003541Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T184410Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T193804Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T202517Z-pr-2013.md"
tags: ["test", "skip", "vacuous-green", "observability", "cross-platform"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-25T07:05:21Z" }
---

# プラットフォーム skip を増やすなら「緑の意味」を痩せさせない skip 会計をセットで入れる

## 概要

クロスプラットフォーム対応は skip を増やす。ところが `print_summary` が PASS/FAIL のみを数える設計だと、**31 アサーションが実行されないまま `All tests passed!` が出る**。緑が「検証した」ではなく「検証しなかった」を意味しうる状態になる。skip を増やす PR では、SKIP カウンタの導入・集計行への反映・成功メッセージの表現・姉妹ランナーとの対称化を **セットで** 行う。

## 詳細

### 1. skip は数えて、人間が読む出力まで到達させる

skip を数える機構を各テストファイルに入れても、**runner の headline が変わらなければ「31 アサーション未実行」は誰も見ない**。可観測性の改善は、実際に人間が読む出力まで到達して初めて完了する。

既存の `skip()` + `SKIP` カウンタ規約がリポジトリにあるなら helper 側に昇格させ、全 skip サイトを置換する。

### 2. 「集計行だけ直して成功メッセージが無条件」は非対称

SKIP カウンタを導入して集計行には gated group 数を出したのに、最終行が無条件 `All tests passed!` のままだと緑の正直さが最後で打ち消される。同 PR 内に類似ランナーが 2 つあれば **両方同時に** 直す（片方だけ直すと非対称が残る）。

### 3. 集計されない skip の 2 形態

| 形態 | 何が起きるか |
|---|---|
| `echo "SKIP: ..." >&2; exit 0` でファイル全体を抜ける | runner から見れば「成功したテストファイル」。skip 集計に現れない |
| `pass "... skipped"` | **PASS を水増ししたうえで** skip 突き合わせも素通りする |

後者が特に厄介で、「bare `echo` は禁止」という規約を書いても対象外のまま残る。

> **規則**: 禁止事項を列挙する前に、**実際にリポジトリで見つかるアンチパターンを grep する**。想像した禁止形ではなく実在形を対象にする。

### 4. 集計 parser は summary 行の形に anchor する

`sed -n 's/.*, ([0-9]+) skipped.*/\1/p'` は行内容を無差別に拾うため、失敗診断文が `, 7 skipped` を含むと +7 誤カウントする。

```bash
# summary 行であることを要求する
^[^❌]*Results:[^❌]*, ([0-9]+) skipped
```

あわせて「可視マーカーはあるのに解析結果が 0」を format drift として WARNING にすると、将来書式が増えたときの取りこぼしが可視化される。ただし **その parser の入力になりうる文字列を同じ PR が出力していないか grep する**こと（[self-defeating-guard-local-purpose-negation](../anti-patterns/self-defeating-guard-local-purpose-negation.md) 形態 2）。

### 5. skip には追跡 Issue を紐づけ、「追跡不要」と「未起票」を区別する

環境依存で skip したテストのうち 1 件だけ追跡 Issue が無く、さらに skip 根拠が hook 自身の設計方針と衝突していた。skip 台帳を作るときは「追跡不要」と「未起票」を明確に区別する。

### 6. capability probe による skip には blocking gate 側の床を入れる

`realpath` の挙動で skip するテストは、Linux で `realpath` が shadow / 不在なら **blocking gate 上でも無言 skip** される。

```bash
# 判定は PATH に汚染されないファイルシステム事実で行う
[ -d /proc ] && ! command -v realpath >/dev/null && fail "capability probe failed on blocking leg"
```

`$(uname -s)` で書くと `uname` 自身も同じ PATH を引くため、**床の判定手段が床の守ろうとしている脅威に汚染される**。`[ -d /proc ]` のようなファイルシステム事実に基づく判定の方が強い。

## 関連ページ

- [新設した検証機構が、その機構自身の目的を局所的に打ち消す](../anti-patterns/self-defeating-guard-local-purpose-negation.md)
- [degrade する対象をテストするときは判別子を probe と連動させる](./degrade-discriminator-switched-by-probe.md)
- [機械的制裁を伴う規約は「何をすると」「何がどこまで」落ちるかを書く](./mechanical-sanction-rule-documents-blast-radius.md)

## ソース

- [PR #2013 review cycle 1 — skip 件数が集計されないと green の意味が痩せる](../../raw/reviews/20260724T175144Z-pr-2013.md)
- [PR #2013 review cycle 1 (後半) — 緑化の正直さを最終行が打ち消す](../../raw/reviews/20260725T003541Z-pr-2013.md)
- [PR #2013 fix results (cycle 2) — skip をカウントして summary に出す / capability probe の床](../../raw/fixes/20260724T184410Z-pr-2013.md)
- [PR #2013 fix results (cycle 3) — カウンタは per-file で止めず集約点まで通す](../../raw/fixes/20260724T193804Z-pr-2013.md)
- [PR #2013 fix results (cycle 4) — 集計 parser の anchor / exit 0 skip が PASSED に計上される](../../raw/fixes/20260724T202517Z-pr-2013.md)
