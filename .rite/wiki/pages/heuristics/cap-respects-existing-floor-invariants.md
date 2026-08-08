---
type: "heuristics"
title: "上限機構(cap)の追加は既存の下限・補完機構が確立した floor を全経路で尊重する"
domain: "heuristics"
promote: rite-plugin
description: "選定パイプラインに上限(cap)機構を後段追加すると、既存の下限・補完機構(min_reviewers / sole-reviewer guard ≥2 / mandatory 保護)が確立した floor を silent に undo しうる。cap は全 valid 入力・全経路で既存 floor を尊重し cap/guard/mandatory/min の invariant を再調停する。"
created: "2026-07-02T23:12:48Z"
updated: "2026-07-02T23:12:48Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260702T223143Z-pr-1729.md"
  - type: "fixes"
    ref: "raw/fixes/20260702T224204Z-pr-1729.md"
  - type: "fixes"
    ref: "raw/fixes/20260702T225338Z-pr-1729.md"
  - type: "reviews"
    ref: "raw/reviews/20260702T222623Z-pr-1729.md"
  - type: "reviews"
    ref: "raw/reviews/20260702T223947Z-pr-1729.md"
  - type: "reviews"
    ref: "raw/reviews/20260702T225129Z-pr-1729.md"
  - type: "reviews"
    ref: "raw/reviews/20260702T230045Z-pr-1729.md"
tags: []
confidence: high
---

# 上限機構(cap)の追加は既存の下限・補完機構が確立した floor を全経路で尊重する

## 概要

既存の選定/補完パイプライン（例: reviewer 選定）に**上限機構 (cap, cost 上限)** を後段挿入すると、既存の**下限・補完機構**が確立した floor を silent に undo する穴が生じる。floor には少なくとも 3 系統がある: `min_reviewers`（明示下限）、sole-reviewer guard（最小構成 ≥2 の補完）、mandatory 保護（特定 reviewer の drop 禁止）。cap は「補完を妨げない」原則に従い、これら全 floor を**全 valid 入力・全経路**で尊重するよう `cap / guard / mandatory / min` の 4 者 invariant を再調停しなければならない。「min のみ」で下限判定すると別経路の floor（guard の ≥2、mandatory 保証）を割ってしまう。

## 詳細

起点事例（`/rite:review` へ max_reviewers 上限と選定サマリを導入）は、この 4 者調停を巡って 4 cycle（MEDIUM 2 → 1 → 1 → 0）で構造的に収束した。cycle ごとに surface した learning:

- **cycle 1 — 保護対象一般化の副作用と SoT 二重定義**:
  - mandatory 保護を「Security のみ hard-protect」から「全 `selection_type=mandatory`」へ一般化したが、cap 決定表に「**全員 mandatory かつ cap 超過**」の未定義分岐が生まれた（保護対象を広げると drop 対象が枯渇する副作用）。→ 保護対象の一般化は cap 決定表の**全 valid 入力被覆**を要求する（全員 mandatory かつ cap 超過なら「cap を mandatory 保証に譲る」と明示）。
  - "do not duplicate" と宣言しながらアルゴリズムを wiring 側に丸ごと再掲する **SoT/wiring 責務分担の破れ**（二重定義 drift）。→ wiring 側（Phase 3.2.1）を SoT（Phase 5 = アルゴリズム）への参照へ縮約して解消。
  - ドキュメントが実装より広い保証を主張する **doc-implementation inconsistency**（"never drops a mandatory reviewer" vs 実装は Security のみ hard-protect）。→ 実装側を doc に合わせて一般化する方が挙動も自然（[[prose-design-without-backing-implementation]] の逆方向対応）。
  - 表示プレースホルダの未定義スカラー（複合ソートキーを単一 `{score}` と表現し二重表示）。→ 一次キー（matched file count）主体へ一本化して曖昧さを排除。

- **cycle 2 — 新 invariant の波及漏れ**:
  - 下限クランプ（新 invariant）を導入したら、それに依存する**全ての固定値メッセージ・doc 記述**へ波及させる必要がある（"既定 6" のような固定値メッセージが実効値と食い違う）。
  - 新語彙（`normal` / `non-mandatory` selection_type）は**導入と同時に定義**する。

- **cycle 3 — floor undo の本丸**:
  - cap を既存の補完機構（sole-reviewer guard）の**後段**に挿入すると、guard が確立した最小構成（≥2）を cap が silent に undo する穴が生じる。cap は `min_reviewers` だけでなく **guard floor も尊重**する必要がある。
  - 新機構の挿入位置は既存判定（`count` 参照の 4+ 分割等）の **pre/post を変える**点に注意し、判定が確定値を見る旨を明記する。

- **cycle 4 — 収束**:
  - `cap ⇄ guard ⇄ mandatory ⇄ min` の 4 者調停が**全経路で invariant を満たし**、全 fallback に WARNING が付随して silent failure を排除（[[silent-fallback-observability-via-debug-log]]）。SoT 分離（Phase 5 = アルゴリズム / 3.2.1 = wiring）で二重定義 drift を防止。残る non-blocking 観察（docs の guard-floor 明記）は正確性を損なわず収束を尊重してスコープ外とした。

### 適用ガイド

1. **floor の棚卸し**: 新しい上限/制約機構を追加する前に、既存の下限・補完機構（明示下限 / 補完 guard / 保護対象）を grep で全列挙する。
2. **決定表の全分岐被覆**: 保護対象の一般化・下限クランプ導入は決定表の全 valid 入力（特に「保護対象が全件」「cap < floor」の corner）を被覆する。
3. **挿入位置の pre/post 検証**: 新機構が既存判定の参照する値（count 等）を pre/post で変えないか、判定が確定値を見るかを確認する。
4. **波及と語彙**: 新 invariant に依存する固定値メッセージ・doc を同時に波及更新し、新語彙は導入と同時に定義する。
5. **fallback の可視化**: 全 fallback 経路に WARNING を付し silent failure を排除する。

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [resolver / helper 失敗時の silent fallback は debug log で観測性を確保する](../patterns/silent-fallback-observability-via-debug-log.md)
- [前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する](../anti-patterns/silent-precondition-omit-disables-and-defense-chain.md)

## ソース

- [PR #1729 fix results](../../raw/fixes/20260702T223143Z-pr-1729.md)
