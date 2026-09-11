#!/bin/bash
# comment-journal-check.test.sh
#
# Tests for comment-journal-check.sh — the fast-fail layer that flags journal
# narration (P1-P4) in plugins/rite/**, docs/** and .rite/wiki/**.
#
# Coverage:
#   TC-3   TODO / FIXME 行は P1-P4 もスキップする
#   TC-7   P1-P4 regex と example-marker skip (HTML / hash / slash)
#   TC-8   裸の `#N` / `Issue #N` / `PR #N` は hit しない (P1-P4 の非対象)
#   TC-9   1 行に複数一致があれば全件報告される (multi-match discipline)
#   TC-10  フェンス内の P1 検出は従来どおり残る
#   TC-11  exit code 契約 (0 = clean / 1 = findings / 2 = invocation error)
#   TC-14  self-exclusion (SoT 本体 / parity test / 自スクリプト / 本 test)
#
# Diagnostic neutralization/head emission is covered repository-wide by
# diag-snippet-neutralize-parity.test.sh. This suite pins --quiet via TC-11;
# duplicating injected IO failures here would test the shared diagnostic policy,
# not this checker's detection contract. mktemp failure on read-only /tmp remains
# environment-dependent and is not reproduced here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/comment-journal-check.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: script not found: $SCRIPT" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local p
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
}
trap cleanup EXIT

SBX=$(make_plain_sandbox) && cleanup_dirs+=("$SBX") || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }
mkdir -p "$SBX/docs"

# scan: write $1 as docs/t.md and return the findings for it (one per line).
scan() {
  printf '%s\n' "$1" > "$SBX/docs/t.md"
  ( cd "$SBX" && bash "$SCRIPT" --target docs/t.md --repo-root "$SBX" --quiet ) 2>/dev/null
}
# count: number of findings; pat_count: findings matching a pattern
count() { scan "$1" | grep -c . ; }
pat_count() { scan "$1" | grep -cE "$2" || true ; }

echo "== comment-journal-check.sh (P1-P4) =="

# ---- TC-7 P1-P4 regex と example-marker skip --------------------------------
# P1-P4 regexes and each supported example-marker dialect are individually
# pinned so deleting one alternation member cannot survive behind aggregate counts.
assert "TC-7 P1 regex member is pinned" "1" "$(pat_count 'verified-review cycle 3' '\[P1\]')"
assert "TC-7 P2 regex member is pinned" "1" "$(pat_count '旧実装はこう動いていた' '\[P2\]')"
assert "TC-7 P3 regex member is pinned" "1" "$(pat_count 'PR #123 cycle 4 fix' '\[P3\]')"
assert "TC-7 P4 regex member is pinned" "1" "$(pat_count 'cycle 4 F-2 で導入' '\[P4\]')"
assert "TC-7 HTML example marker skips line" "0" "$(count '<!-- example: verified-review cycle 3 -->')"
assert "TC-7 hash example marker skips line" "0" "$(count '# example: PR #123 cycle 4 fix')"
assert "TC-7 slash example marker skips line" "0" "$(count '// example: cycle 4 F-2 で導入')"

# ---- TC-8 意図的な非対象 (P1-P4 は裸の番号参照に一致しない) -----------------
assert "TC-8 キーワードなし裸 #N は hit しない" "0" "$(count '#123 の単独形は対象外')"
assert "TC-8 裸の PR #N は hit しない" "0" "$(count 'PR #123 は フォーマットを統一した')"
assert "TC-8 裸の Issue #N は hit しない" "0" "$(count 'Issue #123 系譜の継続')"

# ---- TC-3 TODO / FIXME (P1 fixture — 行スキップは P1-P4 にも効く) -----------
assert "TC-3 TODO 行は hit しない"  "0" "$(count 'TODO: verified-review cycle 9 を確認')"
assert "TC-3 FIXME 行は hit しない" "0" "$(count 'FIXME 旧実装は残す')"

# ---- TC-10 フェンス内でも P1 は検出される -----------------------------------
fence_p1=$(printf '```bash\n# verified-review cycle 8 はフェンス内\n```\n')
assert "TC-10 フェンス内でも P1 は従来どおり検出される" "1" "$(pat_count "$fence_p1" '\[P1\]')"

# ---- TC-9 multi-match --------------------------------------------------------
assert "TC-9 1 行に P1 と P2 があれば 2 件報告される" "2" "$(count 'verified-review cycle 3 のあと 旧実装は残っていた')"

# ---- TC-11 exit code 契約 ----------------------------------------------------
printf '%s\n' 'クリーンな行' > "$SBX/docs/t.md"
( cd "$SBX" && bash "$SCRIPT" --target docs/t.md --repo-root "$SBX" --quiet ) >/dev/null 2>&1
assert "TC-11 findings なし → exit 0" "0" "$?"
printf '%s\n' 'verified-review cycle 3' > "$SBX/docs/t.md"
( cd "$SBX" && bash "$SCRIPT" --target docs/t.md --repo-root "$SBX" --quiet ) >/dev/null 2>&1
assert "TC-11 findings あり → exit 1" "1" "$?"
( cd "$SBX" && bash "$SCRIPT" --repo-root "$SBX" --quiet ) >/dev/null 2>&1
assert "TC-11 target 指定なし → exit 2" "2" "$?"
( cd "$SBX" && bash "$SCRIPT" --bogus-flag --repo-root "$SBX" --quiet ) >/dev/null 2>&1
assert "TC-11 未知の引数 → exit 2" "2" "$?"

# ---- TC-14 self-exclusion の静的回帰 ----------------------------------------
# 禁止句を「定義・例示」するファイルを --all の走査から外す契約。SoT は P1
# (verified-review cycle) と P2 (旧実装は) を含む。
assert_grep "TC-14 SoT 本体を self-exclude" "$SCRIPT" 'comment-best-practices\.md\) continue'
assert_grep "TC-14 parity test を self-exclude" "$SCRIPT" 'comment-best-practices-parity\.test\.sh\) continue'
assert_grep "TC-14 自スクリプトを self-exclude" "$SCRIPT" '"\$self_rel"\) continue'
assert_grep "TC-14 本 test を self-exclude" "$SCRIPT" 'comment-journal-check\.test\.sh\) continue'
assert_not_grep "TC-14 wiki-lint 側 test は self-exclude しない" "$SCRIPT" 'wiki-lint-descriptive-refs\.test\.sh\) continue'
# sandbox に対して --all を回す。実リポジトリを走査すると、走査対象数や awk 実装差 (macOS の
# BWK awk) で件数が 0 になる環境があり、その環境では下の除外 assert が丸ごと vacuous になる。
ALLSBX=$(make_plain_sandbox) && cleanup_dirs+=("$ALLSBX") || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }
mkdir -p "$ALLSBX/plugins/rite/hooks/tests" "$ALLSBX/docs"
printf 'verified-review cycle 3
' > "$ALLSBX/docs/violating.md"
printf '旧実装は残っていた
' > "$ALLSBX/plugins/rite/hooks/tests/comment-journal-check.test.sh"
# self-exclude 対象でない違反も各 root に置く。docs だけだと plugins/rite / .rite/wiki が
# scan_roots から落ちても positive control が充足し、除外 assert が無言で vacuous になる。
printf 'PR #123 cycle 4 fix\n' > "$ALLSBX/plugins/rite/hooks/tests/other.test.sh"
mkdir -p "$ALLSBX/.rite/wiki/pages"
printf 'cycle 4 F-2 で導入\n' > "$ALLSBX/.rite/wiki/pages/w.md"
all_out=$( ( cd "$ALLSBX" && bash "$SCRIPT" --all --quiet --repo-root "$ALLSBX" ) 2>/dev/null )
all_lines=$(printf '%s' "$all_out" | grep -c . || true)
# positive control: --all が 1 件も出さない状況 (scan root 不在で rc=2 等) では下の assert が
# vacuous に pass する。先に「走査自体が成立した」ことを測る。
if [ "${all_lines:-0}" -gt 0 ]; then
  pass "TC-14 --all が findings を出した (${all_lines} 行 — 除外 assert が vacuous でない)"
else
  fail "TC-14 --all が 0 件 — 除外 assert が vacuous になるため判定不能"
fi
# 各 scan root を実際に歩いたことを測る (歩いていなければ除外 assert が何も保証しない)。
assert "TC-14 docs root を走査した" "1" "$(printf '%s' "$all_out" | grep -c 'docs/violating' || true)"
assert "TC-14 plugins/rite root を走査した" "1" "$(printf '%s' "$all_out" | grep -c 'tests/other' || true)"
assert "TC-14 .rite/wiki root を走査した" "1" "$(printf '%s' "$all_out" | grep -c 'wiki/pages/w' || true)"
excluded_hits=$(printf '%s' "$all_out" | grep -cE 'tests/comment-journal-check\.test\.sh' || true)
assert "TC-14 --all で検出器 test の fixture が hit しない" "0" "$excluded_hits"

if ! print_summary "$(basename "$0")" \
  "drift: comment-journal-check.sh の P1-P4 検出が変わった可能性。スクリプト冒頭の Detected patterns (4 regexes) と Whitelist の記述を参照。"; then
  exit 1
fi
