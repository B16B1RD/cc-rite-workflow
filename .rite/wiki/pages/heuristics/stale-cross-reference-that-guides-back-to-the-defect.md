---
type: "heuristics"
title: "陳腐化した相互参照には「ただ古い」ものと「修正した欠陥へ戻す誘導」がある"
domain: "heuristics"
promote: rite-plugin
description: "相互参照が古くなったとき、実害の大きさは 2 段階に分かれる。"
created: "2026-07-30T01:20:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260729T153523Z-pr-2051-c3.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T153947Z-pr-2051-c3.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-30T01:20:00+09:00" }
---

# 陳腐化した相互参照には「ただ古い」ものと「修正した欠陥へ戻す誘導」がある

## 概要

相互参照が古くなったとき、実害の大きさは 2 段階に分かれる。単に事実と合わなくなっただけのものと、**それを読んだ次の編集者を、いま塞いだばかりの欠陥へ誘導するもの**である。後者は「古い記述」として優先度を下げてはならず、正しい記述への置換に加えて「なぜ現状がこうなっているか」の理由まで書く必要がある。

## 詳細

### 実測された誘導経路

`wiki-ingest/SKILL.md` のステップ 8.1 に、次の記述があった。

> ステップ 1.1 と同じ YAML パーサで `auto_lint` を読み取る

起点事例でステップ 1.1 を helper（`parse_wiki_scalar`）への委譲に変えた時点で、この記述は偽になった。だがそれだけではない。

- ステップ 1.1 の**旧形**は `awk -v k="$1" '$0 ~ "^[[:space:]]+" k ":"'` で、skill loader が本文の位置パラメータを起動引数へ展開するため壊れる形だった（これが起点事例で塞いだ欠陥そのもの）
- ステップ 8.1 の awk は `/^[[:space:]]+auto_lint:/ { print; exit }` という bare regex 形で、位置パラメータを参照しないため**壊れない**
- しかし「1.1 と同じパーサ」という記述を信じた編集者は、8.1 を 1.1 に「揃える」ために旧形を持ち込む可能性がある

つまり陳腐化した相互参照が、**修正した欠陥を再導入する経路**になっていた。

### 対処: 事実 + 理由の両方を書く

```markdown
ステップ 1.1 とは**別の** inline lenient パーサで `auto_lint` を読み取る。
ここの awk は位置パラメータ（`$0` / `$N`）を参照しない bare regex 形のため、
skill loader の引数展開を受けず、委譲しなくても壊れない。
**ステップ 1.1 の旧形（`$0 ~ pattern` を使う汎用 helper 関数）をここへ持ち込んではならない** —
静的検出は `hooks/scripts/dollar-zero-check.sh` が担う。
```

「別のパーサである」という事実だけでは、次の編集者が「じゃあ揃えるべきか？」と考える余地が残る。**揃えてはならない理由**を書いて初めて誘導が閉じる。

### トリアージの基準

陳腐化した参照を見つけたとき、次を問う。

| 問い | Yes なら |
|---|---|
| この記述を信じて編集すると、直近で修正した欠陥が戻るか | **最優先で修正 + 理由を追記** |
| この記述を信じると、別の既知の落とし穴に落ちるか | 修正 + 理由を追記 |
| 事実と違うだけで、誤った行動を誘発しないか | 通常の drift 修正 |

### 過剰な一般化も同じ誘導を作る

起点事例では、逆方向の誤りも見つかった。「skills が inline パーサを持てないのは Skill loader が本文の位置パラメータを起動引数へ展開するため」という断定が、**同じファイルの 14 行上で自身が列挙している 2 つの安全な site と矛盾**していた（それらは bare regex 形で正常動作している）。正しい規則は「**位置パラメータを参照する** パーサを skill 本文に置けない」である。

過剰に広い断定は、安全な既存実装を「壊れている」と誤読させ、不要な委譲を誘発する。**断定を書くときは、その断定が同一ファイル内の既存の列挙と矛盾しないかを確認する**。1 箇所を正確化すると、同型の断定が残っている他箇所が相対的に露見するため、修正は全数スイープで行う。

## 関連ページ

- [状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)](../anti-patterns/stale-historical-comment-after-state-change.md)
- [inline 実装を helper へ委譲したら、診断メッセージを新しい失敗分布へ揃える](./delegation-shifts-failure-mode-distribution.md)
- [Scope drift fix での overclaim substitution (置換後に新たな過剰主張を持ち込む)](../anti-patterns/scope-drift-fix-overclaim-substitution.md)
- [「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる](./exhaustiveness-claims-require-mechanical-inventory.md)

## ソース

- [PR #2051 review results (cycle 3)](../../raw/reviews/20260729T153523Z-pr-2051-c3.md)
- [PR #2051 fix results (cycle 3)](../../raw/fixes/20260729T153947Z-pr-2051-c3.md)
