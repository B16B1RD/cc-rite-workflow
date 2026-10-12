#!/usr/bin/env bash
# Tests for grep-count-fallback-check.sh
set -uo pipefail
CHECK="$(cd "$(dirname "$0")/../scripts" && pwd)/grep-count-fallback-check.sh"
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
fails=0
ok() { echo "PASS: $1"; }
ng() { echo "FAIL: $1"; fails=$((fails + 1)); }

mk() { mkdir -p "$TMP/$1/plugins/rite/skills"; }
run() { bash "$CHECK" --all --repo-root "$TMP/$1" >"$TMP/out" 2>"$TMP/err"; echo $?; }

# Fixtures are assembled from parts so this file does not match its own checker.
FB="|| echo"
mk bad; {
  echo '```bash'
  echo "n=\$(printf '%s' \"\$x\" | grep -c . 2>/dev/null $FB 0)"
  echo "m=\$(grep -cE 'a|b' f $FB \"0\")"
  echo '```'
} > "$TMP/bad/plugins/rite/skills/a.md"
[ "$(run bad)" = 1 ] && ok "flags -c / -cE with || echo 0" || ng "flags -c / -cE with || echo 0"
[ "$(grep -c 'grep-count-fallback' "$TMP/out")" = 2 ] && ok "two findings reported" || ng "two findings reported"

mk good; {
  echo '```bash'
  echo 'n=$(printf "%s" "$x" | grep -c . 2>/dev/null || true); n=${n:-0}'
  echo "# n=\$(grep -c . f $FB 0)  <- comment describing the defect"
  echo "x=\$(grep -q foo f $FB 0)"
  echo '```'
  echo "| trap | \`grep -c . f $FB 0\` |"
} > "$TMP/good/plugins/rite/skills/a.md"
[ "$(run good)" = 0 ] && ok "clean forms, comments and table rows pass" || ng "clean forms, comments and table rows pass"

mkdir -p "$TMP/none"
[ "$(bash "$CHECK" --all --repo-root "$TMP/none" --skip-if-no-target >/dev/null 2>&1; echo $?)" = 0 ] && ok "skip-if-no-target exits 0" || ng "skip-if-no-target exits 0"
[ "$(bash "$CHECK" --all --repo-root "$TMP/none" >/dev/null 2>&1; echo $?)" = 2 ] && ok "missing scan dir exits 2" || ng "missing scan dir exits 2"

[ "$fails" -eq 0 ] || exit 1
