#!/bin/bash
# rite workflow - Terminal Output Regression Guard (Issue #561)
#
# Verifies that Terminal Completion sections in /rite:issue:create sub-skills
# wrap sentinel markers in HTML comments so the user-visible final line is
# always the human-readable completion message, not a bare sentinel token.
#
# Enforced contract (per Issue #561 D-01 / #561 AC-2, AC-3, AC-6):
#   - plugins/rite/commands/issue/create-register.md   Phase 4.4 sentinel is
#     documented as `<!-- [create:completed:{...}] -->` (HTML comment form)
#   - plugins/rite/commands/issue/create-decompose.md  Phase 1.0.3 sentinel is
#     documented as `<!-- [create:completed:{...}] -->` (HTML comment form)
#   - plugins/rite/commands/issue/create-interview.md  Defense-in-Depth example
#     outputs `<!-- [interview:skipped] -->` / `<!-- [interview:completed] -->`
#
# Non-regression (AC-3): the raw string `[create:completed:` / `[interview:`
# must still appear in each file so hook/grep contracts remain matchable.
#
# Exit codes:
#   0  all checks passed
#   1  a check failed (details on stderr)
#   2  usage error (unknown argument)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Color helpers (best-effort; disable when stdout is not a tty)
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'
  C_YEL=$'\033[0;33m'
  C_GRN=$'\033[0;32m'
  C_RST=$'\033[0m'
else
  C_RED=""
  C_YEL=""
  C_GRN=""
  C_RST=""
fi

usage() {
  cat >&2 <<'USAGE_EOF'
Usage: verify-terminal-output.sh [--quiet]

Options:
  --quiet    Suppress success output (failures still go to stderr)

Verifies that Terminal Completion sections in create-register.md /
create-decompose.md / create-interview.md wrap sentinel markers in HTML
comments (Issue #561 AC-2 / AC-3 / AC-6).

Exit codes:
  0  all checks passed
  1  a check failed (see stderr)
  2  usage error
USAGE_EOF
  exit 2
}

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    -h|--help) usage ;;
    *) echo "ERROR: unknown argument: $arg" >&2; usage ;;
  esac
done

FAILED=0

fail() {
  echo "${C_RED}FAIL${C_RST}: $1" >&2
  FAILED=$((FAILED + 1))
}

pass() {
  [ "$QUIET" = "1" ] && return 0
  echo "${C_GRN}PASS${C_RST}: $1"
}

info() {
  [ "$QUIET" = "1" ] && return 0
  echo "${C_YEL}INFO${C_RST}: $1"
}

# -----------------------------------------------------------------------------
# Check 1: create-register.md Phase 4 HTML-comment sentinel
# -----------------------------------------------------------------------------
CREATE_REGISTER="$REPO_ROOT/plugins/rite/commands/issue/create-register.md"

if [ ! -f "$CREATE_REGISTER" ]; then
  fail "create-register.md not found at $CREATE_REGISTER"
else
  # AC-3 non-regression: the raw sentinel string must still be present somewhere
  # in the file so hook/grep contracts (stop-guard.sh CREATE_HINT grep etc.)
  # continue to match.
  if grep -qE '\[create:completed:' "$CREATE_REGISTER"; then
    pass "create-register.md: contains [create:completed:...] string (AC-3 non-regression)"
  else
    fail "create-register.md: missing [create:completed:...] string (AC-3 regression — hook contract broken)"
  fi

  # AC-2 / AC-6: the HTML-comment wrapped form must be present. This is the
  # mechanical enforcement introduced by Issue #561 — without this form, the
  # bare sentinel regresses to being the user-visible final line.
  if grep -qE '<!--[[:space:]]*\[create:completed:' "$CREATE_REGISTER"; then
    pass "create-register.md: sentinel wrapped in HTML comment form (AC-2 / AC-6)"
  else
    fail "create-register.md: sentinel NOT wrapped in HTML comment form; expected <!-- [create:completed:{N}] -->"
  fi

  # Drift guard: check that the prose no longer instructs "absolute last line"
  # with a bare sentinel. The phrase is now expected only when bound to the
  # HTML-comment form. This is a soft check — warn, not fail — because the
  # phrase may legitimately appear in historical-note or design-decision text.
  if grep -nE '\[create:completed:\{[^}]+\}\][[:space:]]*MUST be the (absolute )?last line' "$CREATE_REGISTER" >/dev/null 2>&1; then
    # Matches legacy phrasing "[create:completed:{N}] MUST be the last line" without the <!-- --> wrapper.
    info "create-register.md: legacy prose about bare-sentinel 'absolute last line' may still be present; review manually"
  fi
fi

# -----------------------------------------------------------------------------
# Check 2: create-decompose.md Phase 1.0 HTML-comment sentinel
# -----------------------------------------------------------------------------
CREATE_DECOMPOSE="$REPO_ROOT/plugins/rite/commands/issue/create-decompose.md"

if [ ! -f "$CREATE_DECOMPOSE" ]; then
  fail "create-decompose.md not found at $CREATE_DECOMPOSE"
else
  if grep -qE '\[create:completed:' "$CREATE_DECOMPOSE"; then
    pass "create-decompose.md: contains [create:completed:...] string (AC-3 non-regression)"
  else
    fail "create-decompose.md: missing [create:completed:...] string (AC-3 regression)"
  fi

  if grep -qE '<!--[[:space:]]*\[create:completed:' "$CREATE_DECOMPOSE"; then
    pass "create-decompose.md: sentinel wrapped in HTML comment form (AC-2 / AC-6)"
  else
    fail "create-decompose.md: sentinel NOT wrapped in HTML comment form"
  fi
fi

# -----------------------------------------------------------------------------
# Check 3: create-interview.md [interview:*] HTML-comment form
# -----------------------------------------------------------------------------
CREATE_INTERVIEW="$REPO_ROOT/plugins/rite/commands/issue/create-interview.md"

if [ ! -f "$CREATE_INTERVIEW" ]; then
  fail "create-interview.md not found at $CREATE_INTERVIEW"
else
  # AC-3 non-regression
  if grep -qE '\[interview:(completed|skipped)\]' "$CREATE_INTERVIEW"; then
    pass "create-interview.md: contains [interview:completed] / [interview:skipped] string (AC-3 non-regression)"
  else
    fail "create-interview.md: missing [interview:*] string (AC-3 regression)"
  fi

  # AC-2 / AC-6: at least one occurrence of the HTML-commented sentinel form
  # must be present in the output examples.
  if grep -qE '<!--[[:space:]]*\[interview:(completed|skipped)\]' "$CREATE_INTERVIEW"; then
    pass "create-interview.md: [interview:*] wrapped in HTML comment form (AC-2 / AC-6)"
  else
    fail "create-interview.md: [interview:*] NOT wrapped in HTML comment form; expected <!-- [interview:skipped] --> / <!-- [interview:completed] -->"
  fi
fi

# -----------------------------------------------------------------------------
# Check 4: SKILL.md / workflow-identity.md identity entries
# -----------------------------------------------------------------------------
SKILL_MD="$REPO_ROOT/plugins/rite/skills/rite-workflow/SKILL.md"
IDENTITY_MD="$REPO_ROOT/plugins/rite/skills/rite-workflow/references/workflow-identity.md"

if [ ! -f "$SKILL_MD" ]; then
  fail "SKILL.md not found at $SKILL_MD"
else
  if grep -qE '止まらない|turn を閉じない|meaningful_terminal_output' "$SKILL_MD"; then
    pass "SKILL.md: identity entry for 'workflow stops' / 'meaningful terminal output' present (AC-7)"
  else
    fail "SKILL.md: identity entry missing (AC-7)"
  fi
fi

if [ ! -f "$IDENTITY_MD" ]; then
  fail "workflow-identity.md not found at $IDENTITY_MD"
else
  if grep -qE 'no_mid_workflow_stop' "$IDENTITY_MD" && grep -qE 'meaningful_terminal_output' "$IDENTITY_MD"; then
    pass "workflow-identity.md: both principles (no_mid_workflow_stop / meaningful_terminal_output) registered"
  else
    fail "workflow-identity.md: required principles missing"
  fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then
  echo "" >&2
  echo "${C_RED}verify-terminal-output.sh: $FAILED check(s) failed${C_RST}" >&2
  echo "See Issue #561 for rationale and required output structure." >&2
  exit 1
fi

[ "$QUIET" = "1" ] || echo "${C_GRN}verify-terminal-output.sh: all checks passed${C_RST}"
exit 0
