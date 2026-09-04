---
type: "anti-patterns"
title: "テストの gate 条件がプラットフォーム事実を環境 capability の代理にすると恒常 red 化する"
domain: "anti-patterns"
promote: rite-plugin
description: "テストの floor（skip を禁じて fail させるガード）が、守りたい性質そのものではなく「プラットフォーム事実」を代理指標にしていると、代理の成立しない環境で恒常的に赤くなりスイート全体の signal を劣化させる。"
created: "2026-08-04T00:55:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260803T155051Z-pr-2096.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-04T00:55:00+09:00" }
---

# テストの gate 条件がプラットフォーム事実を環境 capability の代理にすると恒常 red 化する

## 概要

テストの floor（skip を禁じて fail させるガード）が、守りたい性質そのものではなく「プラットフォーム事実」を代理指標にしていると、代理の成立しない環境で恒常的に赤くなりスイート全体の signal を劣化させる。コメントと条件式の乖離が、この代理指標ズレの検出点になる。

## 詳細

`wiki-ingest-trigger.test.sh` の TC-036a は `/tmp/rite-*` prefix の受理を検証する。`/tmp` に書けない環境では検証不能なので、「blocking gate では skip させない」という契約を floor で守っていた。その floor の条件が `[ -d /proc ]`（= Linux か）だった。

守りたかったのは「この capability が保証される環境か」であって「Linux か」ではない。`/tmp` の書込可否は環境の capability であってプラットフォームの事実ではないため、sandbox が `/tmp` を読み込み専用でマウントする開発機（Linux）も blocking gate と判定され、スイートは 110/111 が恒常状態になった。実質的な回帰が起きても「いつもの 1 件」に埋もれる。

**検出点はコメントと条件式の乖離だった**。floor のコメント自身が `writability of /tmp is a capability probe, not a platform fact` と正しく述べていながら、実装は platform 事実の代理（`[ -d /proc ]`）を使っていた。コメントが性質を正しく言語化しているのに条件式がそれと違う対象を見ているとき、代理指標のズレを疑う。

**同じ形の gate が並んでいても、probe の対象で正しい条件式は変わる**。同スイートには `[ -d /proc ]` floor が 6-8 箇所あるが、それらが probe しているのは perl / flock / GNU realpath / GNU date / readlink の**ツール存在**で、Linux では実質プラットフォーム事実に近い（無ければ環境が壊れている）。今回だけが**環境 capability**（同じ Linux でもマシンごとに変わる）を probe していた。形の一貫性を根拠に条件式を揃えると、この差異を潰してしまう。

是正は floor 条件を `[ -n "${CI:-}" ] && [ -d /proc ]` にし、capability が実際に保証される環境（CI が blocking gate と定める Linux leg）を名指しする形へ変えた。契約は空洞化しない — CI では従来どおり fail するため、カバレッジ落ちを緑のまま見逃す経路は生じない。ローカルの skip も `run-tests.sh` が gated group として集計するため silent にはならない。

**レビューでの副次的観察**: 4 レビュアーのうち 3 名が「テスト作成の SoT である CONTRIBUTING.md が floor の綴りを `[ -d /proc ]` と固定しており本変更で drift する」「skip メッセージが `CI` と書くが実際は `Linux CI` が正確」という**記述と条件式の 1:1 対応ずれ**を指摘した。いずれも挙動的帰結を持たない字面整合クラスで、実測必須ゲートにより non-blocking へ降格した。gate 条件を変えるとき、その条件を綴りレベルで固定している文書が SoT 側に存在しないかを併せて確認する価値がある。

## 関連ページ

- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](../anti-patterns/locale-dependent-error-message-grep-assertion.md)
- [CI lint チェックを blocking gate に昇格するときはツール自身の exit code を gate にする](../heuristics/ci-blocking-gate-tool-exit-code.md)

## ソース

- [レビュー結果](../../raw/reviews/20260803T155051Z-pr-2096.md)
