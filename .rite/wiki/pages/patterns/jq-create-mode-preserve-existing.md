---
title: "jq -n create mode: 既存値を読み取ってから再構築する"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260416T122803Z-pr-545.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T122506Z-pr-545.md"
tags: ["jq", "state-file", "persistence", "flow-state"]
confidence: high
---

# jq -n create mode: 既存値を読み取ってから再構築する

## 概要

`.rite-flow-state` のような state file を `jq -n` (null input) で毎回全フィールド再構築する設計は、後続の `create` 呼び出しで永続化すべきフィールド (`parent_issue_number`, `loop_count` 等) をリセットしてしまう CRITICAL 欠陥を持つ。canonical pattern は「既存ファイルから読み取った値を `--arg`/`--argjson` で埋めてから `jq -n` に渡す」。

## 詳細

### CRITICAL Anti-pattern (PR #545 で発覚)

```bash
# ❌ NG: create mode が既存値を毎回リセット
jq -n \
  --arg phase "$PHASE" \
  --arg branch "$BRANCH" \
  '{
    active: true,
    phase: $phase,
    branch: $branch,
    parent_issue_number: 0,   # 既存値を無視してリセット
    loop_count: 0             # 既存値を無視してリセット
  }' > .rite-flow-state
```

Phase 1.5 Parent Routing が `.rite-flow-state` に `parent_issue_number=42` を書いた後、Phase 2.3 Branch Setup の `create` 呼び出しが再度 `parent_issue_number=0` に上書きし、Phase 5.7 での Parent Completion 判定が silent に失敗する。

### Canonical pattern: 既存値を先読み

```bash
# ✅ OK: 既存ファイルから保持すべき値を読み取る
EXISTING_STATE=".rite-flow-state"
PREV_PHASE=""
PREV_PARENT_ISSUE=0

if [ -f "$EXISTING_STATE" ]; then
  PREV_PHASE=$(jq -r '.phase // ""' "$EXISTING_STATE")
  PREV_PARENT_ISSUE=$(jq -r '.parent_issue_number // 0' "$EXISTING_STATE")
fi

jq -n \
  --arg phase "$NEW_PHASE" \
  --arg prev_phase "$PREV_PHASE" \
  --argjson parent "${PREV_PARENT_ISSUE:-0}" \
  '{
    active: true,
    phase: $phase,
    previous_phase: $prev_phase,
    parent_issue_number: $parent
  }' > "$EXISTING_STATE"
```

### 影響範囲

以下のフィールドは「一度書かれたら後続の create で保持すべき」:

| フィールド | 初期値 source | 上書きされる害 |
|-----------|--------------|--------------|
| `parent_issue_number` | Phase 1.5 Parent Routing | Phase 5.7 Parent Completion が silent failure |
| `loop_count` | Phase 5.4 review-fix loop | 無限ループ化 / メトリクス不正 |
| `pr_number` | Phase 5.3 PR Creation | Phase 5.4 以降の Skill が PR を見失う |
| `session_id` | 初回 create | resume 時に session tracking が断絶 |

### `flow-state-update.sh` での実装

`create` と `patch` の 2 モードを分離した上で、`create` も「既存があればマージ」方針とする:

```bash
# create mode でも既存フィールドを preserve
if [ -f "$STATE_FILE" ]; then
  # patch 相当にフォールバック
  MODE=patch
fi
```

### Detection

jq `-n` を使う state 更新箇所を網羅的に確認:

```bash
grep -rnE 'jq -n' --include='*.sh' --include='*.md' .
```

その上で「既存ファイル読み取り → `--arg`/`--argjson` で値を渡す」パターンが揃っているかを人手確認する。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #545 fix (jq -n create mode リセット問題)](raw/fixes/20260416T122803Z-pr-545.md)
- [PR #545 review (CRITICAL: parent_issue_number 上書き検出)](raw/reviews/20260416T122506Z-pr-545.md)
