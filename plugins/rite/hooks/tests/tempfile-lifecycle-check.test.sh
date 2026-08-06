#!/bin/bash
# Tests for hooks/scripts/tempfile-lifecycle-check.sh (Issue #2117)
#
# The checker is only worth having if it stays quiet on the shapes this repo
# writes on purpose, so the boundaries matter more than the detections:
#   - a derived mktemp path and a stream-headed `grep -q` are findings,
#   - a printf/echo-headed `grep -q` is not (15 of 16 call sites are that shape;
#     flagging them would bury the one real finding),
#   - the same pipeline in a file without pipefail is not,
#   - code that goes through the tempfile lib is not,
#   - and a drift-check-ignore marker suppresses either pattern.
# Plus the real-repository corpus: the tree must be clean, or the check ships
# already-noisy and gets ignored.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable. The checker
# resolves targets under --repo-root, so no git repo is needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/tempfile-lifecycle-check.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

echo "=== tempfile-lifecycle-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOX="$(make_plain_sandbox)"
# Stands in for a consumer repo that installs rite from the marketplace and has
# no plugins/rite tree of its own.
CONSUMER_SANDBOX="$(make_plain_sandbox)"
cleanup() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  [ -n "${CONSUMER_SANDBOX:-}" ] && rm -rf "$CONSUMER_SANDBOX"
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

FIXTURES="$SANDBOX/plugins/rite/hooks/scripts"
mkdir -p "$FIXTURES"
OUT="$SANDBOX/out.txt"

# Run the checker over one fixture and leave its stdout in $OUT. Echoes the exit code.
run_on() {
  bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target "plugins/rite/hooks/scripts/$1" >"$OUT" 2>"$SANDBOX/err.txt"
  echo $?
}

# --- T-03: both patterns are detected ---------------------------------------
cat > "$FIXTURES/bad.sh" <<'FIX'
#!/bin/bash
set -uo pipefail
FINDINGS_FILE="$(mktemp)"
PART_FILE="$FINDINGS_FILE.part"
awk '{print}' input > "$PART_FILE"
if git log --oneline | grep -q "marker"; then
  echo hit
fi
FIX
rc=$(run_on bad.sh)
assert "T-03 a fixture with both patterns exits 1" "1" "$rc"
assert_grep "T-03 mktemp-derived-path is reported with its line" "$OUT" \
  'bad\.sh:4: mktemp-derived-path'
assert_grep "T-03 pipefail-grep-q-stream names the producer" "$OUT" \
  'bad\.sh:6: pipefail-grep-q-stream .*`git`'
assert_grep "T-03 the total line is machine-readable" "$OUT" \
  '==> Total tempfile-lifecycle findings: 2'

# The derived forms the Wiki page enumerates, each on its own line.
cat > "$FIXTURES/derived-forms.sh" <<'FIX'
#!/bin/bash
tmp=$(mktemp)
cp src "${tmp}.orig"
sort "$tmp" > "${tmp%.tmp}.sorted"
FIX
rc=$(run_on derived-forms.sh)
assert "T-03b brace and prefix-strip derived forms are both detected" "1" "$rc"
assert_grep "T-03b \${tmp}.orig is a finding" "$OUT" 'derived-forms\.sh:3: mktemp-derived-path'
assert_grep "T-03b \${tmp%...} is a finding" "$OUT" 'derived-forms\.sh:4: mktemp-derived-path'

# A backslash-continued pipeline must not hide its consumer from the scan.
cat > "$FIXTURES/continued.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
gh api "repos/o/r/issues" \
  | jq -r '.[].number' \
  | grep -q "^42$"
FIX
rc=$(run_on continued.sh)
assert "T-03c a continued pipeline is joined before scanning" "1" "$rc"
assert_grep "T-03c the finding anchors to the first physical line" "$OUT" \
  'continued\.sh:3: pipefail-grep-q-stream'

# --- T-04: the shapes that must stay quiet ----------------------------------
cat > "$FIXTURES/printf-head.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
if printf '%s\n' "$haystack" | grep -qxF -- "$needle"; then
  echo found
fi
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qE ':[0-9]+:'; then
  echo found
fi
printf '%s\n' "$body" | head -20 | grep -qE '^ingested:' || true
FIX
rc=$(run_on printf-head.sh)
assert "T-04 printf-headed pipelines are not flagged" "0" "$rc"

cat > "$FIXTURES/no-pipefail.sh" <<'FIX'
#!/bin/bash
set -u
if git log --oneline | grep -q "marker"; then
  echo hit
fi
FIX
rc=$(run_on no-pipefail.sh)
assert "T-04b the same pipeline without pipefail is not flagged" "0" "$rc"

cat > "$FIXTURES/marker.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
tmp=$(mktemp)
cp src "$tmp.orig"   # drift-check-ignore
# drift-check-ignore
if git log --oneline | grep -q "marker"; then
  echo hit
fi
FIX
rc=$(run_on marker.sh)
assert "T-04c drift-check-ignore suppresses both on-line and line-above" "0" "$rc"

cat > "$FIXTURES/lib-user.sh" <<'FIX'
#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/tempfile.sh"
rite_tempfile_init
rite_tempfile_new findings "check-findings" || exit 2
rite_tempfile_new part "check-part" || exit 2
awk '{print}' input > "$part"
cat "$part" >> "$findings"
FIX
rc=$(run_on lib-user.sh)
assert "T-04d code that takes both handles from the lib is not flagged" "0" "$rc"

# `x=$(mktemp 2>/dev/null) || x=""` is the sanctioned stderr-slot idiom at 88
# sites in this repo; a warning there would be noise, so it is out of contract.
cat > "$FIXTURES/silenced-idiom.sh" <<'FIX'
#!/bin/bash
set -uo pipefail
jq_err=$(mktemp 2>/dev/null) || jq_err=""
jq . input 2>"${jq_err:-/dev/null}"
FIX
rc=$(run_on silenced-idiom.sh)
assert "T-04e the silenced stderr-slot idiom is deliberately out of contract" "0" "$rc"

# --- Real repository corpus: the check must ship clean ----------------------
real_rc=$(bash "$SCRIPT" --repo-root "$REPO_ROOT" --quiet --all --skip-if-no-target >"$SANDBOX/real.txt" 2>&1; echo $?)
if [ "$real_rc" -ne 0 ]; then
  fail "real repo tree has findings — the check would ship already-noisy:"
  cat "$SANDBOX/real.txt"
else
  pass "real repo hooks/ and scripts/ trees are clean (exit 0)"
fi
assert_grep "real repo run still emits the count line under --quiet" "$SANDBOX/real.txt" \
  '==> Total tempfile-lifecycle findings: 0'

# --- CLI contract ------------------------------------------------------------
assert "--all without a scan dir exits 2 by default" "2" \
  "$(bash "$SCRIPT" --repo-root "$CONSUMER_SANDBOX" --quiet --all >/dev/null 2>&1; echo $?)"
assert "--skip-if-no-target turns that into a clean skip" "0" \
  "$(bash "$SCRIPT" --repo-root "$CONSUMER_SANDBOX" --quiet --all --skip-if-no-target >/dev/null 2>&1; echo $?)"
assert "an unknown argument exits 2" "2" \
  "$(bash "$SCRIPT" --repo-root "$SANDBOX" --nope >/dev/null 2>&1; echo $?)"
assert "no targets at all exits 2" "2" \
  "$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet >/dev/null 2>&1; echo $?)"

print_summary "$(basename "$0")"
