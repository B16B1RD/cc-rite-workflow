---
title: "Phase 番号は構造的対称性を保つ（孤立 sub-phase を生まない）"
domain: "heuristics"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260416T040604Z-pr-541.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T040322Z-pr-541.md"
tags: ["docs", "phase-numbering", "structural-integrity"]
confidence: medium
---

# Phase 番号は構造的対称性を保つ（孤立 sub-phase を生まない）

## 概要

命令書型の Markdown skill (`commands/pr/fix.md` など) で Phase 番号を付ける際、`### 8.0.1` のような sub-phase を追加したら親である `### 8.0` も必ず存在させる。親なし sub-phase は「構造的非対称性」として HIGH 指摘に繋がる。

## 詳細

### Anti-pattern: orphan sub-phase

```markdown
<!-- ❌ NG: ### 8.0 が存在せず ### 8.0.1 が孤立 -->
## Phase 8
### 8.0.1 Auto Re-review Check
...
```

LLM が Phase 8.0 を参照する Skill を辿るとき、親 section がないため navigation が壊れる。また prose で「Phase 8.0 に記述された契約」と書く箇所が stale になる。

### Canonical pattern

```markdown
<!-- ✅ OK: 親 section を明示 -->
## Phase 8
### 8.0 Post-cycle Check (overview)
（下記 sub-phase の overview）

### 8.0.1 Auto Re-review Check
...
```

### Cross-reference との相互作用

Phase 番号を書き換える際は以下を全 md で grep 追跡:

```bash
grep -rn "Phase 8.0" --include='*.md' plugins/rite/
grep -rn "Phase 8\.0\.1" --include='*.md' plugins/rite/
```

cross-file reference の drift は [Asymmetric Fix Transcription](anti-patterns/asymmetric-fix-transcription.md) の典型ケース。PR #548 cycle 3 では `cleanup.md Phase 2.6` が `init.md Phase 3.5.1` を `Phase 3.5` と誤記し、review で検出された。

### Enforcement note の事実正確性

Phase 番号と併せて「この sub-phase は stop-guard hook によって enforce される」のような enforcement note を書く際は、実際の hook 実装が sentinel や marker をチェックしているかを確認する。PR #541 では `stop-guard whitelist は sentinel をチェックしない` という実装事実に反する記述が HIGH で指摘された。doc と hook の drift を防ぐため:

1. Enforcement note は hook の実装名 (`stop-guard.sh` / `phase-transition-whitelist.sh`) を明示
2. hook のどの関数・どの check が enforce するかを参照リンクで書く
3. hook を変更したら注釈付き doc も grep で追跡

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #541 fix (### 8.0 欠落 + enforcement note 事実不正確)](raw/fixes/20260416T040604Z-pr-541.md)
- [PR #541 review (2 HIGH 指摘)](raw/reviews/20260416T040322Z-pr-541.md)
