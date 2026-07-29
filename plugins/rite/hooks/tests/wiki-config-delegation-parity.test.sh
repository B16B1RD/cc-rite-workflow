#!/bin/bash
# Static parity pins for the four skill bodies that delegate their `wiki:`
# configuration reads to hooks/scripts/lib/wiki-config.sh (Issue #2046).
#
# The delegation itself is what removed the defect — a skill body cannot host a
# YAML parser, because the Skill loader rewrites positional parameters in it and
# every key reads back empty. What the delegation cannot express is the contract
# each caller adopted for the case where the helper does not load, and those
# contracts are deliberately asymmetric:
#
#   wiki-ingest / wiki-lint  — exit 1 + WIKI_CONFIG_HELPER_UNAVAILABLE
#       Wiki work is the whole point of these skills. Reporting "Wiki disabled"
#       when the config could not be read is the misreport this Issue removed.
#   cleanup / issue-close    — continue with skip reason config_helper_unavailable
#       Wiki ingest is a side task; the surrounding cleanup must finish. The
#       reason surfaces the failure instead of letting the opt-out default
#       absorb it into a normal skip.
#
# Nothing else checks any of this. sh-cross-ref-check verifies step/phase
# references, orphan-reference-check looks for unreferenced files — neither
# reads these strings. Renaming the reason in cleanup's body while leaving its
# report table untouched leaves the whole suite green, and the mismatch only
# shows up as a blank row in a completion report someone has to notice.
#
# Convention: static text assertions against the skill bodies. No sandbox, no
# network, no execution of the skills themselves.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
SKILLS="$REPO_ROOT/plugins/rite/skills"
LIB_REL="hooks/scripts/lib/wiki-config.sh"

echo "=== wiki-config delegation parity tests ==="

if [ ! -d "$SKILLS" ]; then
  echo "ERROR: $SKILLS not found" >&2
  exit 1
fi

# --- (a) All four sites source the shared helper ------------------------------
for skill in wiki-ingest wiki-lint cleanup issue-close; do
  body="$SKILLS/$skill/SKILL.md"
  if [ ! -f "$body" ]; then
    fail "$skill/SKILL.md not found"
    continue
  fi
  if grep -qF "$LIB_REL" "$body"; then
    pass "$skill sources $LIB_REL"
  else
    fail "$skill no longer references $LIB_REL — did it grow its own parser again?"
  fi
  # The delegation is pointless if the body still calls a parser it defines.
  if grep -qE '^\s*(extract_yaml_key|parse_wiki_key)\s*\(\)' "$body"; then
    fail "$skill defines an inline YAML parser again"
  else
    pass "$skill defines no inline YAML parser"
  fi
done

# --- (b) The two fail-fast sites emit the sentinel and exit 1 -----------------
for skill in wiki-ingest wiki-lint; do
  body="$SKILLS/$skill/SKILL.md"
  [ -f "$body" ] || continue
  if grep -qF 'WIKI_CONFIG_HELPER_UNAVAILABLE=1' "$body"; then
    pass "$skill emits WIKI_CONFIG_HELPER_UNAVAILABLE=1"
  else
    fail "$skill lost the WIKI_CONFIG_HELPER_UNAVAILABLE sentinel"
  fi
  # The sentinel without the exit would leave the skill running on unread config.
  # Scoped to the source-failure block rather than a fixed line window: a window
  # ties the assertion to how many comment lines sit between the two statements,
  # and would break on an edit that changes nothing about the contract. `\s` is
  # avoided deliberately — it is a GNU awk extension that mawk does not honour
  # (verified against mawk 1.3.4), and this file runs wherever the suite runs.
  if awk '
      /^if ! \. .*wiki-config\.sh/ { in_block = 1; sentinel = 0; next }
      in_block && /WIKI_CONFIG_HELPER_UNAVAILABLE=1/ { sentinel = 1 }
      in_block && sentinel && /^[[:space:]]*exit 1/ { hit = 1 }
      in_block && /^fi[[:space:]]*$/ { in_block = 0 }
      END { exit hit ? 0 : 1 }
    ' "$body"; then
    pass "$skill exits 1 inside the helper-source failure block"
  else
    fail "$skill emits the sentinel but does not exit 1 in the same block"
  fi
done

# --- (c) The two skip sites use the reason string, and cleanup's table agrees --
CLEANUP_BODY="$SKILLS/cleanup/SKILL.md"
REASON="config_helper_unavailable"

for skill in cleanup issue-close; do
  body="$SKILLS/$skill/SKILL.md"
  [ -f "$body" ] || continue
  if grep -qF "reason=\"$REASON\"" "$body"; then
    pass "$skill sets reason=\"$REASON\""
  else
    fail "$skill no longer sets reason=\"$REASON\" — the skip becomes indistinguishable from a normal one"
  fi
done

# cleanup renders the reason in its step 12 decision table. A rename on one side
# only shows up as a blank row in the completion report, which is exactly the
# kind of quiet mismatch this Issue was about.
if [ -f "$CLEANUP_BODY" ]; then
  if grep -qF "WIKI_INGEST_SKIPPED=1; reason=$REASON" "$CLEANUP_BODY"; then
    pass "cleanup's decision table carries a row for reason=$REASON"
  else
    fail "cleanup sets reason=$REASON but its decision table has no matching row"
  fi
  # The row must be the unchecked kind: this is a real failure, not a legitimate
  # skip like disabled / auto_ingest_off / no_pending.
  if grep -F "WIKI_INGEST_SKIPPED=1; reason=$REASON" "$CLEANUP_BODY" | grep -qF '| ` ` |'; then
    pass "the row marks it as an outstanding item, not a clean skip"
  else
    fail "the reason=$REASON row is not marked as an outstanding item"
  fi
fi

# --- (d) Every helper the four bodies invoke actually exists ------------------
# A path typo here fails at runtime as "helper not found", which the fail-safe
# then reports as a config problem — the wrong diagnosis for the wrong layer.
missing=0
checked=0
while IFS= read -r rel; do
  checked=$((checked + 1))
  [ -f "$REPO_ROOT/plugins/rite/$rel" ] || {
    fail "referenced helper does not exist: plugins/rite/$rel"
    missing=$((missing + 1))
  }
done < <(
  for skill in wiki-ingest wiki-lint cleanup issue-close; do
    body="$SKILLS/$skill/SKILL.md"
    [ -f "$body" ] || continue
    grep -oE '\{plugin_root\}/hooks/scripts/[A-Za-z0-9_/.-]+\.sh' "$body"
  done | sed 's@^{plugin_root}/@@' | sort -u
)
if [ "$checked" -eq 0 ]; then
  fail "no {plugin_root}/hooks/scripts/*.sh references found — the extraction pattern drifted"
elif [ "$missing" -eq 0 ]; then
  pass "all $checked referenced hooks/scripts helpers exist"
fi

print_summary "$(basename "$0")"
