#!/bin/bash
# Tests for hooks/scripts/dollar-zero-check.sh (Issue #2046)
#
# The checker exists because the Skill loader expands parameter-zero references
# in a skill body to the invocation argument string — including inside fenced
# code blocks. These tests pin the three boundaries that decide whether the
# check is usable at all:
#   - a reference inside a fence is a finding (the defect),
#   - a reference in prose outside every fence is not (explaining the parameter
#     must stay possible — this test file's own header does it),
#   - a real shell script is never scanned (every hooks/*.sh would false-positive).
# Plus the unbalanced-fence contract: skip the file loudly rather than emit
# findings from a block structure that could not be parsed.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable. The checker
# resolves targets under --repo-root, so no git repo is needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/dollar-zero-check.sh"

echo "=== dollar-zero-check.sh tests ==="

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

# The literal is assembled at runtime so the fixtures below carry a real
# parameter-zero reference without this file tripping the check it tests.
DOLLAR='$'
P0="${DOLLAR}0"
P0_BRACE="${DOLLAR}{0}"

mkdir -p "$SANDBOX/plugins/rite/skills/demo" "$SANDBOX/plugins/rite/hooks/scripts"

# --- Fixtures ----------------------------------------------------------------
# Fenced bash carrying the defect: the awk condition breaks when the loader
# rewrites the reference to the invocation arguments.
printf 'Prose line.\n\n```bash\nawk -v k="$key" '\''%s ~ "^" k { print }'\''\n```\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-fenced.md"

# Same defect in brace form — the loader treats both spellings alike.
printf '```bash\necho "%s"\n```\n' "$P0_BRACE" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-brace.md"

# A fence with no info string is just as vulnerable as a bash one; tagging the
# fence differently must not buy an exemption.
printf '```\nprintf "%%s" "%s"\n```\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-untagged.md"

# Prose mention outside any fence — the documented safe way to talk about it.
printf 'The Skill loader expands %s in the body to the invocation arguments.\n\n```bash\necho ok\n```\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/clean-prose.md"

# Indented fence-looking literal inside an awk program: 4+ spaces of indent means
# it is code, not a fence, so the block must stay open and the check must not
# start treating the rest of the file as prose.
printf '```bash\nawk %s\n    if (line ~ /^```json/) next\n%s file\n```\n' "'" "'" \
  > "$SANDBOX/plugins/rite/skills/demo/clean-indented-fence-literal.md"

# Unbalanced fence: opened, never closed.
printf 'Prose.\n\n```bash\necho "%s"\n' "$P0" \
  > "$SANDBOX/plugins/rite/skills/demo/ng-unbalanced.md"

# Real shell script carrying the same idiom — immune, because bash executes the
# file directly and the loader never sees it.
printf '#!/usr/bin/env bash\necho "invoked as %s"\n' "$P0" \
  > "$SANDBOX/plugins/rite/hooks/scripts/real-script.sh"

run() { bash "$SCRIPT" --repo-root "$SANDBOX" "$@" >/dev/null 2>&1; echo $?; }

# --- Invocation contract ------------------------------------------------------
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
assert "no targets exits 2 (invocation error)" "2" "$(run --quiet)"
assert "unknown argument exits 2" "2" "$(run --bogus)"

# --- T-04: detection + line number --------------------------------------------
assert "fenced reference detected (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-fenced.md)"
assert "brace form detected (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-brace.md)"
assert "untagged fence detected (exit 1)" "1" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-untagged.md)"

ng_out="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
  --target plugins/rite/skills/demo/ng-fenced.md 2>/dev/null || true)"
if printf '%s' "$ng_out" | grep -qF '[dollar-zero]'; then
  pass "finding is tagged [dollar-zero]"
else
  fail "finding tag missing: $ng_out"
fi
if printf '%s' "$ng_out" | grep -qF 'ng-fenced.md:4:'; then
  pass "finding carries file path and line number"
else
  fail "finding lacks file:line — got: $ng_out"
fi
if printf '%s' "$ng_out" | grep -qF 'helper script'; then
  pass "finding states the fix direction (helper script)"
else
  fail "finding lacks fix direction — got: $ng_out"
fi

# --- T-06: prose outside a fence is not a finding ------------------------------
assert "prose mention outside a fence is clean (exit 0)" "0" \
  "$(run --quiet --target plugins/rite/skills/demo/clean-prose.md)"

# --- Indented fence literal does not desynchronize fence tracking --------------
assert "indented fence-looking literal stays inside the block (exit 0)" "0" \
  "$(run --quiet --target plugins/rite/skills/demo/clean-indented-fence-literal.md)"

# --- T-08: unbalanced fence -> WARNING + skip ---------------------------------
assert "unbalanced fence exits 0 (detection dropped, not guessed)" "0" \
  "$(run --quiet --target plugins/rite/skills/demo/ng-unbalanced.md)"
unbalanced_err="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
  --target plugins/rite/skills/demo/ng-unbalanced.md 2>&1 >/dev/null || true)"
if printf '%s' "$unbalanced_err" | grep -qF 'unbalanced code fence'; then
  pass "unbalanced fence emits a WARNING naming the cause"
else
  fail "unbalanced fence WARNING missing — got: $unbalanced_err"
fi

# --- T-05: real shell scripts are outside the scan set ------------------------
rm -f "$SANDBOX/plugins/rite/skills/demo/ng-fenced.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-brace.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-untagged.md" \
      "$SANDBOX/plugins/rite/skills/demo/ng-unbalanced.md"
assert "--all ignores hooks/**/*.sh carrying the same idiom (exit 0)" "0" "$(run --quiet --all)"

# --- Missing target is reported, not silently passed --------------------------
missing_err="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
  --target plugins/rite/skills/demo/does-not-exist.md 2>&1 >/dev/null || true)"
if printf '%s' "$missing_err" | grep -qF 'target not found'; then
  pass "missing --target is reported as a WARNING"
else
  fail "missing --target produced no WARNING — got: $missing_err"
fi

# --- --skip-if-no-target contract ---------------------------------------------
CONSUMER_SANDBOX="$(make_plain_sandbox)"
assert "--all without a scan dir exits 2 by default" "2" \
  "$(bash "$SCRIPT" --repo-root "$CONSUMER_SANDBOX" --quiet --all >/dev/null 2>&1; echo $?)"
assert "--skip-if-no-target turns that into a clean skip (exit 0)" "0" \
  "$(bash "$SCRIPT" --repo-root "$CONSUMER_SANDBOX" --quiet --all --skip-if-no-target >/dev/null 2>&1; echo $?)"
rm -rf "$CONSUMER_SANDBOX"

print_summary
