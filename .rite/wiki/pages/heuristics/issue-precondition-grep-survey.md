---
title: "Issue 起票前の grep 棚卸しで「違反あり」前提が既に解消済みか確認する"
domain: "heuristics"
description: "charter 違反 / refactor 残作業を扱う Issue を起票するとき、Issue body に書く「違反あり」「残作業あり」前提は既に過去の関連 PR で解消済みのケースがある。"
promote: rite-plugin
created: "2026-05-08T15:34:21+00:00"
sources:
  - type: "retrospectives"
    resource: "raw/retrospectives/20260508T153421Z-issue-892.md"
  - type: "reviews"
    resource: "raw/reviews/20260830T053201Z-pr-2477.md"
tags: ["issue-management", "grep", "precondition-verification", "scope-management", "charter"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-30T05:45:00Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-08-30T05:45:00Z"
---

# Issue 起票前の grep 棚卸しで「違反あり」前提が既に解消済みか確認する

## 概要

charter 違反 / refactor 残作業を扱う Issue を起票するとき、Issue body に書く「違反あり」「残作業あり」前提は既に過去の関連 PR で解消済みのケースがある。Issue 起票時に `grep` ベースで前提を一通り棚卸しすれば、無駄な PR 起こしを回避できる。起点事例 (Phase D) では起票時「違反あり」と仮定した内容が、実際は Phase A-C で全削除済みで、合計目標 (≤1627 行) も達成済みだった。`Issue #N` / `PR #N` / `cycle N` / `Drift guard` / `NFR-N` 等の項目別 grep を最初に実施することが運用 invariant として価値を持つ。

## 詳細

### 失敗 → 学び（retrospective）

起点事例は `/rite:pr:cleanup` Phase D の追加 slim を扱う Issue として起票された:

- 起票時の前提: archive-procedures.md / bash-trap-patterns.md に charter §禁止パターン違反が複数残存
- 着手時の grep 棚卸し: 両ファイルとも違反 0 件と判明
- 合計目標 (AC-2: ≤1627 行) も既達成 (現状 1618 行)
- 結果: PR を作成せず DoD 見直しのみで close

「違反あり」と仮定して起票したが、実際は Phase A-C の累積で全 PR 不要状態に到達していた。

### canonical workflow

Issue 起票直後 (Phase 0) に以下の grep checklist を実施:

```bash
# charter §禁止パターン (cleanup workflow を例に)
for pattern in 'Issue #[0-9]+' 'PR #[0-9]+' 'cycle [0-9]+' 'Drift guard' 'NFR-[0-9]+'; do
  echo "=== $pattern ==="
  grep -rEn "$pattern" plugins/rite/commands/pr/cleanup.md \
    plugins/rite/commands/pr/references/ 2>/dev/null | wc -l
done

# 合計目標 (行数 / ファイル数) の現状確認
wc -l plugins/rite/commands/pr/cleanup.md
find plugins/rite/commands/pr/references -name '*.md' | xargs wc -l | tail -1
```

各項目で「件数 0 ✅」「件数 N (target M)」を判定し:

- 全項目達成済み → DoD 見直しで close (PR 不要)
- 一部達成済み → Issue scope を未達成項目のみに narrow して PR 起こし
- 全未達成 → 当初予定どおり PR 起こし

### 設計原則 — charter §自己観察

「シンプル化作業が新たな複雑性を生む自己言及ループ」を起こさないため、charter 違反が無い記述を「既存目標があるから」という理由で削るのは charter 自身に反する。合計目標達成 + 違反 0 件の場合は、Issue body の DoD を見直して close する判断が canonical。

### `/rite:issue:close` 経路の活用

`/rite:issue:start` のフローは PR 作成前提だが、合計目標達成済みかつ追加 PR 不要と判明した場合は以下が canonical 経路:

1. `gh issue edit <number>` で Issue body を更新 (DoD を「Phase A-C で達成済み」に書き換え + grep evidence を貼り付け)
2. `/rite:issue:close <number>` で close (PR を介さず直接 close)
3. close comment に「accumulated PR (#XXX, #YYY, #ZZZ) で AC 達成、本 Issue は別 PR を作成せず close」と明記

これにより Issue 履歴に「PR を作らなかった経緯」が残り、後続 reviewer が「なぜこの Issue は PR が無いのか」と疑問に思う回路を排除できる。

### 棚卸しのもう一方の軸 — 前提の解消確認だけでなく「記述箇所の網羅」も測る

上記の起点事例は「前提が既に解消済みか」を測る軸だった。同じ grep 棚卸しには **「その対象を説明している箇所が他にいくつあるか」を測る軸**もあり、こちらを省くと逆向きの失敗、すなわち **1 箇所だけ直して他が古いまま残る部分修正**が生じる。

観測事例: setup スキルの hook 登録表 2 箇所で 1 hook の Purpose が片方の経路しか説明していない欠落を直す Issue を、その 2 表だけをスコープとして起票した。マージ後のレビューで、同じ hook を説明する箇所が他に 4 つ（`docs/SPEC.md` の hook 一覧表 2 行と別節の 1 文、`CONTRIBUTING.md` のディレクトリ構造コメント、setup スキル自身の LEGACY 用登録表）残っていることが判明した。Issue は正しくスコープを守って完遂されたにもかかわらず、リポジトリ全体では同種の drift が残った。

したがって、ドキュメント修正 Issue を起票する前の grep は 2 問を並べて答える:

1. **前提は生きているか** — 直そうとしている記述はまだ古いままか（既に解消済みなら Issue 自体が不要）
2. **記述箇所は何箇所か** — 同じ対象を説明する箇所を全ファイル横断で列挙し、そのうちどれをスコープに含めるかを明示的に決める

2 番目で列挙した箇所をスコープから外すのは正当な判断だが、**列挙せずに外すのは判断ですらない**。列挙結果を Issue body に残しておけば、スコープ外とした箇所は後続の follow-up として拾える。

### 説明の分散が構造化されている箇所は検出器化を検討する

上記事例で最も確度が高かった指摘は、`docs/SPEC.md` の hook 一覧表が **自身を `hooks.json` の mirror だと明記しながら実際には登録エントリの一部しか反映していなかった**ことだった。片側が機械可読な registry（`hooks.json`）で、もう片側が定型テーブルという構成では、drift は grep 棚卸しではなく専用チェッカで恒常的に検出できる（既存の `reviewer-registry-drift-check.sh` が `agents/` と reviewer 一覧表に対して同じことをしている）。

散文どうしの整合は人間・LLM の判断に残すしかないが、**registry ↔ 定型テーブル**の形をしていると気付いたら、その 1 箇所は heuristic ではなく検出器へ移す。

### 関連 anti-pattern

- 「すべての Issue は PR を持つべき」と機械的に仮定すると、本ケースのように **着手前の前提検証で破綻している** Issue でも PR を作成して charter 違反を新規導入するリスクがある
- [Scope Creep Rejection Empirical Gate](./scope-creep-rejection-empirical-gate.md) と相補関係: scope 外の指摘は demote、scope 内の前提が既に解消済みなら Issue 自体を close

## 関連ページ

- [Scope Creep Rejection Empirical Gate](./scope-creep-rejection-empirical-gate.md)
- [Issue Body Scope Out Policy Demotes Advisory Finding](./issue-body-scope-out-policy-demotes-advisory-finding.md)
- [Empirical Reproduction Over Invariant Reasoning](./empirical-reproduction-over-invariant-reasoning.md)

## ソース

- [close retrospective](../../raw/retrospectives/20260508T153421Z-issue-892.md)
- [レビュー結果](../../raw/reviews/20260830T053201Z-pr-2477.md)
