#!/bin/bash
# Tests for the three awk programs moved out of skill bodies :
#   hooks/scripts/pr-review-post-comment-read.sh
#   hooks/scripts/review-raw-json-extract.sh
#   hooks/scripts/fix-reason-coverage-check.sh
#
# Two of the three were relocated verbatim, so the value here is pinning the
# contracts their headers now state — particularly the ones a caller reads as a
# guarantee. The third, fix-reason-coverage-check.sh, is not a pure relocation:
# the old inline pipeline always exited 0 and a human read the output, whereas
# this script returns 1 with the undocumented reasons listed. That failure path
# is the whole point of the check and nothing else exercises it.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

POST_COMMENT_READ="$SCRIPT_DIR/../scripts/pr-review-post-comment-read.sh"
RAW_JSON_EXTRACT="$SCRIPT_DIR/../scripts/review-raw-json-extract.sh"
REASON_COVERAGE="$SCRIPT_DIR/../scripts/fix-reason-coverage-check.sh"

echo "=== review extract helpers tests ==="

for s in "$POST_COMMENT_READ" "$RAW_JSON_EXTRACT" "$REASON_COVERAGE"; do
  if [ ! -f "$s" ]; then
    echo "ERROR: $s not found" >&2
    exit 1
  fi
done

SANDBOX="$(make_plain_sandbox)"
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

FENCE='```'

# ---------------------------------------------------------------------------
# pr-review-post-comment-read.sh
# ---------------------------------------------------------------------------

write_config() {
  printf 'pr_review:\n  post_comment: %s\nother:\n  x: 1\n' "$1" > "$SANDBOX/config.yml"
}

write_config 'true'
assert "post_comment: true reads back as true" "true" \
  "$(bash "$POST_COMMENT_READ" "$SANDBOX/config.yml")"

write_config 'false'
assert "post_comment: false reads back as false" "false" \
  "$(bash "$POST_COMMENT_READ" "$SANDBOX/config.yml")"

# The comment boundary is `whitespace + #`, per YAML: a `#` without leading
# whitespace is part of the value, not a comment.
write_config '"True"  # team workflow'
assert "inline comment and quotes are stripped, value lowercased" "true" \
  "$(bash "$POST_COMMENT_READ" "$SANDBOX/config.yml")"

# Key absent is not an error — the caller treats empty as "not configured" and
# falls back to its default. Conflating it with a read failure would turn a
# normal config into a warning on every run.
printf 'pr_review:\n  other_key: 1\n' > "$SANDBOX/config.yml"
assert "absent key yields empty output" "" \
  "$(bash "$POST_COMMENT_READ" "$SANDBOX/config.yml")"
assert "absent key still exits 0" "0" \
  "$(bash "$POST_COMMENT_READ" "$SANDBOX/config.yml" >/dev/null 2>&1; echo $?)"

# A same-named key in another section must not leak in. Both orderings are
# needed, and they exercise different code: with `other:` first, `in_section`
# never becomes true and any implementation returns empty — that case alone
# passes even with the section-exit guard deleted. Only the second ordering,
# where the scan has already entered `pr_review:` and must stop at the next
# top-level key, actually reaches the guard.
printf 'other:\n  post_comment: true\npr_review:\n  x: 1\n' > "$SANDBOX/config.yml"
assert "post_comment in an earlier section is not read" "" \
  "$(bash "$POST_COMMENT_READ" "$SANDBOX/config.yml")"

printf 'pr_review:\n  x: 1\nother:\n  post_comment: true\n' > "$SANDBOX/config.yml"
assert "post_comment in a later section is not read (section-exit guard)" "" \
  "$(bash "$POST_COMMENT_READ" "$SANDBOX/config.yml")"

assert "missing config file exits 2" "2" \
  "$(bash "$POST_COMMENT_READ" "$SANDBOX/nope.yml" >/dev/null 2>&1; echo $?)"
assert "wrong argument count exits 2" "2" \
  "$(bash "$POST_COMMENT_READ" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# review-raw-json-extract.sh
# ---------------------------------------------------------------------------

# Payload only.
{
  printf '## review\n\n---\n\n### 📄 Raw JSON\n\n%sjson\n' "$FENCE"
  printf '{"real":true}\n'
  printf '%s\n' "$FENCE"
} > "$SANDBOX/body-plain.md"
assert "extracts the payload from a well-formed body" '{"real":true}' \
  "$(bash "$RAW_JSON_EXTRACT" < "$SANDBOX/body-plain.md")"

# A heading before the first `---` is outside the considered range entirely.
{
  printf '### 📄 Raw JSON\n\n%sjson\n{"before-separator":true}\n%s\n\n' "$FENCE" "$FENCE"
  printf -- '---\n\n### 📄 Raw JSON\n\n%sjson\n{"real":true}\n%s\n' "$FENCE" "$FENCE"
} > "$SANDBOX/body-pre-separator.md"
assert "a section before the --- separator is ignored" '{"real":true}' \
  "$(bash "$RAW_JSON_EXTRACT" < "$SANDBOX/body-pre-separator.md")"

# The documented protection: a finding quoting the heading ahead of the payload.
{
  printf -- '---\n\n本文が `### 📄 Raw JSON` に言及する\n\n'
  printf '### 📄 Raw JSON\n\n%sjson\n{"quoted":true}\n%s\n\n' "$FENCE" "$FENCE"
  printf '### 📄 Raw JSON\n\n%sjson\n{"real":true}\n%s\n' "$FENCE" "$FENCE"
} > "$SANDBOX/body-quote-first.md"
assert "quotation before the payload does not win" '{"real":true}' \
  "$(bash "$RAW_JSON_EXTRACT" < "$SANDBOX/body-quote-first.md")"

# The limit of that protection, pinned so the header stays honest. A quotation
# *after* the payload does win, because the rule is "last heading". This is the
# behaviour inherited from the skill body, not a regression introduced by the
# extraction — asserting it keeps anyone from reading the header as a guarantee
# that holds in both directions.
{
  printf -- '---\n\n### 📄 Raw JSON\n\n%sjson\n{"real":true}\n%s\n\n' "$FENCE" "$FENCE"
  printf '### 📄 Raw JSON\n\n%sjson\n{"quoted-after":true}\n%s\n' "$FENCE" "$FENCE"
} > "$SANDBOX/body-quote-last.md"
assert "quotation after the payload wins (documented limitation)" '{"quoted-after":true}' \
  "$(bash "$RAW_JSON_EXTRACT" < "$SANDBOX/body-quote-last.md")"

# Legacy comment with no Raw JSON section: empty output and rc=0, so the caller
# can distinguish it from an extraction failure and fall through to its legacy
# Markdown parser.
printf '## review\n\n---\n\n本文のみ\n' > "$SANDBOX/body-legacy.md"
assert "legacy body yields empty output" "" \
  "$(bash "$RAW_JSON_EXTRACT" < "$SANDBOX/body-legacy.md")"
assert "legacy body still exits 0" "0" \
  "$(bash "$RAW_JSON_EXTRACT" < "$SANDBOX/body-legacy.md" >/dev/null 2>&1; echo $?)"

assert "passing an argument exits 2 (stdin-only contract)" "2" \
  "$(bash "$RAW_JSON_EXTRACT" some-file < "$SANDBOX/body-plain.md" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# fix-reason-coverage-check.sh
# ---------------------------------------------------------------------------

REASON_TARGET="plugins/rite/skills/fix/SKILL.md"
mkdir -p "$SANDBOX/plugins/rite/skills/fix"

# Every emitted reason present in the table.
{
  printf 'echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=alpha_failed"\n'
  printf 'echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=beta_failed"\n\n'
  printf '| reason | 発生 Phase | 発生条件 |\n|---|---|---|\n'
  printf '| `alpha_failed` | p1 | cond |\n'
  printf '| `beta_failed` | p2 | cond |\n'
} > "$SANDBOX/$REASON_TARGET"
assert "full coverage exits 0" "0" \
  "$(bash "$REASON_COVERAGE" --repo-root "$SANDBOX" >/dev/null 2>&1; echo $?)"
assert "full coverage prints nothing" "" \
  "$(bash "$REASON_COVERAGE" --repo-root "$SANDBOX" 2>/dev/null)"

# One reason emitted but absent from the table — the case the check exists for.
{
  printf 'echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=alpha_failed"\n'
  printf 'echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=ghost_failed"\n\n'
  printf '| reason | 発生 Phase | 発生条件 |\n|---|---|---|\n'
  printf '| `alpha_failed` | p1 | cond |\n'
} > "$SANDBOX/$REASON_TARGET"
assert "undocumented reason exits 1" "1" \
  "$(bash "$REASON_COVERAGE" --repo-root "$SANDBOX" >/dev/null 2>&1; echo $?)"
assert "undocumented reason is named on stdout" "ghost_failed" \
  "$(bash "$REASON_COVERAGE" --repo-root "$SANDBOX" 2>/dev/null)"

# A table row without a matching emit is not a finding — the table is a
# superset that documents reasons for other flags too.
{
  printf 'echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=alpha_failed"\n\n'
  printf '| reason | 発生 Phase | 発生条件 |\n|---|---|---|\n'
  printf '| `alpha_failed` | p1 | cond |\n'
  printf '| `documented_only` | p2 | cond |\n'
} > "$SANDBOX/$REASON_TARGET"
assert "extra table row alone is not a finding (exit 0)" "0" \
  "$(bash "$REASON_COVERAGE" --repo-root "$SANDBOX" >/dev/null 2>&1; echo $?)"

# No emit at all: rc=2, not 0. An empty left side makes the set difference empty,
# which would otherwise read as "everything is documented" — the check reporting
# success for a run in which it verified nothing.
printf 'no markers here at all\n' > "$SANDBOX/$REASON_TARGET"
assert "zero emitted reasons exits 2 (not a silent pass)" "2" \
  "$(bash "$REASON_COVERAGE" --repo-root "$SANDBOX" >/dev/null 2>&1; echo $?)"
zero_err="$(bash "$REASON_COVERAGE" --repo-root "$SANDBOX" 2>&1 >/dev/null || true)"
if printf '%s' "$zero_err" | grep -qF 'emit を 1 件も抽出できませんでした'; then
  pass "zero-emit case explains the suspected marker drift"
else
  fail "zero-emit diagnostic missing — got: $zero_err"
fi

assert "missing target exits 2" "2" \
  "$(bash "$REASON_COVERAGE" --repo-root "$SANDBOX" --target does/not/exist.md >/dev/null 2>&1; echo $?)"
assert "unknown argument exits 2" "2" \
  "$(bash "$REASON_COVERAGE" --bogus >/dev/null 2>&1; echo $?)"
assert "--help exits 0" "0" \
  "$(bash "$REASON_COVERAGE" --help >/dev/null 2>&1; echo $?)"

print_summary "$(basename "$0")"
