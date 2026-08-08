---
title: "resolver / helper 失敗時の silent fallback は debug log で観測性を確保する"
domain: "patterns"
promote: rite-plugin
created: "2026-04-30T08:03:08Z"
updated: "2026-07-09T06:56:16+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260430T074655Z-pr-750-cycle-1.md"
  - type: "reviews"
    ref: "raw/reviews/20260430T074221Z-pr-750.md"
  - type: "reviews"
    ref: "raw/reviews/20260709T055242Z-pr-1808.md"
  - type: "fixes"
    ref: "raw/fixes/20260709T055810Z-pr-1808.md"
tags: [observability, silent-failure, debug-log, defense-in-depth]
confidence: high
---

# resolver / helper 失敗時の silent fallback は debug log で観測性を確保する

## 概要

`var=$(helper.sh ... 2>/dev/null) || var="<legacy_default>"` 形式で resolver / helper 失敗時に legacy 値へ fallback する pattern は、stderr が捨てられているため deploy regression / migration drift / permission denied 等の根本原因が完全に silent になる。`RITE_DEBUG=1` 環境変数で gate した `.rite-flow-debug.log` への WARNING 出力を caller 側に対称配置することで、silent fallback の本番再現性を維持しつつ root cause を後追い可能にする。

## 詳細

### 問題の構造

```bash
# Anti-pattern: silent legacy fallback
STATE_FILE_PATH=$(bash "$_resolve-flow-state-path.sh" 2>/dev/null) \
  || STATE_FILE_PATH=".rite-flow-state"  # legacy fallback
```

このコードは以下の障害経路を全て silent に握り潰す:

- resolver script の deploy 失敗 (path 不在 / permission)
- migration 中の transient state (per-session file への書き換え途中)
- per-session file 構造の前提が壊れた場合 (sessions/ ディレクトリの permission denied 等)

caller (pre-tool-bash-guard.sh / post-tool-wm-sync.sh / session-ownership.sh) が同じ pattern を 5 site で複製していると、5 ヵ所すべてで同時 silent failure が起きうるが debug 手段がない。

### Canonical fix: RITE_DEBUG gated WARNING

```bash
# Canonical: silent fallback + RITE_DEBUG observability
if STATE_FILE_PATH=$(bash "$_resolve-flow-state-path.sh" 2>/tmp/resolve_err); then
  :  # success path
else
  rc=$?
  STATE_FILE_PATH=".rite-flow-state"  # legacy fallback (本番挙動は不変)
  if [ "${RITE_DEBUG:-}" = "1" ]; then
    {
      echo "[$(date -Iseconds)] WARNING: _resolve-flow-state-path.sh failed (rc=$rc), falling back to legacy"
      head -5 /tmp/resolve_err 2>/dev/null
    } >> "${RITE_FLOW_DEBUG_LOG:-.rite-flow-debug.log}"
  fi
  rm -f /tmp/resolve_err
fi
```

設計ポイント:

1. **本番挙動を不変に保つ**: legacy fallback への遷移は維持し、observability layer のみ追加する。これにより既存 caller の break risk なしで観測性を獲得できる
2. **RITE_DEBUG gate で常時 enable しない**: 本番運用での log file 肥大化を防ぐ。デバッグ時のみ `RITE_DEBUG=1` で発火させる
3. **caller 全件への対称適用 (Wiki: Asymmetric Fix Transcription)**: 1 caller のみに追加すると、別 caller の silent failure が発見できない。同 pattern を持つ全 caller（実測例では pre-tool-bash-guard.sh / post-tool-wm-sync.sh の 2 site）に対称適用する

### 常時 WARNING 事例: fallback が解決先を変える場合は RITE_DEBUG gate せず常時 WARNING にする

`cleanup-work-memory.sh` の `FLOW_STATE` 解決も同型の resolver 呼び出し失敗パターンだったが、本 PR の fix は上記 canonical fix の `RITE_DEBUG` gate を外し、WARNING を常時 stderr に出力する形を採った:

```bash
if RESOLVED_FLOW_STATE=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" path 2>"${_fs_err:-/dev/null}"); then
  :
else
  echo "WARNING: cleanup-work-memory: flow-state.sh path resolution failed — falling back to legacy $(basename "$STATE_ROOT/.rite-flow-state") (session_id may be missing or invalid)" >&2
  RESOLVED_FLOW_STATE=""
fi
```

判断基準: この実測ケースは fallback 後も**本番挙動が不変**（同じ実質的な state 解決結果に収束）なため、observability を `RITE_DEBUG` gate で opt-in にしても実害がなかった。一方この事例では fallback が **実際に別ファイル**（schema_v2/v3 の per-session file → legacy 共有 file）を操作対象に切り替える — silent だと `/rite:cleanup` が「成功したように見えて実際には別ファイルをリセットした」という schema 不整合を誰にも気づかれず再生産する（実害として観測済み）。**fallback が操作対象そのものを変える場合は、opt-in の debug ログではなく常時可視の WARNING にする**（gate の要否は「fallback後も対象不変か、対象自体が変わるか」で判定する）。

### 上位 Pattern との関係

- `mktemp-failure-surface-warning.md` は mktemp 単体の silent 握り潰しを WARNING + `[CONTEXT]` sentinel で可視化する pattern。本 pattern はそれを「resolver / helper 経由の silent fallback」へ一般化したもの
- `stderr-merge-silent-sentinel-suppression.md` は `2>&1 | head` で sentinel が消える self-defeating observability の anti-pattern。本 pattern は「stderr を tempfile に退避 + RITE_DEBUG gated emit」で対称的に解決する

## 関連ページ

- [バグ修正PRが新設したエラーパス自身にも回帰テストを追加する](./bugfix-new-error-path-needs-regression-test.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)
- [`2>&1` と `2>&1 | head -N` で sentinel/exit code が silent suppression される (self-defeating observability)](../anti-patterns/stderr-merge-silent-sentinel-suppression.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [PR #750 fix cycle 1 results](../../raw/fixes/20260430T074655Z-pr-750-cycle-1.md)
- [PR #750 review results](../../raw/reviews/20260430T074221Z-pr-750.md)
