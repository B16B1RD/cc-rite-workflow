#!/bin/bash
# Tests for hooks/scripts/comment-line-ref-check.sh
#
# The checker flags hardcoded `<file>.<ext>:<NN>` line-number references that
# live inside shell comments (these rot when the referenced file changes).
# These tests pin both the positive detection and the exclusions the checker
# deliberately makes (shebang, range `:N-M`, `# example:` whitelist, code
# lines) so a future regex tweak cannot silently widen or narrow the scope.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable. Targets are
# resolved under --repo-root, so no git repo is needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/comment-line-ref-check.sh"

echo "=== comment-line-ref-check.sh tests ==="

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

# --- Fixtures (paths relative to --repo-root sandbox) -------------------------
# NG: a filename:NN reference inside a shell comment.
printf '#!/bin/bash\n# see wiki-config.sh:42 for the check\necho hi\n' \
  > "$SANDBOX/ng.sh"
# Clean: same filename but no :NN line number.
printf '#!/bin/bash\n# see wiki-config.sh for the check\necho hi\n' \
  > "$SANDBOX/clean.sh"
# Excluded: range form :N-M (review-finding location, not a fragile line ref).
printf '#!/bin/bash\n# Location: foo.sh:12-20\n' \
  > "$SANDBOX/range.sh"
# Excluded: `# example:` whitelist marker.
printf '#!/bin/bash\n# example: foo.sh:42\n' \
  > "$SANDBOX/example.sh"
# Excluded: a code line (not a comment) referencing a file legitimately.
printf '#!/bin/bash\ngrep -n pattern wiki-config.sh:42 || true\n' \
  > "$SANDBOX/codeline.sh"

run() { bash "$SCRIPT" --repo-root "$SANDBOX" "$@" >/dev/null 2>&1; echo $?; }

# --- Invocation contract ------------------------------------------------------
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
assert "no targets exits 2 (invocation error)" "2" "$(run --quiet)"
assert "unknown argument exits 2" "2" "$(run --bogus)"

# --- Positive detection -------------------------------------------------------
assert "comment line-number ref detected (exit 1)" "1" "$(run --quiet --target ng.sh)"

# --- Exclusions (must stay clean, exit 0) -------------------------------------
assert "no line number is clean" "0" "$(run --quiet --target clean.sh)"
assert "range form :N-M is excluded" "0" "$(run --quiet --target range.sh)"
assert "# example: whitelist is excluded" "0" "$(run --quiet --target example.sh)"
assert "code line (non-comment) is excluded" "0" "$(run --quiet --target codeline.sh)"

# --- Finding output shape -----------------------------------------------------
ng_out="$(bash "$SCRIPT" --repo-root "$SANDBOX" --quiet --target ng.sh 2>/dev/null || true)"
if printf '%s' "$ng_out" | grep -qF '[comment-line-ref]' && printf '%s' "$ng_out" | grep -qF 'wiki-config.sh:42'; then
  pass "finding tags [comment-line-ref] and quotes the offending reference"
else
  fail "finding tag/reference missing: $ng_out"
fi

print_summary "comment-line-ref-check.sh"
