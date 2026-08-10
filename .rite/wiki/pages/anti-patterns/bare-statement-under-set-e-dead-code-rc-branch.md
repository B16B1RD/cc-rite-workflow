---
title: "set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する"
domain: "anti-patterns"
description: "`set -euo pipefail` 下で外部コマンド (python3/jq/grep 等) を単独文 (bare statement) として実行すると非ゼロ終了で set -e が script を abort し、直後の `rc=$?` 以降の rc 分岐 (rc=1 no-op / rc=2 corruption 報告) が dead code 化する。`if cmd; then rc=0; else rc=$?; fi` の set -e 免除文脈へ移すのが canonical。`if ! cmd; then rc=$?` 版 (rc 常時 0、到達するが誤値) とは root cause の異なる別の壊れ方 (到達不能)。Asymmetric Fix Transcription の inline→delegate guard 解体 sub-pattern の逆方向 (修復) 適用例。過去のレビューで 4 reviewer 0 findings、関連する課題 subtask4 で他 hook 横断調査し session-start.sh:188 が唯一の該当と確認。過去のレビューで command-substitution 代入 `out=$(...); rc=$?` も同じ set -e abort で dead code 化する変種を追加 (test harness は `set +e`/`set -e` 囲みが canonical)。"
promote: rite-plugin
created: "2026-06-02T04:59:29Z"
updated: "2026-06-08T13:10:25Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260602T045929Z-pr-1242.md"
  - type: "reviews"
    ref: "raw/reviews/20260608T112156Z-pr-1306.md"
  - type: "fixes"
    ref: "raw/fixes/20260608T112705Z-pr-1306.md"
tags: ["bash", "rc-capture", "set-e", "silent-failure", "dead-code"]
confidence: high
---

# set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する

## 概要

`set -euo pipefail` 下で外部コマンド (`python3` / `jq` / `grep` 等) を **単独文 (bare statement)** として実行すると、コマンドが非ゼロ終了した瞬間に `set -e` が script 全体を abort する。その結果、直後の `rc=$?` capture と、それを参照する rc 分岐 (rc=1 no-op 処理 / rc=2 corruption 報告 等) が **dead code 化** し、「失敗時に diagnostics を surface する」という設計意図が実際には一度も実行されない。`if cmd; then rc=0; else rc=$?; fi` のような **set -e 免除文脈** へコマンドを移すのが canonical。

## 詳細

### 実証

```bash
# ❌ NG: bare statement は set -e で abort し rc=$? に到達しない
set -euo pipefail
python3 some-script.py < input > output 2>err   # rc != 0 でここで abort
_py_rc=$?                                        # 未到達 (dead code)
if [ "$_py_rc" -eq 0 ]; then ...                 # rc=0 のみ到達
else
  # rc=1 no-op / rc=2 corruption の報告分岐 — set -e abort により永久に未実行
fi
```

`if [ -n "$tmp" ]; then ... fi` のような **外側の if は python3 の exit status を消費しない** (到達ガードにすぎない) ため、bare statement は set -e の免除を受けられない。`&&` / `||` / `if cmd; then` のいずれの set -e 免除文脈にも置かれていないことが発火条件。

### 影響

実測では `session-start.sh` の settings.local.json 修復経路でこの構造が発生していた。rc=2 (不正 JSON) / rc=1 (no-op) で abort すると、下流の marker 書き込み・flow-state migrate・STATE_FILE 解決・recovery 注入が **すべて skip** される。PR が主張する「不正 JSON 時に corruption を surface する」報告分岐は、dead code のため実際には一度も実行されていなかった。

### Canonical Fix

```bash
# ✅ OK: if 条件 (set -e 免除文脈) で rc を捕捉する
set -euo pipefail
if python3 some-script.py < input > output 2>err; then
  _py_rc=0
else
  _py_rc=$?       # 非ゼロ exit がここで正しく捕捉される
fi
case "$_py_rc" in  # rc=0 / rc=1 / rc=2 / other すべて到達可能
  ...
esac
```

`set +e; cmd; rc=$?; set -e; case` 形式も等価な代替 (一時的に errexit を無効化する)。どちらを採るかは周辺コードの慣用と一致させる。

### `if ! cmd; then rc=$?` 版との区別

本 anti-pattern は姉妹 anti-pattern [`if ! cmd; then rc=$?` は常に 0 を捕捉する] と **root cause が異なる**:

| failure mode | 原因 | 症状 |
|--------------|------|------|
| bare statement (本ページ) | `set -e` が非ゼロ exit で abort | `rc=$?` 以降が **dead code** (未到達) |
| `if ! cmd` (姉妹ページ) | `!` 演算子が exit status を boolean 反転 | `rc=$?` が **常に 0** (到達するが値が誤り) |

両者とも「`set -euo pipefail` 下で外部コマンドの実 rc を安全に捕捉する」ファミリに属するが、前者は到達不能、後者は誤値という別の壊れ方をする。canonical fix の `if cmd; then rc=0; else rc=$?; fi` は **`!` を付けない** 点が重要 (`!` を付けると姉妹 anti-pattern を踏む)。

### 変種: command-substitution 代入 `out=$(...); rc=$?` も同じ dead code を生む

bare statement だけでなく、**command-substitution を含む代入** も `set -e` 下で同じ failure mode を起こす。`out=$(cmd); rc=$?` で `cmd` が非ゼロ終了すると、代入文の exit status が非ゼロになり `set -e` がその行で abort する。直後の `rc=$?` と rc 分岐 (明示 failure 分岐) は dead code 化し、failure attribution が破壊される (silent pass ではなく harness abort)。

起点事例の test T-6 で `out=$(...); rc=$?` が `set -euo pipefail` 下にあり、被テストスクリプトが回帰 (exit 2) した瞬間に代入行で harness が abort → 明示 FAIL 分岐に到達できず failure attribution が壊れていた (test reviewer の MEDIUM)。fix は `set +e; out=$(...); rc=$?; set -e` で囲む canonical pattern。exit 2 を返す broken script を注入する mutation test で FAIL 分岐到達を確認した。

bare statement 版 (上記) と root cause は同一 (`set -e` の非ゼロ abort) で、`if cmd; then rc=0; else rc=$?; fi` と `set +e; ...; rc=$?; set -e` のどちらの set -e 免除文脈に置くかは周辺コードの慣用と一致させる。test harness では `set +e`/`set -e` 囲みが慣用 (上位 if 条件にすると test の意図する rc 比較が読みにくくなるため)。

### Asymmetric Fix Transcription との関係

本バグは先行 PR の **inline → delegate refactor** (RITE_HOOK_RE を python script へ委譲) の際に、`&&` 条件形式から外部コマンド呼び出しを単独文へ移動したことで guard が解体された pre-existing latent bug だった (revert test 不成立で別 Issue 化)。これは [Asymmetric Fix Transcription (対称位置への伝播漏れ)] の「inline → delegate refactor 時の wrapper guard 解体」sub-pattern の実例であり、本ページの事例はその **逆方向 (修復) の適用例**。

### Detection Heuristic

`set -euo pipefail` を持つ script で「外部コマンド単独文の直後に `rc=$?` (または `_rc=$?`) があり、その rc を参照する分岐が続く」箇所を横断 grep する:

```bash
grep -nE '^\s*(python3|jq|grep|awk|sed|[a-zA-Z0-9_./-]+)\s+.*$' --include='*.sh' -r . | ...
# より実用的には: 各 hook で `rc=$?` の直前行が if 条件 / && / || で囲まれているかを目視確認
```

後続の subtask では他 hook (post-compact.sh / pre-tool-bash-guard.sh 等) を横断調査し、`session-start.sh:188` が唯一の該当箇所 (他は if/else・set +e 等で安全) と確認した。inline → delegate 委譲リファクタを行う PR では、委譲先コマンドが set -e 免除文脈に置かれているかを必ず verify すること。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](./bash-if-bang-rc-capture.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #1242 review results](../../raw/reviews/20260602T045929Z-pr-1242.md)
- [PR #1306 review cycle 1 (T-6 の `out=$(...); rc=$?` が set-e 下で failure attribution 破壊)](../../raw/reviews/20260608T112156Z-pr-1306.md)
- [PR #1306 fix cycle 1 (`set +e; out=$(...); rc=$?; set -e` 囲み + mutation test 確認)](../../raw/fixes/20260608T112705Z-pr-1306.md)
