#!/bin/bash
# rite workflow - STATE_ROOT validation helper (private internal helper)
#
# Validates a STATE_ROOT argument against path traversal, shell metacharacter,
# and control character injection. Exits 0 silent on success; exits 1 with an
# ERROR diagnostic to stderr on failure. Intended to be invoked once at the
# top of any helper that accepts STATE_ROOT directly (writer/reader/schema
# layer) so the validation rules live in one place.
#
# Usage:
#   bash plugins/rite/hooks/_validate-state-root.sh "$STATE_ROOT" || exit 1
#
# Arguments:
#   $1 STATE_ROOT  Directory path to validate (must be non-empty)
#
# Exit codes:
#   0 — STATE_ROOT passes all checks
#   1 — STATE_ROOT empty / contains traversal (..) / shell metacharacter ($, `) /
#       control character (0x00-0x1F, 0x7F)
#
# Why this exists:
#   The same validation block (case glob + tr -d '[:cntrl:]' check + 4 ERROR
#   lines) was duplicated byte-for-byte across two helpers
#   (_resolve-session-id-from-file.sh / _resolve-schema-version.sh). This helper
#   is the single source of truth for STATE_ROOT validation. The original
#   threat model (defence-in-depth against future callers passing untrusted
#   path values) is preserved verbatim.
#
# Symmetry doctrine:
#   This helper completes the writer/reader/schema 3-layer validation
#   symmetry by giving every layer a single shared entry point instead of
#   maintaining parallel inline copies.
set -euo pipefail

STATE_ROOT="${1:-}"
if [ -z "$STATE_ROOT" ]; then
  echo "ERROR: usage: $0 <state_root>" >&2
  exit 1
fi

# Path traversal + shell metacharacter check.
# Threat model: a future caller passing an untrusted STATE_ROOT (e.g. from
# multi-tenant driver) could request path probes outside the sandbox or
# trigger command substitution via backtick / $-expansion. We reject ".."
# (path traversal), "$" (variable expansion), and "`" (command substitution)
# unconditionally.
case "$STATE_ROOT" in
  *..*|*'$'*|*'`'*)
    echo "ERROR: STATE_ROOT contains unsafe traversal or shell metacharacter: '$STATE_ROOT'" >&2
    echo "  本 helper は親ディレクトリ参照 (..) / shell expansion (\$) / command substitution (\`) を含む path を受理しません。" >&2
    echo "  対処: caller (state-path-resolve.sh / pwd 由来 path) を経由して正規化された path を渡してください。" >&2
    exit 1
    ;;
esac

# Control character (newline / carriage return / 0x00-0x1F / 0x7F) check.
# bash の case glob では `\n` / `\r` を含む pattern が portable に書けないため、`tr -d '[:cntrl:]'` で
# 制御文字を除去した結果と元 STATE_ROOT を比較する方式で検出する。
state_root_sanitized=$(printf '%s' "$STATE_ROOT" | tr -d '[:cntrl:]')
if [ "$state_root_sanitized" != "$STATE_ROOT" ]; then
  echo "ERROR: STATE_ROOT contains control characters (newline / NUL / 0x00-0x1F / 0x7F)" >&2
  echo "  対処: caller (state-path-resolve.sh / pwd 由来 path) を経由して正規化された path を渡してください。" >&2
  exit 1
fi
unset state_root_sanitized

exit 0
