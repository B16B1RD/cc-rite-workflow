#!/bin/bash
# Tests for hooks/scripts/lib/rite-config-path.sh.
#
# Contract: a linked session worktree reads its own rite-config.yml when it has
# one (tracked config) and otherwise the main checkout's (untracked config);
# no candidate → rc=1 with every tried path on stderr; an unreadable candidate
# → rc=2 without falling through; outside Git only the given directory counts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

HELPER="$SCRIPT_DIR/../scripts/lib/rite-config-path.sh"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && chmod -R u+rwx "$d" 2>/dev/null; [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

MAIN=$(make_sandbox --branch develop)
cleanup_dirs+=("$MAIN")
WT="${MAIN}-wt"
git -C "$MAIN" worktree add -q -b feat/config "$WT" >/dev/null 2>&1 || { echo "ERROR: git worktree add failed" >&2; exit 1; }
cleanup_dirs+=("$WT")

# run <dir> → sets OUT (stdout), ERR (stderr), RC
run() {
  local errf; errf=$(mktemp)
  RC=0
  OUT=$(bash "$HELPER" "$1" 2>"$errf") || RC=$?
  ERR=$(cat "$errf"); rm -f "$errf"
}

echo "=== T-01: config only in the main checkout → worktree resolves to main's file ==="
printf 'x: 1\n' > "$MAIN/rite-config.yml"
run "$WT"
assert "T-01 rc" "0" "$RC"
assert "T-01 path" "$MAIN/rite-config.yml" "$OUT"
assert "T-01 no stderr on success" "" "$ERR"
mkdir -p "$WT/sub/deep"
run "$WT/sub/deep"
assert "T-01 subdir of worktree also resolves to main's file" "$MAIN/rite-config.yml" "$OUT"

echo "=== T-04: both have a config → the worktree's file wins ==="
printf 'x: 2\n' > "$WT/rite-config.yml"
run "$WT"
assert "T-04 path" "$WT/rite-config.yml" "$OUT"
rm -f "$WT/rite-config.yml"

echo "=== T-06: non-worktree checkout → its own toplevel ==="
run "$MAIN"
assert "T-06 rc" "0" "$RC"
assert "T-06 path" "$MAIN/rite-config.yml" "$OUT"

echo "=== T-05: no config anywhere → rc=1, stdout empty, both tried paths on stderr ==="
rm -f "$MAIN/rite-config.yml"
run "$WT"
assert "T-05 rc" "1" "$RC"
assert "T-05 stdout empty" "" "$OUT"
case "$ERR" in
  *"$WT/rite-config.yml"*"$MAIN/rite-config.yml"*) pass "T-05 stderr names worktree then main path" ;;
  *) fail "T-05 stderr names worktree then main path (got '$ERR')" ;;
esac

echo "=== T-07: unreadable main config → rc=2, no fall-through to defaults ==="
if [ "$(id -u)" -eq 0 ]; then
  skip "T-07 unreadable file (root ignores mode bits)"
else
  printf 'x: 1\n' > "$MAIN/rite-config.yml"
  chmod 000 "$MAIN/rite-config.yml"
  run "$WT"
  assert "T-07 rc" "2" "$RC"
  assert "T-07 stdout empty" "" "$OUT"
  case "$ERR" in
    *"$MAIN/rite-config.yml"*) pass "T-07 stderr names the unreadable path" ;;
    *) fail "T-07 stderr names the unreadable path (got '$ERR')" ;;
  esac
  chmod 644 "$MAIN/rite-config.yml"
  rm -f "$MAIN/rite-config.yml"
fi

echo "=== T-08: outside Git → only the given directory ==="
PLAIN=$(make_plain_sandbox)
cleanup_dirs+=("$PLAIN")
run "$PLAIN"
assert "T-08 missing rc" "1" "$RC"
printf 'x: 1\n' > "$PLAIN/rite-config.yml"
run "$PLAIN"
assert "T-08 found path" "$PLAIN/rite-config.yml" "$OUT"

echo "=== T-09: sourcing defines the function without changing shell options ==="
opts_before=$(set +o)
# shellcheck source=../scripts/lib/rite-config-path.sh
source "$HELPER"
opts_after=$(set +o)
assert "T-09 shell options unchanged by source" "$opts_before" "$opts_after"
assert "T-09 function resolves" "$PLAIN/rite-config.yml" "$(rite_config_path "$PLAIN")"

echo "=== T-11: --or-devnull turns a missing config into a WARNING + /dev/null, keeps unreadable an error ==="
rm -f "$MAIN/rite-config.yml"
errf=$(mktemp); rc=0
out=$(bash "$HELPER" --or-devnull "$WT" 2>"$errf") || rc=$?
assert "T-11 missing rc" "0" "$rc"
assert "T-11 missing stdout is /dev/null" "/dev/null" "$out"
case "$(cat "$errf")" in
  WARNING:*"$WT/rite-config.yml"*"$MAIN/rite-config.yml"*) pass "T-11 missing warns with both tried paths" ;;
  *) fail "T-11 missing warns with both tried paths (got '$(cat "$errf")')" ;;
esac
printf 'x: 1\n' > "$MAIN/rite-config.yml"
assert "T-11 found path passes through" "$MAIN/rite-config.yml" "$(bash "$HELPER" --or-devnull "$WT")"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$MAIN/rite-config.yml"
  rc=0; out=$(bash "$HELPER" --or-devnull "$WT" 2>"$errf") || rc=$?
  assert "T-11 unreadable rc" "2" "$rc"
  assert "T-11 unreadable stdout empty" "" "$out"
  chmod 644 "$MAIN/rite-config.yml"
fi
rm -f "$MAIN/rite-config.yml" "$errf"

echo "=== T-10: pr-review post_comment read uses the main checkout config from a worktree ==="
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR_SKILL="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
block=$(awk '/^# --- Step 3: rite-config.yml の pr_review.post_comment 読取/{f=1} /^# --- Step 4:/{f=0} f' "$PR_SKILL" \
  | sed "s|{plugin_root}|$PLUGIN_ROOT|g")
case "$block" in
  *rite-config-path.sh*) pass "T-10 block extracted and calls the resolver" ;;
  *) fail "T-10 block extracted and calls the resolver" ;;
esac
printf 'pr_review:\n  post_comment: true\n' > "$MAIN/rite-config.yml"
got=$(cd "$WT" && bash -c "$block"$'\necho "post=$config_post_comment"' 2>&1)
case "$got" in
  *"post=true"*) pass "T-10 worktree reads post_comment=true from main" ;;
  *) fail "T-10 worktree reads post_comment=true from main (got '$got')" ;;
esac
rm -f "$MAIN/rite-config.yml"
got=$(cd "$WT" && bash -c "$block"$'\necho "post=$config_post_comment"' 2>&1)
case "$got" in
  *"WARNING:"*"$MAIN/rite-config.yml"*"post=false"*) pass "T-10 missing config warns with tried path and defaults to false" ;;
  *) fail "T-10 missing config warns with tried path and defaults to false (got '$got')" ;;
esac
if [ "$(id -u)" -eq 0 ]; then
  skip "T-10 unreadable config (root ignores mode bits)"
else
  printf 'pr_review:\n  post_comment: true\n' > "$MAIN/rite-config.yml"
  chmod 000 "$MAIN/rite-config.yml"
  rc=0; got=$(cd "$WT" && bash -c "$block"$'\necho "post=$config_post_comment"' 2>&1) || rc=$?
  chmod 644 "$MAIN/rite-config.yml"
  assert "T-10 unreadable config exits 1" "1" "$rc"
  case "$got" in
    *"reason=config_unreadable"*"[review:error]"*) pass "T-10 unreadable config stops with review:error" ;;
    *) fail "T-10 unreadable config stops with review:error (got '$got')" ;;
  esac
  case "$got" in
    *"post="*) fail "T-10 unreadable config does not continue with a default (got '$got')" ;;
    *) pass "T-10 unreadable config does not continue with a default" ;;
  esac
  rm -f "$MAIN/rite-config.yml"
fi

echo "=== T-12: initialization checks resolve the config instead of listing the cwd ==="
# 停止の否定形を数える。空行とフェンス行で段落を切ってから行をつなぎ、強調記号を落とすので、
# 改行や ** / _ を挟んだ否定も数える。否定語と stop の間に 2 語まで挟めるのは命令・助動詞の否定
# （do not / must not / cannot / n't / never など）だけで、素の not は直後の stop だけを数える。
# 「not initialized so stop」のように素の not で状態を否定したあとに停止文が続く形は否定形にしない
# （助動詞つきの「does not exist so stop」は 2 語の窓に入るので否定形に数える）
count_negated_stop() {
  printf '%s\n' "$1" | sed -E 's/^[[:space:]]*(```.*)?$/ . /' | tr '\n' ' ' | tr -d '*_' \
    | grep -Eci "((^|[^[:alpha:]])(do|does|did|must|should|shall|will|would|can|could|may|might|need)[[:space:]]+not|cannot|n't|(^|[^[:alpha:]])never)([[:space:]]+[[:alpha:]]+){0,2}[[:space:]]+stop|(^|[^[:alpha:]])not[[:space:]]+stop" || true
}
for neg_case in $'Do not\nstop here.' 'Do **NOT** stop here.' 'Do not **immediately** stop.' 'must not immediately stop' \
  "don't stop" 'never stop' 'cannot stop' 'Do not ever stop'; do
  assert "T-12 counts '${neg_case//$'\n'/\\n}' as a negated stop" "1" "$(count_negated_stop "$neg_case")"
done
for stop_case in 'Config not initialized so stop here.' $'The config does not exist\n\nStop here.' \
  $'The config does not exist\n```\nStop here.' 'Show the message and stop.'; do
  assert "T-12 counts '${stop_case//$'\n'/\\n}' as a stop" "0" "$(count_negated_stop "$stop_case")"
done
# $1 skill, $2 section start heading, $3 next heading, $4 text of the rc=1 message,
# $5 whether rc=1 stops the skill (stop | guide),
# $6 text only the If rc=0 paragraph shows, or - when the section has no If rc=0 paragraph
check_init_section() {
  local skill_md="$PLUGIN_ROOT/skills/$1/SKILL.md" sec blk rc out rc0_line rc1_line rc0_para rc1_para rows
  local rc1_text stop_n cont_n neg_n
  sec=$(awk -v s="$2" -v e="$3" 'index($0, s) == 1 {f = 1; next} f && index($0, e) == 1 {exit} f' "$skill_md")
  blk=$(printf '%s\n' "$sec" | awk '/^```bash$/ {b = 1; next} b && /^```$/ {exit} b' | sed "s|{plugin_root}|$PLUGIN_ROOT|g")
  case "$blk" in
    *rite-config-path.sh*) pass "T-12 $1 check block calls the resolver" ;;
    *) fail "T-12 $1 check block calls the resolver" ;;
  esac
  printf 'x: 1\n' > "$MAIN/rite-config.yml"
  rc=0; out=$(cd "$WT" && bash -c "$blk" 2>/dev/null) || rc=$?
  assert "T-12 $1 finds the main checkout config from a worktree" "0:$MAIN/rite-config.yml" "$rc:$out"
  rm -f "$MAIN/rite-config.yml"
  rc=0; (cd "$WT" && bash -c "$blk" >/dev/null 2>&1) || rc=$?
  assert "T-12 $1 reports a missing config as rc=1" "1" "$rc"
  case "$sec" in
    *"$4"*) pass "T-12 $1 keeps the not-initialized message" ;;
    *) fail "T-12 $1 keeps the not-initialized message" ;;
  esac
  # set -e 下で一致なしの grep がスイートを止めないよう、空行として受けて fail に回す
  rc2_line=$(printf '%s\n' "$sec" | grep -E '^\| 2 \|' | head -n 1) || rc2_line=""
  case "$rc2_line" in
    *stop*) pass "T-12 $1 stops on rc=2" ;;
    *) fail "T-12 $1 stops on rc=2 (line: '$rc2_line')" ;;
  esac
  other_line=$(printf '%s\n' "$sec" | grep -E '^\| other \|' | head -n 1) || other_line=""
  case "$other_line" in
    *stop*) pass "T-12 $1 stops when the resolver cannot run" ;;
    *) fail "T-12 $1 stops when the resolver cannot run (line: '$other_line')" ;;
  esac
  rows=$(printf '%s\n' "$sec" | awk -F'|' '/^\|/ && !/^\| rc \|/ && !/^\|-/ {gsub(/ /, "", $2); printf "%s%s", sep, $2; sep = ","}')
  assert "T-12 $1 lists the rc rows in the order 0, 1, 2, other" "0,1,2,other" "$rows"
  rc0_line=$(printf '%s\n' "$sec" | grep -E '^\| 0 \|' | head -n 1) || rc0_line=""
  rc1_line=$(printf '%s\n' "$sec" | grep -E '^\| 1 \|' | head -n 1) || rc1_line=""
  if [[ -n "$rc1_line" && "$rc0_line" == *continue* && "$rc1_line" != *continue* ]]; then
    pass "T-12 $1 continues on rc=0 and not on rc=1"
  else
    fail "T-12 $1 continues on rc=0 and not on rc=1 (rc=0: '$rc0_line'; rc=1: '$rc1_line')"
  fi
  if [[ "$rc0_line" != *"If rc=1"* && "$rc1_line" != *"If rc=0"* ]]; then
    pass "T-12 $1 table rows point to their own rc paragraph"
  else
    fail "T-12 $1 table rows point to their own rc paragraph (rc=0: '$rc0_line'; rc=1: '$rc1_line')"
  fi
  # 段落の境界は行頭の見出しだけで決める（表の行も "If rc=1" を含むため）
  rc1_para=$(printf '%s\n' "$sec" | awk '/^\**If rc=/ {f = /^\**If rc=1/; next} f')
  case "$rc1_para" in
    *"$4"*) pass "T-12 $1 shows the not-initialized message under If rc=1" ;;
    *) fail "T-12 $1 shows the not-initialized message under If rc=1" ;;
  esac
  rc0_para=$(printf '%s\n' "$sec" | awk '/^\**If rc=/ {f = /^\**If rc=0/; next} f')
  case "$rc0_para" in
    *"$4"*) fail "T-12 $1 does not show the not-initialized message under If rc=0" ;;
    *) pass "T-12 $1 does not show the not-initialized message under If rc=0" ;;
  esac
  if [ "$6" = "-" ]; then
    # If rc=0 段落が無いので、0 行が下にある内容を指すだけで rc=0 に案内が混ざる
    if grep -Eiq 'show|display|below|message' <<< "$rc0_line"; then
      fail "T-12 $1 rc=0 row does not point to content below (line: '$rc0_line')"
    else
      pass "T-12 $1 rc=0 row does not point to content below"
    fi
  else
    case "$rc0_para" in
      *"$6"*) pass "T-12 $1 shows the found message under If rc=0" ;;
      *) fail "T-12 $1 shows the found message under If rc=0" ;;
    esac
    case "$rc1_para" in
      *"$6"*) fail "T-12 $1 does not show the found message under If rc=1" ;;
      *) pass "T-12 $1 does not show the found message under If rc=1" ;;
    esac
  fi
  case "$rc1_line" in
    *stderr*) fail "T-12 $1 does not treat rc=1 as a resolver error (line: '$rc1_line')" ;;
    *) pass "T-12 $1 does not treat rc=1 as a resolver error" ;;
  esac
  # stop 側は停止語があり、続行語 continue も停止の否定形も無いときだけ停止とみなす
  rc1_text=$(printf '%s\n%s\n' "$rc1_line" "$rc1_para")
  stop_n=$(printf '%s\n' "$rc1_text" | grep -ci 'stop' || true)
  cont_n=$(printf '%s\n' "$rc1_text" | grep -ci 'continue' || true)
  neg_n=$(count_negated_stop "$rc1_text")
  if { [ "$5" = stop ] && [ "$stop_n" -gt 0 ] && [ "$cont_n" -eq 0 ] && [ "$neg_n" -eq 0 ]; } \
     || { [ "$5" = guide ] && [ "$stop_n" -eq 0 ]; }; then
    pass "T-12 $1 rc=1 stop behavior is '$5'"
  else
    fail "T-12 $1 rc=1 stop behavior is '$5' (stop=$stop_n; continue=$cont_n; negated=$neg_n)"
  fi
  if grep -nE '(ls( -la)?|cp) rite-config\.yml' "$skill_md"; then
    fail "T-12 $1 does not list or copy rite-config.yml relative to the cwd"
  else
    pass "T-12 $1 does not list or copy rite-config.yml relative to the cwd"
  fi
}
check_init_section workflow '### 1.1 Check Initialization Status' '### 1.2' '初期化されていません' stop -
check_init_section getting-started '### 3.2 Step 1: Initial Setup' '### 3.3' 'Action Required' guide 'Already initialized'
check_init_section template-reset '### 1.1 Read rite-config.yml' '## Phase 2' '見つかりません' stop -
if _gq_out=$(awk '/^## Language Support/ {f = 1} f' "$PLUGIN_ROOT/skills/workflow/SKILL.md") && grep -qF '{rite_config_path}' <<< "$_gq_out"; then
  pass "T-12 workflow reads language from the resolved path"
else
  fail "T-12 workflow reads language from the resolved path"
fi
reset_md="$PLUGIN_ROOT/skills/template-reset/SKILL.md"
# 再生成はバックアップの後に同じパスへ書く。上書きしてから退避する順序も落とす
reset_regen=$(awk 'index($0, "### 3.3 Regenerate Configuration File") == 1 {f = 1; next} f && index($0, "## Phase 4") == 1 {exit} f' "$reset_md")
backup_at=$(printf '%s\n' "$reset_regen" | grep -nF 'cp "{rite_config_path}" "{rite_config_path}.backup.' | head -n 1 | cut -d: -f1) || backup_at=""
write_at=$(printf '%s\n' "$reset_regen" | grep -nF 'write it to `{rite_config_path}`' | head -n 1 | cut -d: -f1) || write_at=""
reset_missing=""
grep -qF 'ls -la "{rite_config_path}"' "$reset_md" || reset_missing="$reset_missing ls"
[[ -n "$backup_at" ]] || reset_missing="$reset_missing backup"
[[ -n "$write_at" ]] || reset_missing="$reset_missing write"
if [[ -z "$reset_missing" && "$backup_at" -ge "$write_at" ]]; then
  reset_missing=" backup-before-write"
fi
if [[ -z "$reset_missing" ]]; then
  pass "T-12 template-reset detects, backs up and regenerates the resolved path"
else
  fail "T-12 template-reset detects, backs up and regenerates the resolved path (missing:$reset_missing)"
fi

print_summary "$(basename "$0")" \
  "Drift hint: rite-config-path.sh — worktree toplevel first, then main checkout root; rc=1 lists tried paths, rc=2 never falls through."
