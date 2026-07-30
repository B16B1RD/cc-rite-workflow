---
type: "anti-patterns"
title: "新規診断出力の追加は同一ファイル内の既存 control-char 中和規約を踏襲する"
domain: "anti-patterns"
description: "既存の診断出力（stderr）が制御文字中和ヘルパー経由で emit される規約を持つファイルに、新規のエラー出力経路を追加すると、その規約を見落として生の制御バイトを stderr へ漏らしうる。"
created: "2026-07-09T19:44:33+09:00"
updated: "2026-07-09T19:44:33+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260709T102352Z-pr-1812.md"
  - type: "fixes"
    ref: "raw/fixes/20260709T103432Z-pr-1812.md"
tags: ["control-char", "neutralize", "stderr", "security", "jq"]
confidence: high
---

# 新規診断出力の追加は同一ファイル内の既存 control-char 中和規約を踏襲する

## 概要

state ファイル等の corrupt/改竄された値を診断メッセージに含める際、同一ファイル内の既存の読み取り経路（READ）が `neutralize_ctrl` 等の制御文字中和ヘルパー経由で stderr emit する規約を確立している場合、新規に追加した書き込み経路（WRITE）のエラーハンドリングもこの規約を踏襲しないと、ESC/CSI 等の制御バイトが未中和のまま operator 端末へ到達しうる。

## 詳細

### 発生条件（cycle 1→2 で実測）

`flow-state.sh` の `cmd_set()` は既に READ 側で `_cur_jq_err`（mktemp によるstderr 捕捉）→ `_emit_jq_err_snippet()` → `neutralize_ctrl --keep-newline` という中和経路を持っていた。cycle 1 で `wm_comment_id` フィールドの `tonumber` 失敗時にエラーメッセージへフィールド名を含める改善を行った際、jq の `error(...)` ビルトインで独自メッセージを組み立てた:

```jq
# ❌ NG: error() が corrupt な値をそのまま jq 自身の stderr へ送出。
# この stderr は捕捉されず、中和ヘルパーを一切経由しない。
(if $wmcid != "" then
  .wm_comment_id = (try ($wmcid | tonumber) catch error("wm_comment_id not numeric (value=" + $wmcid + "): " + .))
else . end)
```

このパターンでは、`wm_comment_id` に ESC/CSI 制御バイトが混入していた場合、`error()` が生成するエラー文字列にその生バイトが含まれたまま jq の stderr に出力される。呼び出し側 (`new=$(jq -n ... )`) はこの jq 呼び出しの stderr を一切捕捉していなかったため（`|| return 1` のみ）、生バイトが直接ターミナルへ到達しうる。

### Canonical pattern: WRITE 側も同一ヘルパー経路に統一する

```bash
# ✅ OK: WRITE 側も READ 側と対称に mktemp + _emit_jq_err_snippet を使う
local _new_jq_err="" _new_rc=0
_new_jq_err=$(mktemp 2>/dev/null) || _new_jq_err=""
new=$(jq -n \
  --arg wmcid "$cur_wm_comment_id" \
  '... | (if $wmcid != "" then .wm_comment_id = ($wmcid | tonumber) else . end)' \
  2>"${_new_jq_err:-/dev/null}") || _new_rc=$?
if [ "$_new_rc" -ne 0 ]; then
  echo "WARNING: state write failed (wm_comment_id not numeric, or other jq failure)" >&2
  _emit_jq_err_snippet "$_new_jq_err"   # neutralize_ctrl 経由で中和済みスニペットを emit
  [ -n "$_new_jq_err" ] && rm -f "$_new_jq_err"
  return 1
fi
[ -n "$_new_jq_err" ] && rm -f "$_new_jq_err"
```

ポイントは custom `error(...)` を撤去し、`tonumber` の素の失敗を stderr にキャプチャしてから中和ヘルパーへ渡すこと。「フィールド名の文脈を示す」という当初の目的は、jq エラーメッセージとは独立した shell 側の固定 WARNING 文字列で達成し、値そのものは中和済みスニペット経由でのみ表示する。

### Detection

同一ファイル内で新規に stderr 出力（`jq ... error(...)` や直接 `echo ... >&2` に corrupt 由来の値を含める）を追加する際は、まず同ファイル内の既存診断出力（`grep -n '_emit_jq_err_snippet\|neutralize_ctrl' <file>`）の有無を確認し、既存の中和ヘルパーがあれば必ずそれを経由させる。中和ヘルパー自体の実装は `control-char-neutralize.sh` の `neutralize_ctrl` / `contains_ctrl` を参照。

回帰テストは corrupt な値に ESC バイトを混入させ、実際の stderr 出力に生の `0x1b` が残らないことを `od -c` や `LC_ALL=C grep` で検証する（`cat -v` のみでは中和済みかどうか判別しづらい場合があるため、バイト単位の検証を推奨）。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [jq -n create mode: 既存値を読み取ってから再構築する](../patterns/jq-create-mode-preserve-existing.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [PR #1812 review cycle 2 (MEDIUM: 未中和 error() 検出)](../../raw/reviews/20260709T102352Z-pr-1812.md)
- [PR #1812 fix cycle 2 (中和経路への統一)](../../raw/fixes/20260709T103432Z-pr-1812.md)
