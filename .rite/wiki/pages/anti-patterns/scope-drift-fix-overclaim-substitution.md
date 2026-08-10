---
title: "Scope drift fix での overclaim substitution (置換後に新たな過剰主張を持ち込む)"
domain: "anti-patterns"
description: "虚偽の test 担保宣言・scope 範囲・契約宣言を「scope を限定する正確な表現」に置換する fix で、reviewer が指摘した overclaim (例: `... で test 担保`) を解消する際、置換後の言い換えに別種の overclaim 語彙 (`固有 (unique to)`、`専用 (specific to)`、`全て (all)`、`必ず (always)` 等) を持ち込むリスク。"
promote: rite-plugin
created: "2026-05-15T10:05:00+09:00"
updated: "2026-07-29T21:32:36+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260515T005613Z-pr-969.md"
  - type: "fixes"
    ref: "raw/fixes/20260515T005734Z-pr-969.md"
  - type: "reviews"
    ref: "raw/reviews/20260515T010126Z-pr-969.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T045143Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T045549Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T085910Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T064931Z-pr-2044.md"
tags: []
confidence: high
---

# Scope drift fix での overclaim substitution (置換後に新たな過剰主張を持ち込む)

## 概要

虚偽の test 担保宣言・scope 範囲・契約宣言を「scope を限定する正確な表現」に置換する fix で、reviewer が指摘した overclaim (例: `... で test 担保`) を解消する際、置換後の言い換えに別種の overclaim 語彙 (`固有 (unique to)`、`専用 (specific to)`、`全て (all)`、`必ず (always)` 等) を持ち込むリスク。fix-introduced finding として cycle 1 で検出されやすい。所有格 (`の`) や限定形容 (`での`、`に関する`) のみを使い、絶対化を含意する語彙は意図的に回避する。

## 詳細

### 失敗 mode

scope drift 解消の fix で典型的に発生する流れ:

1. 初回コード/コメントに `A は B で test 担保` のような **virtual claim** がある (実は B の test scope には A が含まれない false claim)
2. reviewer が virtual claim を指摘
3. fix で「A は本 sub-skill 固有の C」「A は専用の D」のように **新たな overclaim 語彙** を持ち込む置換を行う (固有 = "他に存在しない"、専用 = "他では使われない" を含意)
4. 次の cycle で別 reviewer が新 overclaim 指摘 (実際は他 sub-skill でも C/D pattern が共有されている → 2 件目の虚偽記述)

### 検出指標 (cycle 1 で具体検出された evidence)

| シグナル | 検出方法 |
|---------|---------|
| 置換後に `固有 (unique to)` / `専用 (specific to)` / `全て (all of)` / `必ず (always)` 等の絶対化語彙が新規登場 | reviewer が `grep -lE -- "--<flag-name>"` 等で 「実際は何箇所で使われているか」を確認し、置換後の主張と矛盾しているか judge |
| Cross-file consistency check で「A 以外の場所にも同 pattern が存在」を grep で示せる | reviewer の cross-file impact check (`_reviewer-base.md` Cross-File Impact Check section) で発火 |

### 回避規範

scope を限定する fix を書く際の語彙選択:

| 用途 | 推奨 | 回避 |
|------|------|------|
| 所属表現 | `本 sub-skill **の** X`、`本 sub-skill **での** X` | `本 sub-skill **固有の** X`、`本 sub-skill **専用の** X` |
| 否定形による scope 限定 | `... は本 sub-skill **は対象外**` | `... は本 sub-skill **でのみ** 該当` |
| 並列性の明示 | `(同 pattern は他 sub-skill / X workflow でも使用される共有 pattern)` | (補足なし) — 後段の reviewer が overclaim を疑う材料を与えない |

### 具体事例

- **cycle 0（起票時）**: `start-finalize.md:36` に「4 引数 symmetry は `4-site-symmetry.test.sh` で test 担保」(virtual claim — test SITES には start-finalize.md は含まれていない)
- **cycle 1 fix**: 「`本 sub-skill 固有の` Pre-flight pattern。`4-site-symmetry.test.sh` は create-interview workflow 専用で本 sub-skill は対象外」に置換 (virtual claim は解消されたが「固有」が新 overclaim)
- **cycle 1 review (code-quality, Confidence 80)**: 「4 引数 pattern は実際は他 sub-skill でも使用される共有 pattern なので「固有」は事実誤認」と指摘
- **cycle 2 fix**: 「本 sub-skill **での** Pre-flight pattern (同 pattern は他 sub-skill / create-interview workflow でも使用される共有 pattern)」に再置換 (所有格のみ、並列性も明示)
- **cycle 2 review**: 両 reviewer ともに 0 findings 収束

### 設計判断としての価値

本 anti-pattern を識別することで、初回 fix で「固有」「専用」等を使いそうになった瞬間に self-check 可能になる。reviewer cross-file impact check が cycle 1 で発火する確率は高いが、cycle を 1 つ節約できる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #969 cycle 1 review](../../raw/reviews/20260515T005613Z-pr-969.md)
- [PR #969 fix results](../../raw/fixes/20260515T005734Z-pr-969.md)
- [PR #969 cycle 2 review (mergeable convergence)](../../raw/reviews/20260515T010126Z-pr-969.md)

## 変種: 「窓を狭めた」を「窓を閉じた」と書く

中断窓を「review invoke + ステップ 6 全体」から「共有前段 → sentinel 出力」へ**縮める**修正をしたのに、散文 5 箇所で「そういう経路を持たない」と無条件に断定した（2 レビュアーが独立検出）。

> **教訓**: 窓を狭める修正をしたら、**残った窓の大きさを書く**。「閉じた」と書けるのは、残存窓がゼロであることを示せるときだけ。縮小と消滅を書き分けないと、後続の実装者は「ここはもう安全」と読んで別の変更で窓を広げる。あわせて「完全な閉塞には何が必要で、なぜ今やらないか」まで書くと、別 Issue 化の判断材料が残る。

## 変種: 同一 API の default 挙動を、呼び出しごとに書き下さない

`flow-state.sh set` は `--handoff` を伴わないと handoff を default-clear する。fire 分岐についてはこれを正しくモデル化していたのに、同じ commit で新設した共有前段の set については「再セットしない」（受動）としか書かず、「クリアする」（能動）に踏み込まなかった。結果、停止通知が「counter reset に失敗＝handoff クリアにも失敗」という**成立しない連言**を人間に断定した（3 レビュアーが同一 file:line を検出）。

> **教訓**: default 挙動を持つ API を複数箇所で呼ぶなら、**各呼び出しについて default が何をするかを個別に書き下す**。1 箇所で正しく書けたことは、他の箇所で正しく書けている保証にならない。副産物として、consumer を持たなかった marker に条件分岐という consumer が付いた — **未消費 marker は「まだ書かれていない条件がある」ことの兆候として使える**。

## 変種: 部分的な留保は、無留保より誤解を生む

実装が best-effort（2 つの write のいずれか成功に依存）なのに canonical spec が「〜が必要」と無条件に書き、**片方の caveat だけ**を添えた。読者は「留保は列挙し尽くされている」と合理的に推論するため、部分的な留保は無留保より誤解を生む。留保が 2 つあるなら両方書くか、委譲先へ導線を張る。

同型の失敗として、**宣言の適用範囲を書いていない**形もある。「両分岐は同構造」が停止時の挙動については正しくても失敗記録の永続性については成り立たない、というケースで、**概要節と詳細節の両方に同じ宣言があると、但し書きを詳細節にだけ足しても概要節の単独読者は救えない**。伝播スキャンで概要節も補正する必要があった。

また **blast radius の量化は、その N を決める制御フローが LLM の裁量を経由するなら書けない**。「N cycle で収まる」の可否について 3 レビュアーの見解が割れ、討論フェーズは「確定的に量化しない」で合意した。

## ソース（追記分）

- [PR #2044 review results (cycle 3) — 縮小を消滅として書く / per-callsite default](../../raw/reviews/20260729T045143Z-pr-2044.md)
- [PR #2044 fix results (cycle 3) — コード変更ゼロ・散文のみ 24 行の修正](../../raw/fixes/20260729T045549Z-pr-2044.md)
- [PR #2044 fix results — 宣言の適用範囲、概要節と詳細節の両方を補正](../../raw/fixes/20260729T085910Z-pr-2044.md)
- [PR #2044 fix results (cycle 2) — 部分的な留保は無留保より誤解を生む](../../raw/fixes/20260729T064931Z-pr-2044.md)
