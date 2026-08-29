#!/usr/bin/env bash
# Issue #2431: setup Phase 4.6 shrink, --upgrade migrate, health-check 3-line SoT.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
source "$SCRIPT_DIR/../gitignore-ensure.sh"
source "$SCRIPT_DIR/../relocated-state-migrate.sh"

HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$HOOKS_DIR/.." && pwd)"
GHC="$HOOKS_DIR/scripts/gitignore-health-check.sh"
SETUP="$PLUGIN_ROOT/skills/setup/SKILL.md"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

rite_runtime_in_root() {
  local gi="$1"
  grep -E '^(\.rite/sessions/|\.rite/worktrees/|\.rite/review-results/|\.rite/state/|\.rite-work-memory/|\.rite-initialized-version|\.rite-settings-hooks-cleaned)$' "$gi" || true
}

echo "=== T-01 AC-1: Phase 4.6 generation does not add rite runtime lines to root .gitignore ==="
d01=$(make_sandbox)
cleanup_dirs+=("$d01")
printf 'node_modules/\n' > "$d01/.gitignore"
mkdir -p "$d01/.rite/work-memory"
chmod 700 "$d01/.rite/work-memory" 2>/dev/null || true
_ensure_rite_nested_gitignore "$d01/.rite"
assert "T-01 no rite runtime entries in root gitignore" "" "$(rite_runtime_in_root "$d01/.gitignore")"
assert "T-01 user root line preserved" "node_modules/" "$(cat "$d01/.gitignore")"
_rite_nested_gitignore_expected > "$d01/expected-nested"
cmp -s "$d01/.rite/.gitignore" "$d01/expected-nested"
assert "T-01 nested gitignore matches helper expected (order + newline)" "0" "$?"
[ ! -d "$d01/.rite-work-memory" ]
assert "T-01 does not create legacy .rite-work-memory" "0" "$?"
[ ! -e "$d01/.rite-initialized-version" ]
assert "T-01 no root .rite-initialized-version" "0" "$?"
[ ! -e "$d01/.rite-settings-hooks-cleaned" ]
assert "T-01 no root .rite-settings-hooks-cleaned" "0" "$?"

echo "=== T-02 AC-2: migrate moves all 6 pairs; dest existing is non-destructive ==="
d02=$(make_sandbox)
cleanup_dirs+=("$d02")
printf 'pr' > "$d02/.rite-plugin-root"
printf 'sid' > "$d02/.rite-session-id"
printf 'ver' > "$d02/.rite-initialized-version"
printf 'cln' > "$d02/.rite-settings-hooks-cleaned"
printf 'log' > "$d02/.rite-flow-debug.log"
mkdir -p "$d02/.rite-work-memory"
printf 'wm' > "$d02/.rite-work-memory/issue-1.md"
_rite_run_relocated_state_migrate "$d02"
assert "T-02 plugin-root dest" "pr" "$(cat "$d02/.rite/plugin-root")"
assert "T-02 session-id dest" "sid" "$(cat "$d02/.rite/session-id")"
assert "T-02 initialized-version dest" "ver" "$(cat "$d02/.rite/initialized-version")"
assert "T-02 settings-hooks-cleaned dest" "cln" "$(cat "$d02/.rite/settings-hooks-cleaned")"
assert "T-02 flow-debug dest" "log" "$(cat "$d02/.rite/logs/flow-debug.log")"
assert "T-02 work-memory dest" "wm" "$(cat "$d02/.rite/work-memory/issue-1.md")"
[ ! -e "$d02/.rite-plugin-root" ] && [ ! -e "$d02/.rite-session-id" ] \
  && [ ! -e "$d02/.rite-initialized-version" ] && [ ! -e "$d02/.rite-settings-hooks-cleaned" ] \
  && [ ! -e "$d02/.rite-flow-debug.log" ] && [ ! -e "$d02/.rite-work-memory" ]
assert "T-02 all six src paths gone" "0" "$?"

d02b=$(make_sandbox)
cleanup_dirs+=("$d02b")
mkdir -p "$d02b/.rite"
printf 'KEEP' > "$d02b/.rite/plugin-root"
printf 'OLD' > "$d02b/.rite-plugin-root"
_rite_run_relocated_state_migrate "$d02b"
assert "T-02 dest existing is not clobbered" "KEEP" "$(cat "$d02b/.rite/plugin-root")"
assert "T-02 dest existing leaves src" "OLD" "$(cat "$d02b/.rite-plugin-root")"

echo "=== T-03 AC-3: second migrate is no-op ==="
d03=$(make_sandbox)
cleanup_dirs+=("$d03")
printf 'x' > "$d03/.rite-session-id"
_rite_run_relocated_state_migrate "$d03"
_rite_run_relocated_state_migrate "$d03"
assert "T-03 dest still x after second run" "x" "$(cat "$d03/.rite/session-id")"
[ ! -e "$d03/.rite-session-id" ]
assert "T-03 src still absent after second run" "0" "$?"

echo "=== T-04 AC-4: wiki-enabled fixture with nested 3-line → findings 0 ==="
d04=$(make_sandbox)
cleanup_dirs+=("$d04")
printf 'wiki:\n  enabled: true\n  branch_strategy: separate_branch\n' > "$d04/rite-config.yml"
printf '\n' > "$d04/.gitignore"
mkdir -p "$d04/.rite"
_rite_nested_gitignore_expected > "$d04/.rite/.gitignore"
T04_RC=0
T04_OUT=$(cd "$d04" && bash "$GHC" --quiet 2>&1) || T04_RC=$?
assert "T-04 health-check exit 0" "0" "$T04_RC"
case "$T04_OUT" in
  *"Total gitignore-health-check findings: 0"*) pass "T-04 findings 0" ;;
  *) fail "T-04 expected findings 0, got: $T04_OUT" ;;
esac
case "$T04_OUT" in
  *"DRIFT DETECTED (separate_branch)"*) fail "T-04 must not report .rite/wiki/ DRIFT" ;;
  *) pass "T-04 no separate_branch wiki DRIFT" ;;
esac

echo "=== T-05 AC-5: lint-path health-check does not rewrite gitignore files ==="
d05=$(make_sandbox)
cleanup_dirs+=("$d05")
printf 'wiki:\n  enabled: true\n  branch_strategy: separate_branch\n' > "$d05/rite-config.yml"
printf 'keep-root\n' > "$d05/.gitignore"
mkdir -p "$d05/.rite"
_rite_nested_gitignore_expected > "$d05/.rite/.gitignore"
cp "$d05/.gitignore" "$d05/root.before"
cp "$d05/.rite/.gitignore" "$d05/nested.before"
(cd "$d05" && bash "$GHC" --quiet >/dev/null 2>&1) || true
cmp -s "$d05/.gitignore" "$d05/root.before"
assert "T-05 root .gitignore unchanged" "0" "$?"
cmp -s "$d05/.rite/.gitignore" "$d05/nested.before"
assert "T-05 nested .gitignore unchanged" "0" "$?"

echo "=== T-06 AC-6: same_branch + nested 3-line → git add wiki raw succeeds ==="
d06=$(make_sandbox)
cleanup_dirs+=("$d06")
printf 'wiki:\n  enabled: true\n  branch_strategy: same_branch\n' > "$d06/rite-config.yml"
printf '\n' > "$d06/.gitignore"
mkdir -p "$d06/.rite/wiki/raw"
_rite_nested_gitignore_expected > "$d06/.rite/.gitignore"
printf 'page\n' > "$d06/.rite/wiki/raw/page.md"
T06_OUT=$(git -C "$d06" add --dry-run .rite/wiki/raw/page.md 2>&1); T06_RC=$?
assert "T-06 git add --dry-run rc=0" "0" "$T06_RC"
case "$T06_OUT" in
  *"add '.rite/wiki/raw/page.md'"*) pass "T-06 stdout contains add of wiki page" ;;
  *) fail "T-06 stdout missing add (actual='$T06_OUT')" ;;
esac
T06H_RC=0
T06H_OUT=$(cd "$d06" && bash "$GHC" --quiet 2>&1) || T06H_RC=$?
assert "T-06 health-check same_branch exit 0" "0" "$T06H_RC"

echo "=== T-06b: lint path, missing !wiki/** is exit 1 (not --verify-negation) ==="
d06b=$(make_sandbox)
cleanup_dirs+=("$d06b")
printf 'wiki:\n  enabled: true\n  branch_strategy: same_branch\n' > "$d06b/rite-config.yml"
printf '\n' > "$d06b/.gitignore"
mkdir -p "$d06b/.rite"
printf '*\n!wiki/\n' > "$d06b/.rite/.gitignore"
T06B_RC=0
T06B_OUT=$(cd "$d06b" && bash "$GHC" --quiet 2>&1) || T06B_RC=$?
assert "T-06b missing !wiki/** is lint-path exit 1" "1" "$T06B_RC"
case "$T06B_OUT" in
  *"DRIFT DETECTED (nested)"*) pass "T-06b nested composition drift" ;;
  *) fail "T-06b expected nested drift, got: $T06B_OUT" ;;
esac

echo "=== T-07 AC-2: --upgrade path sources helper after Apply, does not inline 6 pairs ==="
assert_grep "T-07 current < latest row includes Step 6.5 after Apply" \
  "$SETUP" 'current < latest.*Step 6 Apply.*Step 6.5 nested gitignore migrate'
assert_grep "T-07 current >= latest row includes Step 6.5 after Apply" \
  "$SETUP" 'current >= latest.*Step 6 Apply.*Step 6.5 nested gitignore migrate'
assert_grep "T-07 Step 6.5 sources relocated-state-migrate.sh" \
  "$SETUP" 'source {plugin_root}/hooks/relocated-state-migrate.sh'
assert_grep "T-07 Step 6.5 calls _rite_run_relocated_state_migrate" \
  "$SETUP" '_rite_run_relocated_state_migrate'
assert_not_grep "T-07 setup SKILL does not inline .rite-plugin-root migrate pair" \
  "$SETUP" '\.rite-plugin-root'
assert_not_grep "T-07 setup Phase 4.6 no longer lists dir_entry runtime dirs" \
  "$SETUP" 'for dir_entry in "\.rite/sessions/"'

print_summary "$(basename "$0")" \
  "setup nested gitignore generation, --upgrade migrate, health-check 3-line SoT (#2431)"
