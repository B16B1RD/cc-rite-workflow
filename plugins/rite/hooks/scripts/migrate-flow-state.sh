#!/bin/bash
# rite workflow — Legacy `.rite-flow-state` Auto Migration (Issue #672 / #679)
#
# Detects legacy `.rite-flow-state` files (`schema_version` missing or `< 2`)
# and migrates them to the per-session path `.rite/sessions/{session_id}.flow-state`
# (Option A, multi-state design — see docs/designs/multi-session-state.md).
#
# Migration is a 5-step rename strategy:
#   1. Detect legacy file
#   2. Resolve session_id (read from legacy state, or generate fresh UUID)
#   3. Atomic write new format file (mktemp + mv)
#   4. Rename legacy source to `.rite-flow-state.legacy.{timestamp}`
#   5. Emit explicit migration message on stderr (silent skip is forbidden — AC-8)
#
# Failure handling preserves legacy state untouched:
#   - step 3 failure: no new file left behind, legacy intact
#   - step 4 failure: new file removed, legacy intact
#
# Usage:
#   STATE_ROOT="/path/to/repo" bash migrate-flow-state.sh           # apply
#   STATE_ROOT="/path/to/repo" bash migrate-flow-state.sh --dry-run # detect only
#
# Exit codes:
#   0 — migrated, no-op (already v2 or no legacy file), or dry-run completed
#   1 — migration failed (legacy state preserved)
#
# Called from `session-start.sh` at the earliest opportunity so subsequent
# hook reads land on the per-session path.

set -euo pipefail

# --- Argument parsing ---
DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  '') ;;
  *) echo "ERROR: unknown argument: $1 (expected: --dry-run)" >&2; exit 1 ;;
esac

# --- STATE_ROOT resolution ---
STATE_ROOT="${STATE_ROOT:-$PWD}"
if [ ! -d "$STATE_ROOT" ]; then
  echo "ERROR: STATE_ROOT does not exist: $STATE_ROOT" >&2
  exit 1
fi

LEGACY_FILE="$STATE_ROOT/.rite-flow-state"
SESSIONS_DIR="$STATE_ROOT/.rite/sessions"

# --- Honor `flow_state.schema_version` rollback flag ---
# Migration must NOT run when the user explicitly opts into legacy single-file
# operation via `rite-config.yml` (`flow_state.schema_version: 1`) or when the
# config is absent (default = legacy = "1"). Only schema_version=2 enables
# migration. This is the documented rollback path (Issue #672 §Rollback).
# Reuses the canonical _resolve-schema-version.sh helper. The helper is
# documented to "always exit 0" (echoes "1" or "2" on stdout), so we call it
# without a defensive `|| fallback` to stay symmetric with state-read.sh and
# flow-state-update.sh's _resolve_schema_version function. If the helper file
# is missing, fall through to the legacy default; the resolution itself never
# fails by contract.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RESOLVE_SCHEMA="$SCRIPT_DIR/../_resolve-schema-version.sh"
if [ -x "$_RESOLVE_SCHEMA" ]; then
  CONFIG_SCHEMA_VERSION=$(bash "$_RESOLVE_SCHEMA" "$STATE_ROOT")
else
  CONFIG_SCHEMA_VERSION="1"
fi
if [ "$CONFIG_SCHEMA_VERSION" != "2" ]; then
  # Rollback / config-absent path: legacy operation is the user's stated choice.
  # Silent no-op (the user will see the explicit migration message only when
  # they opt into v2 via config — that's where the AC-8 contract applies).
  exit 0
fi

# --- Step 1: Detect legacy file ---
if [ ! -f "$LEGACY_FILE" ]; then
  # No legacy file — nothing to migrate. Silent no-op (this is the common path
  # on systems already running schema_version=2).
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[rite] ERROR: jq is required for migrate-flow-state.sh but was not found in PATH" >&2
  exit 1
fi

# Empty legacy file is treated as "nothing meaningful to migrate". Remove it
# so subsequent hook reads land on the per-session path without confusion.
if [ ! -s "$LEGACY_FILE" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    echo "[rite] dry-run: would remove empty legacy file: $LEGACY_FILE" >&2
    exit 0
  fi
  rm -f "$LEGACY_FILE" 2>/dev/null || true
  exit 0
fi

# Validate JSON parse before reading schema_version. Corrupt JSON must NOT be
# silently treated as "missing schema_version" — that would force a destructive
# migration on an unreadable file.
if ! _SCHEMA_VERSION_RAW=$(jq -r '.schema_version // empty' "$LEGACY_FILE" 2>/dev/null); then
  echo "[rite] ERROR: legacy file is not valid JSON: $LEGACY_FILE — manual recovery required, skipping migration" >&2
  exit 1
fi

# Determine if this file actually needs migration (schema_version missing or < 2).
# Non-numeric values fall through to "needs migration" (treated like missing).
_NEEDS_MIGRATION=false
if [ -z "$_SCHEMA_VERSION_RAW" ]; then
  _NEEDS_MIGRATION=true
elif ! [[ "$_SCHEMA_VERSION_RAW" =~ ^[0-9]+$ ]]; then
  _NEEDS_MIGRATION=true
elif [ "$_SCHEMA_VERSION_RAW" -lt 2 ]; then
  _NEEDS_MIGRATION=true
fi

if [ "$_NEEDS_MIGRATION" != "true" ]; then
  # Already schema_version >= 2 in the legacy path. Treat as legitimate — a
  # writer (e.g., flow-state-update.sh) may have chosen the legacy path
  # intentionally because no session_id was available at write time. We do
  # not remove the file: doing so would discard the only copy of that state.
  # No-op. The per-session path is the canonical location going forward; if
  # this legacy file is later confirmed orphaned, manual cleanup is the path
  # forward — out of scope for automatic migration.
  exit 0
fi

# --- Step 2: Resolve session_id ---
# Prefer the session_id stored inside the legacy file. If absent, malformed,
# or empty, generate a fresh UUID so the migrated file has a valid identifier.
SESSION_ID=""
_LEGACY_SID=$(jq -r '.session_id // empty' "$LEGACY_FILE" 2>/dev/null) || _LEGACY_SID=""

# SCRIPT_DIR was set at the top of this script (during config schema resolution);
# reuse it instead of re-computing. The two earlier declarations were equivalent
# since BASH_SOURCE[0] is invariant within a single invocation.
RESOLVE_SID="$SCRIPT_DIR/../_resolve-session-id.sh"

if [ -n "$_LEGACY_SID" ] && [ -x "$RESOLVE_SID" ]; then
  if validated=$(bash "$RESOLVE_SID" "$_LEGACY_SID" 2>/dev/null); then
    SESSION_ID="$validated"
  fi
fi

if [ -z "$SESSION_ID" ]; then
  # Generate fresh UUID. Try uuidgen first (POSIX-ish), fall back to
  # /proc/sys/kernel/random/uuid (Linux), then python3 (last resort).
  # Use a 2-step capture pattern (raw → tr) so a uuidgen failure under
  # `set -euo pipefail` does not propagate up the pipeline and abort the
  # script before reaching the next fallback. Symmetric with how
  # `_LEGACY_SID` is captured above.
  if command -v uuidgen >/dev/null 2>&1; then
    _raw=$(uuidgen 2>/dev/null) || _raw=""
    [ -n "$_raw" ] && SESSION_ID=$(printf '%s' "$_raw" | tr 'A-F' 'a-f')
  fi
  if [ -z "$SESSION_ID" ] && [ -r /proc/sys/kernel/random/uuid ]; then
    _raw=$(tr -d '\n' < /proc/sys/kernel/random/uuid 2>/dev/null) || _raw=""
    [ -n "$_raw" ] && SESSION_ID=$(printf '%s' "$_raw" | tr 'A-F' 'a-f')
  fi
  if [ -z "$SESSION_ID" ] && command -v python3 >/dev/null 2>&1; then
    SESSION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null) || SESSION_ID=""
  fi
  if [ -z "$SESSION_ID" ]; then
    echo "[rite] ERROR: cannot generate UUID — uuidgen / /proc/sys/kernel/random/uuid / python3 all unavailable" >&2
    exit 1
  fi
fi

NEW_FILE="$SESSIONS_DIR/${SESSION_ID}.flow-state"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
BACKUP_FILE="$STATE_ROOT/.rite-flow-state.legacy.${TIMESTAMP}"

# --- Dry-run early exit (before any filesystem mutation) ---
if [ "$DRY_RUN" = "true" ]; then
  echo "[rite] dry-run: would migrate $LEGACY_FILE → $NEW_FILE (backup: $BACKUP_FILE)" >&2
  exit 0
fi

# --- Step 3: Atomic write new format file (mktemp + mv) ---
# Ensure target directory exists with restrictive permissions (multi-user
# host protection — symmetric with flow-state-update.sh).
if ! mkdir -p "$SESSIONS_DIR" 2>/dev/null; then
  echo "[rite] ERROR: migration step 3 (mkdir $SESSIONS_DIR) failed — legacy state preserved at $LEGACY_FILE" >&2
  exit 1
fi
chmod 700 "$SESSIONS_DIR" 2>/dev/null || true

# Signal-specific trap to clean up the temp file if the script is interrupted
# between mktemp and the final mv. Without this, SIGINT/SIGTERM/SIGHUP arriving
# in the race window would leave a `.rite/sessions/{sid}.flow-state.XXXXXX`
# orphan that subsequent readers see as a "non-UUID flow-state file". The
# 2-state commit pattern below (`TMP_NEW=""` after successful mv) disarms the
# trap once the write is committed.
TMP_NEW=""
jq_err=""
NEW_FILE_TO_CLEANUP=""
NEW_FILE_COMMITTED=false
_rite_migrate_cleanup() {
  rm -f "${TMP_NEW:-}" "${jq_err:-}"
  # Roll back the new-format file when step 4 has not committed it yet.
  # NEW_FILE_TO_CLEANUP is set after step 3's atomic mv; NEW_FILE_COMMITTED
  # flips to true only after step 4's rename succeeds.
  if [ -n "${NEW_FILE_TO_CLEANUP:-}" ] && [ "${NEW_FILE_COMMITTED:-false}" != "true" ]; then
    rm -f "$NEW_FILE_TO_CLEANUP"
  fi
}
trap 'rc=$?; _rite_migrate_cleanup; exit $rc' EXIT
trap '_rite_migrate_cleanup; exit 130' INT
trap '_rite_migrate_cleanup; exit 143' TERM
trap '_rite_migrate_cleanup; exit 129' HUP

if ! TMP_NEW=$(mktemp "${NEW_FILE}.XXXXXX" 2>/dev/null); then
  echo "[rite] ERROR: migration step 3 (mktemp under $SESSIONS_DIR) failed — legacy state preserved at $LEGACY_FILE" >&2
  exit 1
fi
chmod 600 "$TMP_NEW" 2>/dev/null || true

# Capture jq stderr so build failures surface their root cause (e.g. malformed
# legacy JSON, missing field path) instead of silently emitting a generic
# "jq build new-format object failed" message. Use the canonical helper to stay
# symmetric with state-read.sh / flow-state-update.sh / _resolve-cross-session-guard.sh
# (the helper applies chmod 600 and emits a 3-line WARNING block on mktemp failure).
jq_err=$(bash "$SCRIPT_DIR/../_mktemp-stderr-guard.sh" \
  "migrate-flow-state" "migrate-jq-err" \
  "jq build new-format object 失敗時の root cause が表示されません")

# Build the new-format object by merging schema_version: 2 with the legacy
# fields. Missing fields fall back to defaults compatible with the
# `flow-state-update.sh` create object (active=false, issue_number=0,
# branch="", phase="", previous_phase="", pr_number=0,
# parent_issue_number=0, next_action="", last_synced_phase="").
# session_id and updated_at are forced to migration-time values.
if ! jq -n \
  --slurpfile legacy "$LEGACY_FILE" \
  --arg sid "$SESSION_ID" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '
    ($legacy[0] // {}) as $L
    | {
        schema_version: 2,
        active: ($L.active // false),
        issue_number: (($L.issue_number // 0) | tonumber? // 0),
        branch: ($L.branch // ""),
        phase: ($L.phase // ""),
        previous_phase: ($L.previous_phase // ""),
        pr_number: (($L.pr_number // 0) | tonumber? // 0),
        parent_issue_number: (($L.parent_issue_number // 0) | tonumber? // 0),
        next_action: ($L.next_action // ""),
        updated_at: $ts,
        session_id: $sid,
        last_synced_phase: ($L.last_synced_phase // "")
      }
    + (if $L.wm_comment_id   then {wm_comment_id: $L.wm_comment_id}     else {} end)
    + (if $L.error_count     then {error_count: $L.error_count}         else {} end)
    + (if $L.loop_count      then {loop_count: $L.loop_count}           else {} end)
  ' > "$TMP_NEW" 2>"${jq_err:-/dev/null}"
then
  echo "[rite] ERROR: migration step 3 (jq build new-format object) failed — legacy state preserved at $LEGACY_FILE" >&2
  if [ -n "$jq_err" ] && [ -s "$jq_err" ]; then
    head -3 "$jq_err" | sed 's/^/  /' >&2
  fi
  exit 1
fi
[ -n "$jq_err" ] && rm -f "$jq_err"
jq_err=""

if ! mv "$TMP_NEW" "$NEW_FILE" 2>/dev/null; then
  echo "[rite] ERROR: migration step 3 (atomic mv $TMP_NEW → $NEW_FILE) failed — legacy state preserved at $LEGACY_FILE" >&2
  exit 1
fi
TMP_NEW=""  # disarm trap cleanup — file is now committed under its final name

# Track NEW_FILE so step 4 failure can route through the same trap-managed
# rollback path as step 3, instead of an ad-hoc inline rm. NEW_FILE_COMMITTED
# stays "false" until step 4 succeeds; on any signal/error before that,
# `_rite_migrate_cleanup` removes the new-format file to preserve the
# rollback semantics tested by TC-10.
NEW_FILE_TO_CLEANUP="$NEW_FILE"
NEW_FILE_COMMITTED=false

# --- Step 4: Rename legacy source to backup path ---
# Tighten the source file's mode to 600 *before* the rename so the backup
# inode is born private. `mv` preserves the source inode mode, so doing
# `chmod 600` after `mv` opens a SIGINT/SIGKILL race window where the
# backup remains world-readable. Pre-mv chmod is symmetric with
# flow-state-update.sh's atomic-write block, which `chmod 600` the tempfile
# before mv. Best-effort: skip on filesystems without permission bit support.
chmod 600 "$LEGACY_FILE" 2>/dev/null || true
if ! mv "$LEGACY_FILE" "$BACKUP_FILE" 2>/dev/null; then
  echo "[rite] ERROR: migration step 4 (rename $LEGACY_FILE → $BACKUP_FILE) failed — new-format file removed, legacy state preserved" >&2
  # Roll back the new-format file via trap cleanup (NEW_FILE_COMMITTED still false).
  exit 1
fi

# Step 4 succeeded — disarm the new-format rollback so subsequent signals
# don't delete a committed file.
NEW_FILE_COMMITTED=true

# Defense-in-depth: re-apply chmod 600 to the backup file. The pre-mv chmod
# above already makes this redundant on filesystems where it succeeded, but
# we keep the post-mv invocation so that ACL-restricted environments which
# refused the source-side chmod still get a chance to tighten the backup
# (some filesystems allow chmod on the destination but not the source).
chmod 600 "$BACKUP_FILE" 2>/dev/null || true

# --- Step 5: Emit explicit migration message (silent skip forbidden — AC-8) ---
echo "[rite] migrated: $LEGACY_FILE → $NEW_FILE (backup: $BACKUP_FILE)" >&2

exit 0
