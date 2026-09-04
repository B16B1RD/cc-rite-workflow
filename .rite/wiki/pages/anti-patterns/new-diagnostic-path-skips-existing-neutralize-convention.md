---
type: "anti-patterns"
title: "新規診断出力の追加は同一ファイル内の既存 control-char 中和規約を踏襲する"
domain: "anti-patterns"
promote: rite-plugin
description: "state ファイル等の corrupt/改竄された値を診断メッセージに含める際、同一ファイル内の既存の読み取り経路（READ）が `neutralize_ctrl` 等の制御文字中和ヘルパー経由で stderr emit する規約を確立している場合、新規に追加した書き込み経路（WRITE）のエラーハンドリングもこの規約を踏襲しないと、ESC/CSI 等の制御バイトが未中和のまま operator 端末へ到達しうる。"
created: "2026-07-09T19:44:33+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260709T102352Z-pr-1812.md"
  - type: "fixes"
    resource: "raw/fixes/20260709T103432Z-pr-1812.md"
  - type: "reviews"
    resource: "raw/reviews/20260807T133323Z-pr-2137.md"
tags: ["control-char", "neutralize", "stderr", "security", "jq"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-07T23:45:00+09:00" }
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

### 変種: 拒否経路の診断が、拒否した当の入力によって成立する（cycle 1 実測）

最も漏れやすい診断出力は「入力検証を通らなかった値」を引用するものである。**検証を通らなかった値こそが壊れた値**であり、それを無加工で引用する診断は、検証と同じ強度で守らないと拒否経路そのものが攻撃面になる。

`hooks/scripts/lib/context-marker.sh` の `marker_emit` は、改行を含む KEY を契約違反として rc 1 で拒否する。しかし ERROR 文がその KEY を無加工でエコーしたため、**拒否した出力の中に列 0 の `[CONTEXT]` 行が現れた**。marker の消費者は列 0 の `[CONTEXT] ` 行だけを marker 候補として読む規約なので（[LLM が読む出力ストリームで marker を契約にするには prefix・行頭・デリミタ・識別子スコープの 4 条件すべてが要る](../patterns/llm-read-marker-contract-four-conditions.md)）、拒否経路が当の偽 marker を成立させたことになる。

同リポジトリの `review-save-json-verify.sh` は同一の失敗を明記したうえで `_scrub()` を持っており、**その定義位置は検査ブロックより前**である。定義が検査ブロックより後だと拒否経路を覆えないため、位置そのものが load-bearing になる。新規 lib はこの先例から漏れていた（[テンプレート流用の新規スクリプトは最新兄弟の防御を継承する](../heuristics/new-script-inherits-latest-sibling-defenses.md) と同時発生）。

**確認手順**: 入力検証を持つ helper を書いたら、拒否経路の ERROR 文が引用する値を列挙し、それぞれが中和/サニタイズ関数を通っているかを見る。通っていない場合、その値で「検証が拒否したはずの構造」を出力側に組み立てられないかを実測する（改行 + プロトコル prefix の注入が最頻）。

なお同じ事例では実装 5 箇所すべてに `_marker_scrub` を適用したにもかかわらず、テストが pin したのは 2 箇所だけで、残り 3 箇所は scrub を外しても suite が green のまま生存した — 修正の網羅と pin の網羅は別の数字である（[Test pin protection theater](./test-pin-protection-theater.md)）。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [LLM が読む出力ストリームで marker を契約にするには prefix・行頭・デリミタ・識別子スコープの 4 条件すべてが要る](../patterns/llm-read-marker-contract-four-conditions.md)
- [jq -n create mode: 既存値を読み取ってから再構築する](../patterns/jq-create-mode-preserve-existing.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [MEDIUM: 未中和 error() 検出](../../raw/reviews/20260709T102352Z-pr-1812.md)
- [中和経路への統一](../../raw/fixes/20260709T103432Z-pr-1812.md)
- [拒否経路の ERROR 文が未検証値を無加工でエコーし列 0 の偽 marker を成立させる](../../raw/reviews/20260807T133323Z-pr-2137.md)
