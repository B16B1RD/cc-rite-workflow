---
type: "heuristics"
title: "SoT 同期は detection 側と authoring 側の双方向に書く — 片側だけでは機構が silent に空振りする"
domain: "heuristics"
promote: rite-plugin
description: "「アンカーが特定の regex にマッチしたら blocking として扱う」のような機構は、**検出する側**（assessment-rules.md / SKILL.md の判定ステップ）と**書く側**（`_reviewer-base.md` / reviewer-prompt-generator.md）の 2 つの SoT を持つ。"
created: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260726T160331Z-pr-2030.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T130838Z-pr-2030.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T161811Z-pr-2030.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T131902Z-pr-2030.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-27T10:57:51+09:00" }
---

# SoT 同期は detection 側と authoring 側の双方向に書く — 片側だけでは機構が silent に空振りする

## 概要

「アンカーが特定の regex にマッチしたら blocking として扱う」のような機構は、**検出する側**（assessment-rules.md / SKILL.md の判定ステップ）と**書く側**（`_reviewer-base.md` / reviewer-prompt-generator.md）の 2 つの SoT を持つ。detection 側にだけ制約を書くと、authoring 側は制約を知らないまま成果物を生成し、機構は no-match で silent に空振りする。

## 詳細

### 観測された失敗

起点事例は `Verification:` アンカーの regex がテーブルのセル境界に束縛されるため raw パイプ（`|`）を含む repro が no-match になる、という制約を detection 側にだけ書いた。reviewer が実際に読む authoring 側 SoT には無かったため、canonical な再現イディオム（`printf ... | jq`）を含む指摘がそのまま降格される経路が開いた。

**同期規約を自分で書いた PR が、その規約に違反していた**。

### 3 層波及チェックリスト

仕様ゲートを導入するときの波及先（cycle 1 で確立）:

| 層 | 内容 | 漏れたときの症状 |
|---|---|---|
| (a) authoring 指示層 | reviewer 指示・プロンプトテンプレート・few-shot 例 | 新機構が指示レベルで無効化される（成果物が制約を満たさない） |
| (b) 下流消費層 | 分類ロジック・収束条件・全読取経路 | カウンタ非対称・routing 不能な状態が生まれる |
| (c) 契約宣言層 | schema の enforcement 主体宣言 | 実装ゼロの機能を「実装済み」と宣言する |

ゲート本体だけ直しても、3 層のどれかが旧前提だと機構は silent に無効化される。

### enforcement 主体は grep で裏取りする

schema に「read 側でも検出する」と書くなら、その emitter が実在することを grep で確認する。起点事例では schema doc が read 側 auto-correct（invariant #6）を宣言したが実装がゼロで、4 レビュアーが独立に検出した。

### 修正時は相互参照を張る

片側を直したら、もう片方に「この制約の反対側 SoT は X」と明記する。次回の drift が grep で検出可能になる。

### ガイダンス追加と観測 marker 追加はセットで行う

authoring 側に制約を伝播しても、**守られなかった場合の観測性**がなければ silent failure は残る。起点事例では「アンカーに raw pipe を含めない」制約を伝播したが、守られなかったケース（パイプ入り repro）は regex no-match で無音降格したままだった。実測済みの指摘が誰にも気付かれず non-blocking に落ちる。

**処方**: fail-safe（no-match なら降格）は緩めず、「アンカー文字列はあるが full regex が no-match」を 2 段判定で切り出して WARNING + cause 付き marker を出す。**fail-safe の維持と観測性の追加は両立する**。

### SoT を直したら実行文書を grep する

SoT（assessment-rules.md）の条件を広げても、実際に LLM が読む実行文書（pr-review/SKILL.md）が旧条件のままなら実効ルールは変わらない。**SoT 修正時は「その SoT を実装／反復している側」を必ず grep する**。SoT chain が多段（SPEC → CONFIGURATION → template）なら末端まで辿る。

## 関連ページ

- [同一手順が複数 site に分散する場合は片方を canonical source と宣言する](../patterns/canonical-source-declaration-for-multi-site-procedure.md)
- [SoT-reviewer 表現 drift: pos/neg 方向の差で派生記述が silent drift する](../anti-patterns/sot-reviewer-expression-drift.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [保存パス基準の変更は観測面と全 caller 引数の同時スイープが必要](./path-basis-change-observation-surface-sweep.md)

## ソース

- [PR #2030 review results](../../raw/reviews/20260726T160331Z-pr-2030.md)
