---
title: "Archive doc の front-matter で宣言した preservation policy を body 編集が無視して矛盾を生む"
domain: "anti-patterns"
description: "`status: structurally_resolved` の anti-pattern doc / design doc で front-matter に「本文中の `Phase` 番号は PR #XXXX 以前の旧構造の歴史的記述として保持」と明示宣言されているにも関わらず、rename PR の機械的置換 fix が body の Phase 参照を `ステップ` に書き換え、**front-matter declaration と body の矛盾** を発生させる anti-pattern。"
promote: rite-plugin
created: "2026-05-27T01:30:00Z"
updated: "2026-05-27T01:30:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260526T153732Z-pr-1151.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T155823Z-pr-1151.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T154013Z-pr-1151.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T160217Z-pr-1151.md"
tags: ["archive-doc", "frontmatter-policy", "historical-preservation", "rename-pr", "reviewer-classification-disagreement"]
confidence: high
---

# Archive doc の front-matter で宣言した preservation policy を body 編集が無視して矛盾を生む

## 概要

`status: structurally_resolved` の anti-pattern doc / design doc で front-matter に「本文中の `Phase` 番号は PR #XXXX 以前の旧構造の歴史的記述として保持」と明示宣言されているにも関わらず、rename PR の機械的置換 fix が body の Phase 参照を `ステップ` に書き換え、**front-matter declaration と body の矛盾** を発生させる anti-pattern。reviewer 間でも document classification (archive vs current) の認識が共有されていないと、cycle N で fix された箇所が cycle N+1 で revert される往復が発生する。

## 詳細

### 発生条件

1. **archive doc に preservation policy が front-matter で declare されている**

   ```yaml
   ---
   status: structurally_resolved
   note: "本文中の Phase 番号は PR #1149 以前の旧構造の歴史的記述として保持"
   ---
   ```

2. **rename PR の fix が同 doc の body を機械的に置換する** (front-matter を read しない / read しても無視する)

3. **reviewer が「stale ref」と誤判定して fix を要求する**

4. **次 cycle で別の reviewer (or 同じ reviewer の再評価) が front-matter declaration を発見して revert を要求する**

結果: cycle 1 で fix → cycle 2 で revert → cycle 3 で revert 漏れの tail residue 発覚、という往復が発生する。

### 大規模 rename 事例での実測

`docs/anti-patterns/cleanup-wiki-ingest-turn-boundary.md` (front-matter L14-18 で archive policy 宣言) で以下の経過:

- **cycle 1**: 8 箇所中 L23 1 件のみ rename、残り 7 件 `Phase 9.x` のまま (F-14 として tech-writer reviewer が「fix-required」と指摘) → fix で全 8 件を `ステップ` に over-translate
- **cycle 2**: prompt-engineer reviewer が front-matter declaration vs body の矛盾を再発見 (F-21) → fix で 6 箇所を `Phase` に revert
- **cycle 3**: cycle 2 で revert 漏れの 2 箇所 (L26 `wiki/lint.md ステップ 9.2`, L35 `ingest.md ... ステップ 8`) を最終 revert (HIGH 級 finding として再発覚)
- **cycle 4**: 0 findings (mergeable)

L35 の `ステップ 8` は同 doc L114 の `Phase 8` と intra-document contradiction を形成していた。

### 構造的原因

1. **LLM は機械的に文字列を置換する**: front-matter declaration を read しても、body の置換時にそれを参照しない
2. **Reviewer 間で archive policy の認識が共有されていない**: tech-writer は「stale ref」と判定、prompt-engineer は「historical preservation」と判定、cycle ごとに見解が割れる
3. **archive doc の判定が「structurally_resolved status」だけでは不十分**: body 編集時に LLM が status を参照する手順が確立されていない

### Detection Heuristic / 対策

1. **archive doc の front-matter で preservation policy を明示宣言する**（現 anti-pattern doc が既に採用）

   ```yaml
   ---
   status: structurally_resolved
   preserve_terminology: ["Phase", "本 Phase", "Phase N"]
   note: "本文中の Phase 番号は PR #XXXX 以前の旧構造の歴史的記述として保持。
          rename PR の対象から除外。"
   ---
   ```

2. **rename PR の対象から自動除外する仕組み**: `status: structurally_resolved` のファイルは AC grep / find から除外するスクリプトを CI に組み込む

3. **intra-document consistency check**: archive doc 内の `(Phase|ステップ) [0-9]` パターンを同 doc 内の他 historical reference との表記対称性で audit する (外部参照 drift より検出しやすい)

4. **cycle N で同 file 内に 5+ の同 policy violation がある場合、cycle N+1 で同 file の全 archive reference を一括 grep + audit する pre-fix scan を導入する** (3 cycle 通しても 1-2 件単位で残り続ける tail-end pattern を防ぐ)

5. **Reviewer 間で document classification (archive vs current) を共有する**: SKILL.md / reviewer briefing に「archive doc 一覧」セクションを追加し、reviewer がレビュー前に classification を確認できるようにする

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [AC 検証 grep を狭い正規表現で定義すると bare prose / 表ヘッダ / 副詞句が捕捉できない](./ac-grep-narrow-pattern.md)
- [Rename PR の callee → caller 片方向 over-translation で Out-of-Scope の broken cross-ref を生成する](./rename-pr-callee-caller-over-translation.md)

## ソース

- [PR #1151 review cycle 2 (3 findings, F-21)](../../raw/reviews/20260526T153732Z-pr-1151.md)
- [PR #1151 review cycle 3 (2 tail residue)](../../raw/reviews/20260526T155823Z-pr-1151.md)
- [PR #1151 fix cycle 2 (F-21 revert)](../../raw/fixes/20260526T154013Z-pr-1151.md)
- [PR #1151 fix cycle 3 (tail residue fix)](../../raw/fixes/20260526T160217Z-pr-1151.md)
