#!/bin/bash
# gh-issue-develop-base.test.sh
#
# base がデフォルトブランチと異なる git-flow では、remote branch を作る
# `gh issue develop` に `--base` を明示する規則
# (references/gh-cli-patterns.md「PR 作成・運用の規則」節) の機械検証。
#
# 検査範囲: plugins/rite/ 配下の *.md / *.sh / *.yml のうち、`gh issue develop`
# を含む行（コマンド例だけでなく規則本文などの散文中の言及も対象。このテスト
# ファイル自身は除外）が、同じ行に `--base` を伴うこと。判定は 1 行単位の文字列
# 一致のため、行継続 (\) で次行に --base を書いた記述は誤検知し、同じ行の別
# コマンドの --base は見逃す。`gh issue develop` は 1 行で書く前提とする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

PATTERN='gh[[:space:]]+issue[[:space:]]+develop'

# scan_dir <dir>: <dir> 配下の `gh issue develop` 行を grep -rn 形式で出力する。
# 走査自体の失敗 (rc>=2) は 2 を返す。ヒット 0 件 (rc=1) は空出力で 0 を返す。
scan_dir() {
  local rc=0
  # grep の実装差（BSD / GNU）に依存しないよう、ディレクトリの存在を先に明示検査する
  [ -d "$1" ] || return 2
  grep -rnE "$PATTERN" "$1" \
    --include='*.md' --include='*.sh' --include='*.yml' \
    --exclude='gh-issue-develop-base.test.sh' || rc=$?
  [ "$rc" -le 1 ] || return 2
}

# filter_violations: stdin の行から --base を伴わない行だけを出力する
filter_violations() {
  grep -v -e '--base' || true
}

# TC-1: 走査が成功し、1 行以上ヒットする (走査対象の取り違えで素通りしない)
scan_out=""
scan_ok=0
if scan_out=$(scan_dir "$PLUGIN_ROOT"); then
  scan_ok=1
  hits=$(printf '%s' "$scan_out" | grep -c . || true)
  if [ "$hits" -ge 1 ]; then
    pass "TC-1 走査が成功し gh issue develop を $hits 行検出"
  else
    fail "TC-1 gh issue develop が 1 行も検出されない (走査対象の誤りの可能性)"
  fi
else
  fail "TC-1 走査 (grep) が rc>=2 で失敗"
fi

# TC-2: 全ての gh issue develop 記述が --base を伴う（走査が成功したときのみ判定）
if [ "$scan_ok" -eq 1 ]; then
  violations=$(printf '%s' "$scan_out" | filter_violations)
  if [ -z "$violations" ]; then
    pass "TC-2 全ての gh issue develop 記述が --base を伴う"
  else
    fail "TC-2 --base なしの gh issue develop を検出:
$violations"
  fi
fi

# TC-2b: 復旧案内 (recover スキル) の gh issue develop が走査対象に含まれる
if [ "$scan_ok" -eq 1 ]; then
  if printf '%s' "$scan_out" | grep -q 'skills/recover/SKILL\.md'; then
    pass "TC-2b recover スキルの gh issue develop 記述を検出"
  else
    fail "TC-2b recover スキルの gh issue develop 記述が検出されない"
  fi
fi

# TC-3: 同じ scan_dir / filter_violations が fixture の違反行を検出する
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
printf '%s\n' 'run gh issue develop 1 -R o/r' 'run gh issue develop 1 -R o/r --base develop' > "$fixture/sample.md"
if ! fixture_out=$(scan_dir "$fixture"); then
  fail "TC-3 fixture の走査が rc>=2 で失敗"
  fixture_out=""
fi
fixture_violations=$(printf '%s' "$fixture_out" | filter_violations)
if [ "$(printf '%s' "$fixture_violations" | grep -c .)" -eq 1 ] && [ "${fixture_violations#*:1:}" = "run gh issue develop 1 -R o/r" ]; then
  pass "TC-3 fixture の --base なし行のみを違反として検出"
else
  fail "TC-3 検出処理が fixture で期待どおりに動作しない: $fixture_violations"
fi

# TC-4: ディレクトリでないパスの走査は 2 を返す
if scan_dir "$fixture/missing" >/dev/null 2>&1; then
  fail "TC-4 ディレクトリでないパスの走査が成功扱いになった"
else
  pass "TC-4 ディレクトリでないパスの走査を 2 で返す"
fi

print_summary "gh-issue-develop-base.test.sh"
