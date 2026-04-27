---
title: "`2>&1` と `2>&1 | head -N` で sentinel/exit code が silent suppression される (self-defeating observability)"
domain: "anti-patterns"
created: "2026-04-27T23:01:24+00:00"
updated: "2026-04-27T23:01:24+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260427T033904Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T035029Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260427T151741Z-pr-688.md"
tags: ["bash", "stderr", "sentinel", "silent-failure", "observability", "pipefail"]
confidence: high
---

# `2>&1` と `2>&1 | head -N` で sentinel/exit code が silent suppression される (self-defeating observability)

## 概要

`2>&1` で stderr を stdout に merge する pattern は、(a) `2>&1 | head -N` 形式では pipeline 終端の `head` が前段の exit code を消す silent failure を生み、(b) helper の stderr 出力が caller 側で classification 文字列に混入し case arm が defensive `*)` 経路に落ちる silent sentinel suppression を生む。Issue #687 の core deliverable である `legacy_state_corrupt` / `cross_session_takeover_refused` workflow incident sentinel が、この `2>&1` で reader/writer 両方で silent suppress される **self-defeating** 構造として PR #688 cycle 35 で実測された。canonical fix は stderr を tempfile に退避して exit code と sentinel を分離 capture すること。

## 詳細

### 症状 (a): `2>&1 | head -N` exit code masking

cycle 7 で 3-reviewer 独立検出された cross-validated CRITICAL:

```bash
# anti-pattern: pipeline 終端 head -3 が exit code を支配
if ! bash flow-state-update.sh patch ... 2>&1 | head -3; then
  exit 1
fi
```

`set -o pipefail` 未設定の bash デフォルト評価では、pipeline の exit code は **終端コマンド (`head -3`) の exit 0** に支配される。前段の `bash ... patch` が exit 1 を返しても caller には silent。Issue #79 の resume-session variant の症状を別経路で再現。

### 症状 (b): `2>&1` sentinel suppression (PR #688 cycle 35 で実測 CRITICAL × 2)

```bash
# anti-pattern: helper stderr が classification 文字列に混入
classification=$(bash _resolve-cross-session-guard.sh ... 2>&1)
case "$classification" in
  corrupt:*)
    bash workflow-incident-emit.sh --type legacy_state_corrupt ...
    ;;
  *)
    # defensive fallback - silently swallows corrupt:* with stderr noise
    ;;
esac
```

helper が `stdout: classification token / stderr: 診断ログ` の混合 output を採用したため、`2>&1` で stderr 出力が classification 先頭に混入し `corrupt:*` arm にマッチしなくなる。`*)` arm に落ちて sentinel emit が完全 silent。

**self-defeating 構造**: 当該 PR は「silent failure を sentinel で観測可能化」を目的としていながら、その deliverable 自体が silent failure する。reader (`state-read.sh:119`) と writer (`flow-state-update.sh:149`) で対称バグとして発生。

### Root cause: helper output contract の曖昧性

`stdout: 機械可読 token / stderr: 人向け 診断` の混合 output は、caller が `2>&1` か `2>/dev/null` のどちらを選ぶかという contract 曖昧性を生む。両 caller (reader/writer) が同じ誤った選択 (`2>&1`) を独立に行う構造リスク。

### canonical fix

**(a) exit code masking 対策**: stderr を tempfile に退避してから head する。

```bash
err=$(mktemp /tmp/foo-err-XXXXXX) || err=""
trap '[ -n "$err" ] && rm -f "$err"; exit 0' EXIT INT TERM HUP

if ! bash flow-state-update.sh patch ... 2>"${err:-/dev/null}"; then
  rc=$?
  [ -n "$err" ] && head -3 "$err" >&2
  exit "$rc"
fi
```

**(b) sentinel suppression 対策**: stderr を完全分離して classification capture から除外する。

```bash
err=$(mktemp /tmp/guard-err-XXXXXX) || err=""
classification=$(bash _resolve-cross-session-guard.sh ... 2>"${err:-/dev/null}")
rc=$?

# 診断 stderr は別途 surface (success path でも sentinel を含む可能性があるため)
if [ -n "$err" ] && [ -s "$err" ]; then
  cat "$err" >&2
fi

case "$classification" in
  corrupt:*)
    bash workflow-incident-emit.sh --type legacy_state_corrupt ...
    ;;
  ...
esac
```

### 周辺対策

- `set -o pipefail` を helper script 冒頭に明示 (デフォルト挙動だけに頼らない)。
- helper の output contract を docstring で明示: `stdout: classification token (machine-parseable)` / `stderr: 診断ログ (operator-readable)` を分離宣言。
- caller test で sentinel emit と exit code の **両方** を assert (どちらか片方の assert だけでは silent 化を catch しない)。
- mutation testing で `2>&1` と `2>"$err"` を sed 置換して TC が FAIL するか empirical 検証。

### 検出パターン

- 6 reviewer (code-quality / error-handling / test / prompt-engineer / tech-writer / security) が CRITICAL × 2 として独立検出。
- `corrupt:*` 分類経路の TC が新規 4 test file (1470 行) のいずれにも不在 → coverage gap が cycle 28-34 の review-fix loop で構造的盲点として残存。

## 関連ページ

- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)
- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #688 cycle 7 review results (`2>&1 | head -N` masking)](raw/reviews/20260427T033904Z-pr-688.md)
- [PR #688 cycle 8 fix results (canonical tempfile pattern)](raw/fixes/20260427T035029Z-pr-688.md)
- [PR #688 review results (cycle 35 — `2>&1` sentinel suppression CRITICAL × 2)](raw/reviews/20260427T151741Z-pr-688.md)
