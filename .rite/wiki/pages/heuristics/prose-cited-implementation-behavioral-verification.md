---
title: "散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする"
domain: "heuristics"
description: "SoT 散文 / 設計ドキュメントが実装 (正規表現リテラル・helper file・挙動主張) を要約参照するとき、レビューは「散文を読む」だけでは整合を保証できない。"
created: "2026-06-02T00:07:23Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260601T185616Z-pr-1238.md"
  - type: "reviews"
    resource: "raw/reviews/20260601T191319Z-pr-1238.md"
  - type: "fixes"
    resource: "raw/fixes/20260601T190814Z-pr-1238.md"
tags: ["verification-protocol", "prose-implementation-sync", "regex", "behavioral-test", "attribution"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-02T00:07:23Z" }
---

# 散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする

## 概要

SoT 散文 / 設計ドキュメントが実装 (正規表現リテラル・helper file・挙動主張) を要約参照するとき、レビューは「散文を読む」だけでは整合を保証できない。3 点を機械的に裏取りする:

1. **文字一致**: 散文が引用する regex literal が実装ファイルの実体と byte 単位で一致するか (Cross-File Impact Check)
2. **帰属精度**: 散文が regex を帰属させたファイルが、実際にその regex を保持するファイルか (wrapper / 委譲先の取り違え)
3. **behavioral test**: 散文が主張する挙動 (match / non-match) を、実際にその regex を代表ケース群にかけて実測確認したか

prompt-engineer + code-quality の 2 cycle 収束・0 blocking findings の実測で、3 点すべてが review/fix 技法として有効に機能し、cycle 2 まで independent cross-validation された。

## 詳細

### 背景となった起点事例

`commands/init.md` の rite hook 検出基準を「散文の plain substring `rite/hooks/`」から「`rite` を完全 path segment とする SoT (`RITE_HOOK_RE` = `(?:^|/)rite/(?:[^/]+/)?hooks/`)」へ統一する doc PR。散文が helper 実装の regex を要約参照するため、散文と実装の整合検証が review の中心になった。

### 1. 文字一致 — 引用 literal の byte 単位 cross-check

散文が引用する正規表現リテラル `(?:^|/)rite/(?:[^/]+/)?hooks/` が、実体 (`settings-local-rite-hook-cleanup.py:33` / `session-start.sh:201`) と文字単位で一致するかを Cross-File Impact Check で検証する。散文の regex は「読者がコピペ origin にする」ため、1 文字の drift も誤誘導になる ([canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md) と同根)。

派生して観測された **pre-existing リスク (本 PR 由来ではない)**: 同一 regex が `.py:33` と `session-start.sh:201` の 2 箇所に独立コピーとして存在し、散文を含めると 3 系統になる。複数コピーは将来片方のみ更新する drift リスクを孕むため、regex 単一定義化 (共有 source 化) を follow-up Issue 候補として boundary 分類で切り出した (scope 規律: 本 PR では touch しない)。

### 2. 帰属精度 — wrapper / 委譲先の取り違えを避ける

新規 SoT 定義で regex 等の実体を要約参照する際、`.sh` wrapper が `.py` へ JSON 変換 (regex 適用) を委譲する**二層構造**を `.sh` 一語で要約すると、「regex 実体ファイル」の誤帰属を生む。読者が wrapper (`.sh`) を開いても regex が見つからない誘導ミスになる（F-01、code-quality LOW-MEDIUM → ユーザー承認で current-pr scope に昇格して fix）。

canonical: helper を散文参照するときは「regex 実体ファイル (`.py`)」と「python3 guard / atomic write の wrapper (`.sh`)」を区別するか、拡張子なし basename で両者を包含する表記にする。wrapper が regex を持たず別ファイルへ委譲する構造では、帰属先を grep で確認してから散文を書く ([Documentation review は対応する実装側の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md) の帰属軸への拡張)。

### 3. behavioral test — 挙動主張を実 regex で実測する

散文が主張する「look-alike 非マッチ / cache version 形マッチ / version segment 1 個許容」を、**代表ケース群に実際の regex をかけて実測確認**する。起点事例の cycle 2 では両レビュアーが独立に 8 ケースの behavioral test を実施した:

| ケース群 | 例 | 期待 |
|----------|-----|------|
| must-match | dev 形 `rite/hooks/` / cache 形 `rite/0.2.0/hooks/` | match |
| must-not-match (look-alike) | `favorite/hooks/` / `prerite/hooks/` / `rite-something/hooks/` | non-match |
| must-not-match (segment 過多) | version segment 2 個 `rite/a/b/hooks/` | non-match |

「散文の主張を読むだけ」でなく実際に regex を実行して claim を裏取りすると、散文の不正確さも検出できる (例: `(?:[^/]+/)?` は version に限らず任意単一セグメント許容のため、「version segment」という表現はやや不正確 — 実害なしの推奨事項として surface)。これは [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](./empirical-reproduction-over-invariant-reasoning.md) の regex/散文版。

### 適用範囲

- SoT 散文 / 設計ドキュメントが regex・閾値・path 形状など実装の挙動を要約参照する PR
- helper が wrapper → 実体へ委譲する二層 (以上) 構造をもつ実装を散文が参照するケース
- substring → segment-anchored への正規表現厳格化 ([path セグメントの substring マッチが look-alike を誤マッチし対象を silent に over-remove する](../anti-patterns/path-segment-substring-over-match.md) の検証手法として直結)

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md)
- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](./empirical-reproduction-over-invariant-reasoning.md)
- [path セグメントの substring マッチが look-alike を誤マッチし対象を silent に over-remove する](../anti-patterns/path-segment-substring-over-match.md)

## ソース

- [PR #1238 review results](../../raw/reviews/20260601T185616Z-pr-1238.md)
- [PR #1238 review results (cycle 2)](../../raw/reviews/20260601T191319Z-pr-1238.md)
- [PR #1238 fix results](../../raw/fixes/20260601T190814Z-pr-1238.md)
