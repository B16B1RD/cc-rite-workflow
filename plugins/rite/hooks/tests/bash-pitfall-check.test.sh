#!/bin/bash
# Tests for hooks/scripts/bash-pitfall-check.sh
#
# Per rule: a known-bad form is a finding (negative case), the corrected form is not
# (normal case). Plus the scan-boundary and invocation contracts. Fixtures are assembled
# at runtime so this file does not carry the bad forms it tests.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/bash-pitfall-check.sh"

echo "=== bash-pitfall-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOX="$(make_plain_sandbox)"
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

HS="$SANDBOX/plugins/rite/hooks/scripts"
mkdir -p "$HS" "$SANDBOX/plugins/rite/hooks/tests" "$SANDBOX/plugins/rite/skills/demo"

G=grep; S=sed; M=mktemp; PS=PIPESTATUS
# fixture <name> <line...>: one .sh file under hooks/scripts, one line per argument
fixture() { local name="$1"; shift; printf '%s\n' '#!/usr/bin/env bash' "$@" > "$HS/$name.sh"; }
run() { bash "$SCRIPT" --repo-root "$SANDBOX" "$@" >/dev/null 2>&1; echo $?; }
out() { bash "$SCRIPT" --repo-root "$SANDBOX" --quiet "$@" 2>/dev/null; }

check() { # check <label> <fixture-name> <expected-rc> <rule-or-empty>
  assert "$1 (exit $3)" "$3" "$(run --quiet --target "plugins/rite/hooks/scripts/$2.sh")"
  if [ -n "$4" ]; then
    local o; o="$(out --target "plugins/rite/hooks/scripts/$2.sh")"
    if [ "$3" = 1 ] && [[ "$o" == *"$4"* ]]; then pass "$1: tagged $4"
    elif [ "$3" = 1 ]; then fail "$1: rule tag $4 missing — got: $o"; fi
  fi
}

# --- grep-c-echo-fallback ----------------------------------------------------
fixture gc-ng "n=\$($G -c x f || echo 0)"
fixture gc-ng-flags "n=\$($G -cE 'a|b' f || printf 0)"
fixture gc-ok-outside "n=\$($G -c x f) || n=0"
fixture gc-ok-true "n=\$($G -c x f || true)"
check "grep -c with echo fallback inside substitution" gc-ng 1 grep-c-echo-fallback
check "grep -c with printf fallback and pipe in pattern" gc-ng-flags 1 grep-c-echo-fallback
check "fallback outside the substitution" gc-ok-outside 0 ""
check "|| true inside the substitution" gc-ok-true 0 ""

# --- if-bang-rc ---------------------------------------------------------------
fixture bang-ng 'if ! cmd; then' '  rc=$?' '  echo "failed rc=$rc"' 'fi'
fixture bang-ng-oneline 'if ! cmd; then rc=$?; fi'
fixture bang-ok-else 'rc=0' 'if cmd; then' '  :' 'else' '  rc=$?' 'fi'
fixture bang-ok-or 'rc=0' 'cmd || rc=$?' 'if [ "$rc" -ne 0 ]; then' '  echo "rc=$rc"' 'fi'
fixture bang-ok-no-status 'if ! cmd; then' '  echo "failed" >&2' '  exit 1' 'fi' 'x=$?'
check "\$? in the then-body of if !" bang-ng 1 if-bang-rc
fixture bang-ng-comment 'if ! cmd; then' '  # capture the status' '  rc=$?' 'fi'
fixture bang-ng-then-line 'if ! cmd' 'then' '  rc=$?' 'fi'
fixture bang-ok-other-first 'if ! cmd; then' '  other' '  rc=$?' 'fi'
check "comment line between then and \$? does not disarm" bang-ng-comment 1 if-bang-rc
check "then on its own line" bang-ng-then-line 1 if-bang-rc
check "\$? after another command belongs to that command" bang-ok-other-first 0 ""
fixture bang-ok-oneline-other 'if ! cmd; then other; rc=$?; fi'
check "one-line then with another command first" bang-ok-oneline-other 0 ""
check "\$? on the same line as if ! ... then" bang-ng-oneline 1 if-bang-rc
check "status read in the else branch of a positive if" bang-ok-else 0 ""
check "status captured with || rc=\$?" bang-ok-or 0 ""
check "if ! without reading \$? (status read after fi is out of scope)" bang-ok-no-status 0 ""

# --- nested-mktemp-cd ---------------------------------------------------------
fixture cd-ng "d=\$(cd \"\$($M -d)\" && pwd -P)"
fixture cd-ok "d=\$($M -d) || exit 1" 'cd "$d" || exit 1'
check "mktemp nested in cd" cd-ng 1 nested-mktemp-cd
check "mktemp and cd in separate steps" cd-ok 0 ""

# --- sed-inplace-gnu ----------------------------------------------------------
fixture sed-ng "$S -i 's/a/b/' f"
fixture sed-ng-flag "$S -E -i 's/a/b/' f"
fixture sed-ok-suffix "$S -i.bak 's/a/b/' f"
fixture sed-ng-empty "$S -i '' 's/a/b/' f"
fixture sed-ok-stdout "$S 's/a/b/' f > g"
check "sed -i with an expression directly after" sed-ng 1 sed-inplace-gnu
check "sed -E -i with an expression directly after" sed-ng-flag 1 sed-inplace-gnu
check "sed -i.bak" sed-ok-suffix 0 ""
check "sed -i with an empty-string argument (BSD-only form)" sed-ng-empty 1 sed-inplace-gnu
check "sed without -i" sed-ok-stdout 0 ""

# --- pipestatus-subst ---------------------------------------------------------
fixture ps-ng 'v=$(a | b)' "[ \"\${${PS}[0]}\" -eq 0 ]"
fixture ps-ng-sameline "v=\$(a | b); [ \"\${${PS}[0]}\" -eq 0 ]"
fixture ps-ok-ownpipe 'v=$(a | b)' "x | y; [ \"\${${PS}[0]}\" -eq 0 ]"
fixture ps-ok 'a | b' "[ \"\${${PS}[0]}\" -eq 0 ]"
check "PIPESTATUS read after a pipeline inside \$( )" ps-ng 1 pipestatus-subst
check "PIPESTATUS read on the same line after \$( )" ps-ng-sameline 1 pipestatus-subst
check "PIPESTATUS read after a plain pipeline" ps-ok 0 ""
check "PIPESTATUS of the next line's own pipeline" ps-ok-ownpipe 0 ""

# --- exclusions ---------------------------------------------------------------
fixture ign-above "# drift-check-ignore: reviewed" "n=\$($G -c x f || echo 0)"
fixture ign-sameline "n=\$($G -c x f || echo 0) # drift-check-ignore"
check "drift-check-ignore on the same line" ign-sameline 0 ""
fixture ign-comment "# n=\$($G -c x f || echo 0)"
check "drift-check-ignore on the line above" ign-above 0 ""
check "comment lines are skipped" ign-comment 0 ""

# Byte-identical bad line on each side of the tests/ boundary: only the pair shows exclusion.
bad="n=\$($G -c x f || echo 0)"
rm -f "$HS"/*.sh   # earlier fixtures would make the --all probes below vacuous
printf '%s\n%s\n' '#!/usr/bin/env bash' "$bad" > "$SANDBOX/plugins/rite/hooks/tests/probe.sh"
printf '%s\n%s\n' '#!/usr/bin/env bash' "$bad" > "$HS/probe.sh"
assert "probe under hooks/scripts is a finding via --all (exit 1)" "1" "$(run --quiet --all)"
rm -f "$HS/probe.sh"
assert "same line under hooks/tests is not scanned via --all (exit 0)" "0" "$(run --quiet --all)"
rm -f "$SANDBOX/plugins/rite/hooks/tests/probe.sh"

# --- markdown: only fenced code counts, with the original line number -----------
printf 'Prose: %s\n\n```bash\nok=1\n%s\n```\n' "$bad" "$bad" > "$SANDBOX/plugins/rite/skills/demo/ref.md"
assert "bad form in a fence is a finding (exit 1)" "1" "$(run --quiet --target plugins/rite/skills/demo/ref.md)"
md_out="$(out --target plugins/rite/skills/demo/ref.md)"
if [[ "$md_out" == *"ref.md:5:"* && "$md_out" != *"ref.md:1:"* ]]; then
  pass "reported line is the fenced line (5), not the prose mention (1)"
else
  fail "wrong line attribution — got: $md_out"
fi
# fences in a list item (4+ columns of indent), tilde fences, an sh info string, two blocks, a colon in the path
printf -- '- step\n\n    ```sh\n    %s\n    ```\n' "$bad" > "$SANDBOX/plugins/rite/skills/demo/list.md"
assert "bad form in an indented list fence is a finding (exit 1)" "1" "$(run --quiet --target plugins/rite/skills/demo/list.md)"
printf '~~~bash\n%s\n~~~\n' "$bad" > "$SANDBOX/plugins/rite/skills/demo/tilde.md"
assert "bad form in a tilde fence is a finding (exit 1)" "1" "$(run --quiet --target plugins/rite/skills/demo/tilde.md)"
printf '```bash\nok=1\n```\n\ntext\n\n```bash\nok=2\n%s\n```\n' "$bad" > "$SANDBOX/plugins/rite/skills/demo/two.md"
two_out="$(out --target plugins/rite/skills/demo/two.md)"
[[ "$two_out" == *"two.md:9:"* ]] && pass "line number of the second block is its file line (9)" || fail "wrong line in second block — got: $two_out"
printf '```bash\n%s\n```\n' "$bad" > "$SANDBOX/plugins/rite/skills/demo/a:b.md"
assert "path containing a colon is scanned without a crash (exit 1)" "1" "$(run --quiet --target plugins/rite/skills/demo/a:b.md)"
# an indented fence-looking line inside a top-level block (4+ columns deeper) does not close it; one with an info string does not either
printf '```bash\nawk %s\n    ```\n%s\n```\n' "'" "$bad" > "$SANDBOX/plugins/rite/skills/demo/deep-literal.md"
assert "indented fence literal does not close the block (exit 1)" "1" "$(run --quiet --target plugins/rite/skills/demo/deep-literal.md)"
printf '```bash\n```json\n%s\n```\n' "$bad" > "$SANDBOX/plugins/rite/skills/demo/inner-info.md"
assert "inner fence with an info string does not close the block (exit 1)" "1" "$(run --quiet --target plugins/rite/skills/demo/inner-info.md)"
printf 'x\n' > "$SANDBOX/plugins/rite/skills/demo/other.bash"
assert "unsupported file type exits 2" "2" "$(run --quiet --target plugins/rite/skills/demo/other.bash)"
printf '```bash\n%s\n' "$bad" > "$SANDBOX/plugins/rite/skills/demo/unbalanced.md"
assert "unbalanced fence exits 2 (not scanned != clean)" "2" \
  "$(run --quiet --target plugins/rite/skills/demo/unbalanced.md)"

# --- invocation contract --------------------------------------------------------
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
assert "no targets exits 2" "2" "$(run --quiet)"
assert "unknown argument exits 2" "2" "$(run --bogus)"
assert "missing --target exits 2" "2" "$(run --quiet --target plugins/rite/hooks/scripts/none.sh)"
if [ "$(id -u)" -eq 0 ]; then
  skip "unlistable directory exits 2 (running as root: chmod 000 does not deny access)"
else
  LOCKED="$(make_plain_sandbox)"
  mkdir -p "$LOCKED/plugins/rite/hooks/locked" "$LOCKED/plugins/rite/scripts"; chmod 000 "$LOCKED/plugins/rite/hooks/locked"
  assert "unlistable directory exits 2 (not scanned != clean)" "2" \
    "$(bash "$SCRIPT" --repo-root "$LOCKED" --quiet --all >/dev/null 2>&1; echo $?)"
  chmod 755 "$LOCKED/plugins/rite/hooks/locked"; rm -rf "$LOCKED"
fi
EMPTY="$(make_plain_sandbox)"
assert "--all without plugins/rite exits 2" "2" "$(bash "$SCRIPT" --repo-root "$EMPTY" --quiet --all >/dev/null 2>&1; echo $?)"
assert "--all --skip-if-no-target without plugins/rite exits 0" "0" \
  "$(bash "$SCRIPT" --repo-root "$EMPTY" --quiet --all --skip-if-no-target >/dev/null 2>&1; echo $?)"
rm -rf "$EMPTY"

# --- the real tree is clean ----------------------------------------------------
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
assert "plugins/rite scans clean (exit 0)" "0" \
  "$(bash "$SCRIPT" --repo-root "$REPO_ROOT" --quiet --all >/dev/null 2>&1; echo $?)"

if ! print_summary "bash-pitfall-check.test.sh" "Check hooks/scripts/bash-pitfall-check.sh rules and fixtures"; then
  exit 1
fi
