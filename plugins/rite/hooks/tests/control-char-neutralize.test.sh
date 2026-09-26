#!/bin/bash
# Tests for plugins/rite/hooks/control-char-neutralize.sh
#
# Purpose:
#   neutralize_ctrl は flow-state.sh (_emit_jq_err_snippet) と
#   stop-loop-continuation.sh (unknown-prefix WARNING) が共有する
#   「制御文字 → ?」規約の single source of truth。glibc の [[:cntrl:]] が
#   分類しない C1 8-bit 制御バイト (0x80-0x9f、特に CSI introducer 0x9b) を
#   バイト単位で `?` 置換することを直接 pin する (jq / state file を介さない
#   単体層 — 統合層は flow-state.test.sh TC-23 / stop-loop-continuation.test.sh
#   TC-14 が担う)。--keep-newline だけは整形式 UTF-8 列の継続バイトを残す
#   (TC-22 / TC-23)。
#
# Test cases:
#   TC-1: C0 制御文字 (0x01 / TAB / ESC) → ?
#   TC-2: DEL (0x7f) → ?
#   TC-3: C1 境界 (0x80 / 0x9b CSI / 0x9f) → ? (本丸 pin)
#   TC-4: 0xa0 (C1 上限 +1) は保持される (過剰置換しない上側境界 pin)
#   TC-5: UTF-8 U+009B (0xc2 0x9b) の 0x9b バイトが ? 化され生 0x9b が残らない
#   TC-6: default モード: \n も ? 化 (旧 ${var//[[:cntrl:]]/?} の 1 行化挙動と同じ)
#   TC-7: --keep-newline: \n は保持、ASCII の後の制御文字 (C0 / 単独 C1) は ?
#   TC-8: 可読 ASCII は無傷 + 1:1 置換 (削除ではない — 長さ保存)
#   TC-9: NUL バイト (0x00) → ? (LC_ALL=C tr のバイトストリーム性 pin)
#   TC-10: --c0-only: C0 (0x01 / TAB / ESC) + DEL → ?
#   TC-11: --c0-only: C1 境界 (0x80 / 0x9b / 0x9f) は素通し (default との差分 pin)
#   TC-12: --c0-only: UTF-8 マルチバイト (日本語) が無傷 (JSON フォールバック reason 保護の本丸 pin)
#   TC-13: --c0-only: \n も ? 化 (C0 範囲 — caller は改行を先にエスケープしてから呼ぶ契約)
#   TC-14: contains_ctrl: C0 (0x01 / TAB / \n / ESC) を検出
#   TC-15: contains_ctrl: DEL (0x7f) を検出
#   TC-16: contains_ctrl: C1 境界 (0x80 / 0x9b CSI / 0x9f) を検出 (本丸 pin —
#          旧 `=~ [[:cntrl:]]` は glibc が C1 を cntrl と分類しないため素通し)
#   TC-17: contains_ctrl: 0xa0 (C1 上限 +1) / printable ASCII は clean (過剰検出しない境界 pin)
#   TC-18: contains_ctrl: UTF-8 U+009B (0xc2 0x9b) を 2 バイト目で検出
#   TC-19: contains_ctrl: empty string は clean / UTF-8 マルチバイト (日本語) は検出
#          (byte-wise 設計判断 pin — 継続バイト 0x80-0x9f 重複は accepted trade-off)
#   TC-20: contains_ctrl --c0-only: C0+DEL のみ検出・C1/日本語は clean
#          (neutralize_ctrl --c0-only と同一範囲を共有する検出側モード。UTF-8 本文を
#           検査する call site 用。未知の第 2 引数は default 範囲へ倒す fail-closed も pin)
#   TC-21: neutralize_ctrl --c0-only --keep-newline: 同一入力で日本語+改行保持・ESC は ?
#          ・生 C1 は素通し。未知第2引数は default 範囲へ倒す fail-closed
#   TC-22: --keep-newline: 日本語ロケールの git / シェルの原因行 (継続バイトに 0x80-0x9f を
#          含む) が無傷で、ESC・単独 0x9b・U+009B・途中で切れた多バイト列・overlong は ?
#   TC-23: --keep-newline: UTF-8 整形式判定の境界 (E0 / ED / F0 / F4 の 2 バイト目制約、
#          4 バイト列、継続バイト 0x80 / 0x9f) と隣接の形 (完結した文字の直後の余分な
#          継続バイト / 途中で切れた列の直後の正しい文字 / 列の途中の改行)、長さ保存、
#          NUL / 空入力、単独 --keep-newlin (typo) の default 範囲への fail-closed
#
# Usage: bash plugins/rite/hooks/tests/control-char-neutralize.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HELPER="$PLUGIN_ROOT/hooks/control-char-neutralize.sh"

if [ ! -f "$HELPER" ]; then
  echo "ERROR: $HELPER not found" >&2
  exit 1
fi
# shellcheck source=../control-char-neutralize.sh
source "$HELPER"

# stdout を hex 列へ (バイト単位比較用 — od のスペース/改行を除去)
to_hex() { od -An -tx1 | LC_ALL=C tr -d ' \n'; }

echo "=== TC-1: C0 制御文字 (0x01 / TAB / ESC) → ? ==="
assert "TC-1: C0 bytes neutralized" "A?B?C?D" "$(printf 'A\x01B\tC\x1bD' | neutralize_ctrl)"

echo ""
echo "=== TC-2: DEL (0x7f) → ? ==="
assert "TC-2: DEL neutralized" "A?B" "$(printf 'A\x7fB' | neutralize_ctrl)"

echo ""
echo "=== TC-3: C1 境界 (0x80 / 0x9b CSI / 0x9f) → ? ==="
# sed [[:cntrl:]] / bash ${var//[[:cntrl:]]/?} で実装するとこの 3 バイトを素通しする
# (glibc は C/UTF-8 両ロケールで C1 を cntrl と分類しないため)。その素通し経路を guard する。
assert "TC-3: C1 range boundaries neutralized" "A?B?C?D" "$(printf 'A\x80B\x9bC\x9fD' | neutralize_ctrl)"

echo ""
echo "=== TC-4: 0xa0 (C1 上限 +1) は保持 (過剰置換しない境界 pin) ==="
assert "TC-4: byte just above C1 preserved" "41a042" "$(printf 'A\xa0B' | neutralize_ctrl | to_hex)"

echo ""
echo "=== TC-5: UTF-8 U+009B (0xc2 0x9b) の 0x9b が ? 化される ==="
# valid UTF-8 の U+009B は jq の JSON 読み書きを素通りして call site まで届く
# 現実の攻撃バイト列 (xterm 等は UTF-8 モードでも C1 を制御文字として解釈する)。
# バイト単位置換は 2 バイト目の 0x9b を潰すため、出力に生 0x9b が残らない。
_tc5_hex=$(printf 'X\xc2\x9bY' | neutralize_ctrl | to_hex)
assert "TC-5: U+009B second byte neutralized (0xc2 remains, harmless)" "58c23f59" "$_tc5_hex"

echo ""
echo "=== TC-6: default モード — \\n も ? 化 (1 行 WARNING 埋め込み用) ==="
assert "TC-6: newline neutralized in default mode" "l1?l2" "$(printf 'l1\nl2' | neutralize_ctrl)"

echo ""
echo "=== TC-7: --keep-newline — \\n は保持、ASCII の後の制御文字は ? (行構造保持 snippet 用) ==="
assert "TC-7: newline preserved, others neutralized" "6c313f0a6c323f0a" "$(printf 'l1\x9b\nl2\x1b\n' | neutralize_ctrl --keep-newline | to_hex)"

echo ""
echo "=== TC-8: 可読 ASCII 無傷 + 1:1 置換 (長さ保存 — 空削除への revert を catch) ==="
assert "TC-8: printable ASCII untouched" "readable TEXT-123_ok" "$(printf 'readable TEXT-123_ok' | neutralize_ctrl)"
# `wc -c` right-justifies its count with leading spaces on BSD/macOS (GNU emits
# the bare number). `$( )` strips the trailing newline but not the leading pad,
# so strip whitespace before the string comparison.
assert "TC-8: 1:1 replacement preserves byte length" "3" "$(printf 'A\x9bB' | neutralize_ctrl | wc -c | tr -d ' ')"

echo ""
echo "=== TC-9: NUL バイト (0x00) → ? (バイトストリーム性 pin) ==="
assert "TC-9: NUL neutralized" "413f42" "$(printf 'A\x00B' | neutralize_ctrl | to_hex)"

echo ""
echo "=== TC-10: --c0-only — C0 (0x01 / TAB / ESC) + DEL → ? ==="
assert "TC-10: C0 bytes neutralized" "A?B?C?D?E" "$(printf 'A\x01B\tC\x1bD\x7fE' | neutralize_ctrl --c0-only)"

echo ""
echo "=== TC-11: --c0-only — C1 境界 (0x80 / 0x9b / 0x9f) は素通し (default との差分 pin) ==="
# RFC 8259 が JSON 文字列内で生バイトを禁じるのは C0 のみで、--c0-only は 0x80 以上に
# 触れない (default は ? 化する)。jq と対称なのは valid UTF-8 の C1 (0xc2 0x9b) のみ —
# 本 TC の raw 8-bit 単独 C1 は jq なら U+FFFD に置換されるため、素通しは --c0-only 固有。
assert "TC-11: C1 range preserved (hex)" "4180429b439f44" "$(printf 'A\x80B\x9bC\x9fD' | neutralize_ctrl --c0-only | to_hex)"

echo ""
echo "=== TC-12: --c0-only — UTF-8 マルチバイト (日本語) が無傷 (本丸 pin) ==="
# default モードは「停」(0xe5 0x81 0x9c) の継続バイト 0x81/0x9c を ? 化して本文を破壊する。
# --c0-only は 0x80 以上に触れないため、JSON フォールバック reason の日本語指示文が保持される。
assert "TC-12: Japanese text untouched" "停止せず継続" "$(printf '停止せず継続' | neutralize_ctrl --c0-only)"

echo ""
echo "=== TC-13: --c0-only — \\n も ? 化 (C0 範囲 — caller は改行を先にエスケープする契約) ==="
assert "TC-13: newline neutralized in c0-only mode" "l1?l2" "$(printf 'l1\nl2' | neutralize_ctrl --c0-only)"

# contains_ctrl の rc を assert 可能な文字列へ (rc 0 = detected / rc 1 = clean)
ctrl_verdict() { if contains_ctrl "$1"; then echo detected; else echo clean; fi; }

echo ""
echo "=== TC-14: contains_ctrl — C0 (0x01 / TAB / \\n / ESC) を検出 ==="
assert "TC-14: SOH (0x01) detected" "detected" "$(ctrl_verdict $'a\x01b')"
assert "TC-14: TAB detected" "detected" "$(ctrl_verdict $'a\tb')"
assert "TC-14: newline detected" "detected" "$(ctrl_verdict $'a\nb')"
assert "TC-14: ESC (0x1b) detected" "detected" "$(ctrl_verdict $'a\x1bb')"

echo ""
echo "=== TC-15: contains_ctrl — DEL (0x7f) を検出 ==="
assert "TC-15: DEL detected" "detected" "$(ctrl_verdict $'a\x7fb')"

echo ""
echo "=== TC-16: contains_ctrl — C1 境界 (0x80 / 0x9b CSI / 0x9f) を検出 (本丸) ==="
# 旧 `=~ [[:cntrl:]]` (flow-state.sh / wiki-ingest-trigger.sh の reject 経路) は
# glibc が C/UTF-8 両ロケールで C1 を cntrl と分類しないためこの 3 バイトを素通ししていた。
assert "TC-16: C1 lower bound (0x80) detected" "detected" "$(ctrl_verdict $'a\x80b')"
assert "TC-16: CSI introducer (0x9b) detected" "detected" "$(ctrl_verdict $'a\x9bb')"
assert "TC-16: C1 upper bound (0x9f) detected" "detected" "$(ctrl_verdict $'a\x9fb')"

echo ""
echo "=== TC-17: contains_ctrl — 0xa0 / printable ASCII は clean (過剰検出しない境界 pin) ==="
assert "TC-17: byte just above C1 (0xa0) clean" "clean" "$(ctrl_verdict $'a\xa0b')"
assert "TC-17: printable ASCII clean" "clean" "$(ctrl_verdict 'pr-123 TEXT_ok~')"

echo ""
echo "=== TC-18: contains_ctrl — UTF-8 U+009B (0xc2 0x9b) を 2 バイト目で検出 ==="
# valid UTF-8 の U+009B は jq / YAML パーサを素通りして call site まで届く現実の攻撃
# バイト列 (TC-5 と同じ脅威モデルの検出側 pin)。
assert "TC-18: U+009B detected via second byte" "detected" "$(ctrl_verdict $'x\xc2\x9by')"

echo ""
echo "=== TC-19: contains_ctrl — empty は clean / 日本語は検出 (byte-wise 設計判断 pin) ==="
assert "TC-19: empty string clean" "clean" "$(ctrl_verdict '')"
# UTF-8 継続バイト (0x80-0x9f 重複) の検出は accepted trade-off (設計判断)。
# この assert が fail し始めたら byte-wise 契約自体が変わったことを意味する。
assert "TC-19: multibyte (Japanese) detected via continuation bytes" "detected" "$(ctrl_verdict 'あ')"

echo ""
echo "=== TC-20: contains_ctrl --c0-only — 範囲は neutralize_ctrl --c0-only と同一 ==="
# UTF-8 本文 (日本語 title 等) を検査する call site 用モード。default 範囲との差分は
# C1 (0x80-0x9f) の扱いのみで、そこが継続バイトを巻き込む false positive の発生源。
# neutralize_ctrl --c0-only (TC-10〜13) と同じ範囲を共有していることを両側で pin する。
ctrl_verdict_c0() { if contains_ctrl "$1" --c0-only; then echo detected; else echo clean; fi; }
assert "TC-20: C0 (SOH) detected in --c0-only" "detected" "$(ctrl_verdict_c0 $'a\x01b')"
assert "TC-20: TAB detected in --c0-only" "detected" "$(ctrl_verdict_c0 $'a\tb')"
assert "TC-20: newline detected in --c0-only" "detected" "$(ctrl_verdict_c0 $'a\nb')"
assert "TC-20: DEL detected in --c0-only" "detected" "$(ctrl_verdict_c0 $'a\x7fb')"
# 本モードの存在意義: default が detected を返す日本語が clean になる (TC-19 と対の差分 pin)
assert "TC-20: multibyte (Japanese) clean in --c0-only" "clean" "$(ctrl_verdict_c0 'あ')"
assert "TC-20: C1 (0x9b CSI) clean in --c0-only" "clean" "$(ctrl_verdict_c0 $'a\x9bb')"
assert "TC-20: printable ASCII clean in --c0-only" "clean" "$(ctrl_verdict_c0 'a-b_c.d')"
assert "TC-20: empty string clean in --c0-only" "clean" "$(ctrl_verdict_c0 '')"
# 未知の第 2 引数は default 範囲へ倒す (typo を silent に緩い判定へ落とさない fail-closed 側)
assert "TC-20: unknown 2nd arg falls back to default range" "detected" "$(ctrl_verdict_c0_typo() { if contains_ctrl "$1" --c0only; then echo detected; else echo clean; fi; }; ctrl_verdict_c0_typo 'あ')"

echo ""
echo "=== TC-21: --c0-only --keep-newline — 日本語+改行保持 / ESC は ? / C1 素通し ==="
# S2 と同じ引数順。日本語・改行・ESC・生 C1(0x9b) を同一入力に載せ、合成を pin する。
# あ = e3 81 82 / \\n = 0a / B / ESC 1b → 3f / C / 0x9b 素通し / D
_tc21_hex=$(printf 'あ\nB\x1bC\x9bD' | neutralize_ctrl --c0-only --keep-newline | to_hex)
assert "TC-21: combined flags keep UTF-8+newline, strip ESC, pass C1" "e381820a423f439b44" "$_tc21_hex"
# 未知第2引数は default 範囲（C1 込み・改行も ?）へ倒す。日本語継続バイトが壊れる。
# 破壊後の本文は不正 UTF-8 になるので比較は hex のみ（bash [ ] や echo に載せない）。
_tc21_intact_hex=$(printf '停止せず継続' | to_hex)
_tc21_typo_hex=$(printf '停止せず継続' | neutralize_ctrl --c0-only --keep-newlin | to_hex)
if [ "$_tc21_typo_hex" != "$_tc21_intact_hex" ]; then
  assert "TC-21: unknown 2nd arg falls back to default range" "destroyed" "destroyed"
else
  assert "TC-21: unknown 2nd arg falls back to default range" "destroyed" "intact"
fi

echo ""
echo "=== TC-22: --keep-newline — 日本語の原因行は無傷 / C1 と壊れた列は ? ==="
# ja_JP.UTF-8 の git / bash が出す文言を固定バイト列で渡す (ランナーの locale に依存しない)。
# 「ディ」(e3 83 87) や「ホ」(e3 83 9b) の継続バイトは C1 範囲と重なる — 旧実装はここを ? にしていた。
_tc22_msg=$'fatal: そのようなファイルやディレクトリはありません\nディレクトリです\nホ'
assert "TC-22: localized stderr lines pass through byte-for-byte" \
  "$(printf '%s' "$_tc22_msg" | to_hex)" "$(printf '%s' "$_tc22_msg" | neutralize_ctrl --keep-newline | to_hex)"
# 制御側は同じ呼び出しで潰れたまま。1 行に 1 種類ずつ置き、どの腕が外れても hex がずれる:
#   ESC 1b / 単独 0x9b / U+009B (c2 9b — c2 は残す、TC-5 と同じ) / 途中で切れた「デ」(e3 83 + 改行) /
#   overlong の U+009B (e0 82 9b) / 範囲外の先頭バイト (c0 9b)
_tc22_ctrl=$(printf 'a\x1bb\nc\x9bd\ne\xc2\x9bf\ng\xe3\x83\nh\xe0\x82\x9bi\nj\xc0\x9bk' | neutralize_ctrl --keep-newline | to_hex)
assert "TC-22: control and malformed bytes neutralized, newlines kept" \
  "613f620a633f640a65c23f660a67e33f0a68e03f3f690a6ac03f6b" "$_tc22_ctrl"
# 末尾改行の有無を変えない (awk が改行を足したり落としたりしない)
assert "TC-22: no trailing newline added" "6e6f2d6e6c" "$(printf 'no-nl' | neutralize_ctrl --keep-newline | to_hex)"
assert "TC-22: trailing newline kept" "6e6c0a" "$(printf 'nl\n' | neutralize_ctrl --keep-newline | to_hex)"

echo ""
echo "=== TC-23: --keep-newline — 整形式判定の境界と隣接の形 ==="
kn_hex() { printf "$1" | neutralize_ctrl --keep-newline | to_hex; }
# 残す: 継続バイト 0x80 / 0x9f の境界、E0 / ED / F0 / F4 の 2 バイト目の許容端、4 バイト列
for _tc23_keep in 'e38080' 'e3819f' 'e0a080' 'ed9fbf' 'f09f9880' 'f0908080' 'f48fbfbf' 'c2a0'; do
  _tc23_in=$(printf '%s' "$_tc23_keep" | sed 's/../\\x&/g')
  assert "TC-23: well-formed $_tc23_keep kept" "$_tc23_keep" "$(kn_hex "$_tc23_in")"
done
# ? にする: 単独の境界バイト (0xa0 は範囲外なので残す)、overlong、サロゲート、U+10FFFF 超、
# 範囲外の先頭バイト。先頭バイトは 0xa0 以上なので残り、後続の 0x80-0x9f だけが ? になる
assert "TC-23: lone 0x80 / 0x9f neutralized, 0xa0 kept" "3f3fa0" "$(kn_hex '\x80\x9f\xa0')"
assert "TC-23: overlong 2-byte (c1 9b)" "c13f" "$(kn_hex '\xc1\x9b')"
assert "TC-23: overlong 3-byte (e0 9f 80)" "e03f3f" "$(kn_hex '\xe0\x9f\x80')"
assert "TC-23: surrogate (ed a0 80)" "eda03f" "$(kn_hex '\xed\xa0\x80')"
assert "TC-23: overlong 4-byte (f0 8f 80 80)" "f03f3f3f" "$(kn_hex '\xf0\x8f\x80\x80')"
assert "TC-23: above U+10FFFF (f4 90 80 80)" "f43f3f3f" "$(kn_hex '\xf4\x90\x80\x80')"
assert "TC-23: invalid lead f5" "f53f" "$(kn_hex '\xf5\x9b')"
# 隣接の形: 完結した文字の直後の余分な継続バイト / 途中で切れた列の直後の正しい文字 / 列の途中の改行
assert "TC-23: stray continuation after complete char" "e381823f" "$(kn_hex '\xe3\x81\x82\x9b')"
assert "TC-23: extra continuation after complete char" "e381823f" "$(kn_hex '\xe3\x81\x82\x81')"
assert "TC-23: truncated sequence resyncs on next char" "e33fe38182" "$(kn_hex '\xe3\x81\xe3\x81\x82')"
assert "TC-23: newline inside a sequence" "e30a3f" "$(kn_hex '\xe3\x0a\x81')"
# 長さ保存: 置換は 1:1 で、awk がバイトを足したり落としたりしない
_tc23_big=$(for _i in $(seq 1 200); do printf 'そのようなファイルやディレクトリはありません %s\n' "$_i"; done)
assert "TC-23: multi-KB Japanese input byte count preserved" \
  "$(printf '%s' "$_tc23_big" | LC_ALL=C wc -c | tr -d ' ')" \
  "$(printf '%s' "$_tc23_big" | neutralize_ctrl --keep-newline | LC_ALL=C wc -c | tr -d ' ')"
assert "TC-23: empty input stays empty" "" "$(printf '' | neutralize_ctrl --keep-newline | to_hex)"
assert "TC-23: NUL and 0x01 neutralized" "613f623f63" "$(printf 'a\x00b\x01c' | neutralize_ctrl --keep-newline | to_hex)"
# 不正バイトでも rc 0 (set -euo pipefail の診断経路を止めない)
set +e
printf '\xe3\x81\x9b\xff\xfe\x80' | neutralize_ctrl --keep-newline >/dev/null
_tc23_rc=$?
set -e
assert "TC-23: malformed input exits 0" "0" "$_tc23_rc"
# 単独 --keep-newlin (typo) は default 範囲 (改行も ?、日本語は壊れる) へ倒す
assert "TC-23: typo single flag falls back to default range" "613f623f" \
  "$(printf 'a\nb\x9b' | neutralize_ctrl --keep-newlin | to_hex)"
_tc23_typo_jp=$(printf 'ディ' | neutralize_ctrl --keep-newlin | to_hex)
assert "TC-23: typo single flag destroys Japanese (default range)" "e33f3fe33fa3" "$_tc23_typo_jp"

if ! print_summary "$(basename "$0")" "control-char-neutralize.sh — C0+DEL+C1 neutralization (--keep-newline keeps well-formed UTF-8) + detection shared helper"; then
  exit 1
fi
