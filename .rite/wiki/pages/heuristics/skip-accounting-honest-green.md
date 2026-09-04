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
  - type: "fixes"
    resource: "raw/fixes/20260830T142208Z-pr-2489.md"
tags: ["test", "skip", "vacuous-green", "observability", "cross-platform"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-30T15:15:33Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-30T15:15:33Z" }
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

### 7. 抽出失敗で assert 群を gate する分岐も skip 会計の対象

skip 会計が要るのは「プラットフォーム非対応」だけではない。テストが SKILL.md の fenced bash を抽出して実行する型では、抽出アンカーが壊れたときに後続の assert 群をまとめて gate する分岐が要る。この分岐が `skip()` を呼ばずに素通りすると、**実行 assert 14 件が PASS / FAIL / SKIP のどこにも載らない**。実測では baseline との PASS 差（212 → 197、SKIP 行なし）でしか気付けなかった。gate した件数を数えれば、何が走らなかったかがサマリから読める。

`skip()` を 1 本足しておくと、gate 自体を削除する変異が SKIP=1 の消失として現れるので、gate の存在も同時に pin できる。

### 8. gate の skip 文言は原因を決め打ちしない

複数の原因が同じフラグを落とす設計なら、skip 文言も両方の原因を名乗る形にする。フラグ名も同様で、`*_extract_ok` のように片方の原因だけを含意する名前は、もう片方で落ちたときに読み手を誤らせる。

### 9. 非項の除去は位置ではなく名指しで行う

集合抽出から特定のトークンを除くとき、「この区切り以降」のように**位置で範囲を狭める**と、狭めた範囲の外側が盲点になる。実測では、内訳文言の左側に counter を挿入した変異が検出されなかった（除去は右側だけを見ていた）。除去したいトークンが行内で一意なら、範囲を狭めずに**名指しで落とす**方が盲点を作らない。whitelist の穴を塞ぐために抽出を開いた regex へ移しても、同じサイトで位置 narrowing を入れれば別の穴が空く。

## 関連ページ

- [新設した検証機構が、その機構自身の目的を局所的に打ち消す](../anti-patterns/self-defeating-guard-local-purpose-negation.md)
- [degrade する対象をテストするときは判別子を probe と連動させる](./degrade-discriminator-switched-by-probe.md)
- [機械的制裁を伴う規約は「何をすると」「何がどこまで」落ちるかを書く](./mechanical-sanction-rule-documents-blast-radius.md)

## ソース

- [skip 件数が集計されないと green の意味が痩せる](../../raw/reviews/20260724T175144Z-pr-2013.md)
- [(後半) — 緑化の正直さを最終行が打ち消す](../../raw/reviews/20260725T003541Z-pr-2013.md)
- [skip をカウントして summary に出す / capability probe の床](../../raw/fixes/20260724T184410Z-pr-2013.md)
- [カウンタは per-file で止めず集約点まで通す](../../raw/fixes/20260724T193804Z-pr-2013.md)
- [集計 parser の anchor / exit 0 skip が PASSED に計上される](../../raw/fixes/20260724T202517Z-pr-2013.md)
- [gate した assert 群の skip 計上 / 位置 narrowing の盲点](../../raw/fixes/20260830T142208Z-pr-2489.md)
