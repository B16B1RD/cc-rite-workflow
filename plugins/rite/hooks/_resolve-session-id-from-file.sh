#!/bin/bash
# rite workflow - Session ID Resolution from .rite-session-id File (private internal helper)
#
# Reads `<state_root>/.rite-session-id`, strips whitespace, and runs the result
# through `_resolve-session-id.sh` for RFC 4122 UUID validation. Returns the
# validated UUID on stdout, or empty string on any failure path (file absent /
# read failed / validation failed). Exit 0 in all cases (caller distinguishes
# present-and-valid vs absent/invalid via empty-string check).
#
# Usage:
#   sid=$(bash plugins/rite/hooks/_resolve-session-id-from-file.sh "$STATE_ROOT")
#
# Arguments:
#   $1 state_root  Directory containing `.rite-session-id` (typically the repo root
#                  resolved via `state-path-resolve.sh`)
#
# Output:
#   stdout: validated UUID, or empty string when:
#     - <state_root>/.rite-session-id is absent
#     - file is empty after whitespace stripping
#     - content fails UUID validation
#
# Exit codes:
#   0 — always (output empty string on any failure path so callers can rely on
#       a single command-substitution capture pattern: `sid=$(... )`)
#   1 — argument error (missing state_root)
#
# Why this exists (verified-review cycle 38 F-05 MEDIUM):
#   The compound sequence
#     `tr -d '[:space:]' < <state_root>/.rite-session-id` + `_resolve-session-id.sh`
#     validation + `sid=""` fallback
#   was duplicated across 3 sites:
#     - state-read.sh の per-session resolver
#     - flow-state-update.sh `_resolve_session_id` 関数 (sid_file 経路)
#     - resume-active-flag-restore.sh の `.rite-session-id` 読込ブロック
#   UUID validation 自体は cycle 34 F-01 で `_resolve-session-id.sh` に DRY 化済だが、
#   その上流の compound 動作 (file read + whitespace stripping + validation + fallback)
#   は残存していた。将来「session_id を hex normalize する」「base64-encoded UUID を許容」等の
#   追加で同型片肺更新 drift リスクを抱える経路を構造的に防ぐ。
#
# Caller migration (cycle 38 F-05):
#   Before (10 lines): `if [ -f "$root/.rite-session-id" ]; then ... raw=$(tr -d ...);`
#                      `if validated=$(bash _resolve-session-id.sh "$raw"); then ...; fi; fi`
#   After  (1 line):   `sid=$(bash _resolve-session-id-from-file.sh "$STATE_ROOT")`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_ROOT="${1:-}"
if [ -z "$STATE_ROOT" ]; then
  echo "ERROR: usage: $0 <state_root>" >&2
  exit 1
fi

sid_file="$STATE_ROOT/.rite-session-id"

# File-absent path: return empty string (legitimate "no session id stored yet").
# This matches the previous inline behavior `if [ -f ... ]; then ... fi` where
# the absent branch left `sid=""` untouched.
if [ ! -f "$sid_file" ]; then
  exit 0
fi

# Whitespace-stripped read. `2>/dev/null || raw=""` keeps the previous behavior
# of treating IO errors (permission denied / inode race) as "no session id"
# rather than fail-fast — caller chains have always degraded gracefully here.
raw=$(tr -d '[:space:]' < "$sid_file" 2>/dev/null) || raw=""
if [ -z "$raw" ]; then
  exit 0
fi

# Run through the canonical UUID validator. On validation failure, fall through
# to the implicit empty-string output (exit 0 with no stdout). Callers cannot
# distinguish "file empty" from "file invalid" from "validation failed", which
# matches the prior inline semantics — all three paths previously collapsed to
# `sid=""` and downstream code treated the session as effectively missing.
if validated=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$raw" 2>/dev/null); then
  printf '%s' "$validated"
fi
