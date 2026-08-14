---
type: "anti-patterns"
title: "「step が走ったか」を後段で判定するとき、識別子の供給元をその step 自身にすると検出したい状態でだけ判定が成立しない"
domain: "anti-patterns"
promote: rite-plugin
description: "step の実行有無を中間ファイルの存在で判定する設計で、そのファイルパスに含む cycle 識別子を当の step が鋳造すると、step を飛ばした cycle には本 cycle のパスが存在せず、解決規則が前 cycle の実ファイルを掴んで fail-open する。"
created: "2026-08-11T01:20:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260810T150514Z-pr-2231.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-11T01:20:00+09:00" }
---

# 「step が走ったか」を後段で判定するとき、識別子の供給元をその step 自身にすると検出したい状態でだけ判定が成立しない

## 概要

step の実行有無を中間ファイルの存在で判定する設計で、そのファイルパスに含む cycle 識別子を当の step が鋳造すると、step を飛ばした cycle には本 cycle のパスが存在せず、解決規則が前 cycle の実ファイルを掴んで fail-open する。

## 詳細

### 起点

reviewer の起動時刻を記録する step が、書き出す JSON のパスへ cycle 一意の epoch を含めた。ここまでは正しい（セッション内不変の `TMPDIR` 配下に cycle スコープの中間ファイルを置くとき、パスに cycle 識別子がないと「不在」を検出条件にできない）。問題は **その epoch を鋳造するのが検出対象の step 自身**だったこと。

step を飛ばした cycle には本 cycle のパスが存在しない。そこで解決規則を「末尾 epoch が最大のもの」にすると、前 cycle の値が返る。`TMPDIR` はセッション内不変で cleanup 経路もないためそのファイルは実在し、存在検査は真になる。**判定が成立するのは「step が走った cycle」だけで、走らなかった cycle では必ず誤る** — 検出したい唯一の状態でだけ判定が壊れる。

3 名のレビュアーが独立に同じ欠陥へ収束した。

### 同じ idiom でも極性で安全性が反転する

同じリポジトリの既存 pending marker 群は同じ「末尾 epoch が最大」規則を使っていたが、**あちらは不在が pass 条件**なので stale ヒットは loud に落ちる。この step のガードは**存在が pass 条件**のため stale ヒットが fail-open する。

**idiom を借りるときは pass 条件の極性を確認する。** 同じ解決規則が、不在 pass では安全側・存在 pass では危険側に働く。

### 対処は機構を増やさず減らす方向で取れる

識別子を step の外（既に確定している commit SHA 等）から取ると:

- marker 1 本と解決規則 1 つを**削除**できる
- 検出が全 cycle で成立する（step を飛ばした cycle でも本 cycle のパスを構成できるため、不在が意味を持つ）

「ガードを足す」ではなく「**ガードの前提を外から与える**」。判定に使う識別子は、判定対象より前に確定しているものから取る。

### 残る残余は明記する

commit SHA を識別子にすると、粒度が cycle ではなく commit になる。HEAD 不変で再入する cycle（fix が push なしで完了を返す正規経路など）では前 cycle のファイルが同一パスに残る。この残余は消えないので、**同種の残余を持つ既存機構と同じ形で「既知の残余」として明記する** — 断言を弱め、SoT を 1 箇所に集約し、他所からは 1 行ポインタで参照する。

### 副次的な教訓

**挙動を変える fix は、その挙動を根拠として引用している設計記録も stale にする。** この cycle では「この block の出力は X だけ・値はセッション不変・skip しても下流に齟齬なし」という設計判断の記録 3 文のうち 2 文が偽になっていた。設計記録は「なぜそう決めたか」を書くので、前提が崩れると次の改修が誤った土台に載る。変更対象を引用している箇所を grep で洗う。

## 関連ページ

- [同一 placeholder を識別子と resolution-target で再利用すると path-resolution drift を生む](../anti-patterns/placeholder-dual-use-resolution-drift.md)
- [仕様が「A のとき報告・B のとき併記」を別々に定めている箇所を elif で書くと A ∧ B で B が消える](./elif-drops-spec-required-co-reporting.md)

## ソース

- [PR #2231 fix results (cycle 3)](../../raw/fixes/20260810T150514Z-pr-2231.md)
