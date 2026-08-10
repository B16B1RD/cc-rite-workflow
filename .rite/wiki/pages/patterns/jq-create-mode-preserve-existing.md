---
title: "jq -n create mode: 既存値を読み取ってから再構築する"
domain: "patterns"
description: "`.rite-flow-state` のような state file を `jq -n` (null input) で毎回全フィールド再構築する設計は、後続の `create` 呼び出しで永続化すべきフィールド (`parent_issue_number`, `loop_count` 等) をリセットしてしまう CRITICAL 欠陥を持つ。"
promote: rite-plugin
created: "2026-04-16T19:37:16Z"
updated: "2026-07-09T19:44:33+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260416T122803Z-pr-545.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T122506Z-pr-545.md"
  - type: "reviews"
    ref: "raw/reviews/20260709T100928Z-pr-1812.md"
  - type: "reviews"
    ref: "raw/reviews/20260709T104501Z-pr-1812.md"
  - type: "fixes"
    ref: "raw/fixes/20260709T101456Z-pr-1812.md"
tags: ["jq", "state-file", "persistence", "flow-state"]
confidence: high
---

# jq -n create mode: 既存値を読み取ってから再構築する

## 概要

`.rite-flow-state` のような state file を `jq -n` (null input) で毎回全フィールド再構築する設計は、後続の `create` 呼び出しで永続化すべきフィールド (`parent_issue_number`, `loop_count` 等) をリセットしてしまう CRITICAL 欠陥を持つ。canonical pattern は「既存ファイルから読み取った値を `--arg`/`--argjson` で埋めてから `jq -n` に渡す」。

## 詳細

### CRITICAL Anti-pattern（実測で発覚）

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

### 型変換を伴う preserve フィールドは失敗経路が新規発生する

`worktree` / `cycle_count` / `last_synced_phase` 等の既存 preserve フィールドはいずれも文字列/整数の無変換書き戻しだったが、`wm_comment_id` を追加した際は唯一 `tonumber` による型変換を伴った。この構造的な違いが2つの新規指摘を生んだ:

1. **エラーメッセージの文脈不足**: `tonumber` 失敗時の jq ネイティブエラーは「どのフィールドが原因か」を示さない。preserve フィールドに型変換を追加する際は、失敗時に対象フィールド名を明示する WARNING を呼び出し側で用意する必要がある。
2. **診断出力の中和規約からの逸脱**: 型変換失敗時のエラーメッセージを jq の `error()` ビルトインで独自組み立てすると、そのメッセージは jq 自身の stderr 経由で出力される。同一ファイル内に既存の診断中和規約（例: `_emit_jq_err_snippet` 経由の `neutralize_ctrl`）がある場合、新規追加した失敗経路もそれを踏襲しないと、corrupt な入力値に含まれる制御バイト（ESC/CSI 等）が中和されずに operator 端末へ到達しうる（[Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の一種 — 新規追加コードが同一ファイル内の既存規約に追随しない failure mode）。

**教訓**: preserve whitelist に新フィールドを追加する際、既存フィールドと型が異なる（特に文字列以外への変換を伴う）場合は、その型変換の失敗経路がもたらす新しい failure surface（診断メッセージの生成方法・出力経路）を既存の同ファイル内規約と照合すること。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #545 fix (jq -n create mode リセット問題)](../../raw/fixes/20260416T122803Z-pr-545.md)
- [PR #545 review (CRITICAL: parent_issue_number 上書き検出)](../../raw/reviews/20260416T122506Z-pr-545.md)
- [PR #1812 review cycle 1 (wm_comment_id 追加、型変換フィールドの指摘)](../../raw/reviews/20260709T100928Z-pr-1812.md)
- [PR #1812 review cycle 3 (mergeable 到達)](../../raw/reviews/20260709T104501Z-pr-1812.md)
- [PR #1812 fix cycle 1 (エラーメッセージ文脈追加)](../../raw/fixes/20260709T101456Z-pr-1812.md)
