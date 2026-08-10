#!/bin/bash
# rite workflow - Wiki Ingest Trigger
#
# Saves a Raw Source artifact under .rite/wiki/raw/{type}/ so that the
# /rite:wiki-ingest command can later read & integrate it into Wiki pages.
#
# This script is the staging primitive for the Ingest cycle described in
# docs/designs/experience-heuristics-persistence-layer.md (F2). It does not
# perform LLM integration itself — that responsibility belongs to
# /rite:wiki-ingest (skills/wiki-ingest/SKILL.md). The script's only job is to
# write the Raw Source file with consistent naming and metadata.
#
# Usage:
#   bash wiki-ingest-trigger.sh \
#     --type {reviews|retrospectives|fixes} \
#     --source-ref "<short identifier, e.g. pr-123 or issue-469>" \
#     --content-file <path-to-file-containing-raw-source-body> \
#     [--pr-number 123] \
#     [--issue-number 469] \
#     [--title "Optional human-readable title"]
#
# Options:
#   --type           Raw Source type. Required. One of: reviews, retrospectives, fixes
#   --source-ref     Short identifier used in filename + frontmatter (required)
#   --content-file   Path to a file whose contents become the Raw Source body (required)
#   --pr-number      Optional PR number to embed in frontmatter
#   --issue-number   Optional Issue number to embed in frontmatter
#   --title          Optional one-line human-readable title
#
# Output:
#   stdout: relative path of the saved Raw Source file (single line)
#   stderr: validation errors / write failures
#
# Exit codes:
#   0  success
#   1  argument validation error
#   2  Wiki not initialized or wiki feature disabled
#   3  filesystem write failure
#
# Notes:
#   - The script does NOT perform git operations. Persistence to the wiki branch
#     (separate_branch strategy) is left to /rite:wiki-ingest, which has the
#     full branch-switching machinery.
#   - The script does NOT do any LLM work — it is a pure file-writing utility.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Resolve project root (git root anchored) — matches the session-start.sh /
# state-path-resolve.sh convention. Without this anchor,
# a `$PWD`-based rite-config.yml lookup would silently miss the config when the
# script runs from a subdirectory. CLI tool (not a hook), so $PWD takes the
# place of the stdin-supplied CWD that hook scripts receive.
#
# STATE_ROOT is ALSO the write anchor for the Raw Source (see "Compute target
# path" below): wiki-ingest-commit.sh scans `.rite/wiki/raw` after `cd
# "$repo_root"` where repo_root == this same state-path-resolve.sh result. In a
# multi-session linked worktree state-path-resolve.sh unifies to the main
# checkout, so anchoring the write here keeps trigger (write) and commit (scan)
# on the SAME root. A `$PWD`-relative write would land the raw in the worktree's
# `.rite/wiki/raw` while commit scans the main checkout's — silently dropping it
#. The two scripts MUST stay keyed off state-path-resolve.sh.
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$PWD" 2>/dev/null) || STATE_ROOT="$PWD"

TYPE=""
SOURCE_REF=""
CONTENT_FILE=""
PR_NUMBER=""
ISSUE_NUMBER=""
TITLE=""

usage() {
  cat <<'USAGE'
Usage: wiki-ingest-trigger.sh --type <type> --source-ref <ref> --content-file <path>
                              [--pr-number N] [--issue-number N] [--title "..."]

Saves a Raw Source artifact under .rite/wiki/raw/{type}/ for later
integration by /rite:wiki-ingest.

Required:
  --type           reviews | retrospectives | fixes
  --source-ref     short identifier (e.g. pr-123, issue-469)
  --content-file   path to file containing the raw body

Optional:
  --pr-number      PR number for frontmatter
  --issue-number   Issue number for frontmatter
  --title          one-line human-readable title

Exit codes:
  0  success (path of saved file printed to stdout)
  1  argument validation error
  2  Wiki disabled / not initialized
  3  filesystem write failure
USAGE
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)       usage; exit 0 ;;
    --type)          [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }; TYPE="$2"; shift 2 ;;
    --source-ref)    [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }; SOURCE_REF="$2"; shift 2 ;;
    --content-file)  [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }; CONTENT_FILE="$2"; shift 2 ;;
    --pr-number)     [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }; PR_NUMBER="$2"; shift 2 ;;
    --issue-number)  [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }; ISSUE_NUMBER="$2"; shift 2 ;;
    --title)         [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }; TITLE="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$TYPE" ]]; then
  echo "ERROR: --type is required" >&2
  exit 1
fi
case "$TYPE" in
  reviews|retrospectives|fixes) ;;
  *)
    echo "ERROR: --type must be one of: reviews, retrospectives, fixes (got: '$TYPE')" >&2
    exit 1
    ;;
esac

if [[ -z "$SOURCE_REF" ]]; then
  echo "ERROR: --source-ref is required" >&2
  exit 1
fi
# Any control char can break YAML frontmatter (early --- close, key
# injection, escape sequences). Limiting to LF/CR/TAB would leave
# 0x00-0x08 / 0x0B / 0x0C / 0x0E-0x1F / 0x7F as bypass vectors.
# contains_ctrl (control-char-neutralize.sh) は C0 + DEL に加え C1 8-bit
# (0x80-0x9f) もバイト単位で検出する — 旧 `=~ [[:cntrl:]]` は glibc が C1 を
# cntrl と分類しないため 0x9b (8-bit CSI) を素通ししていた。
if contains_ctrl "$SOURCE_REF"; then
  echo "ERROR: --source-ref must not contain control characters (newlines, tabs, or other C0/DEL/C1 control bytes)" >&2
  echo "  reason: control characters can break YAML frontmatter (early --- close, key injection, escape sequences)" >&2
  exit 1
fi

# Validate numeric args before any write so a non-numeric string can't end up
# in the YAML frontmatter and corrupt later parsers.
if [[ -n "$PR_NUMBER" ]]; then
  case "$PR_NUMBER" in
    ''|*[!0-9]*)
      echo "ERROR: --pr-number must be a positive integer (got: '$PR_NUMBER')" >&2
      exit 1
      ;;
  esac
fi
if [[ -n "$ISSUE_NUMBER" ]]; then
  case "$ISSUE_NUMBER" in
    ''|*[!0-9]*)
      echo "ERROR: --issue-number must be a positive integer (got: '$ISSUE_NUMBER')" >&2
      exit 1
      ;;
  esac
fi

# Mirror the SOURCE_REF control-char rejection on TITLE — the two fields land
# in adjacent YAML keys, so an asymmetric guard would leak the same injection
# class through whichever side is unprotected. Byte-wise C1 detection also
# rejects multibyte (e.g. Japanese) titles via their 0x80-0x9f continuation
# bytes — accepted: all in-repo callers pass ASCII-fixed titles.
if [[ -n "$TITLE" ]]; then
  if contains_ctrl "$TITLE"; then
    echo "ERROR: --title must not contain control characters (newlines, tabs, or other C0/DEL/C1 control bytes)" >&2
    exit 1
  fi
  # reject odd trailing backslashes (escape ambiguity)
  trailing=${TITLE##*[^\\]}
  trailing_len=${#trailing}
  if (( trailing_len % 2 == 1 )); then
    echo "ERROR: --title must not end with an odd number of backslashes (escape ambiguity)" >&2
    exit 1
  fi
fi

if [[ -z "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file is required" >&2
  exit 1
fi
# Reject symlinks and require path containment so a prompt-injected
# `--content-file /etc/passwd` can't slip through the subsequent
# `/rite:wiki-ingest` commit + push (which would publish the file to the wiki
# branch). Symlinks bypass the containment check after resolution, so they are
# rejected before realpath runs.
if [[ -L "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file '$CONTENT_FILE' is a symlink (rejected for security)" >&2
  echo "  hint: provide the actual file, not a symlink" >&2
  exit 1
fi
if [[ ! -f "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file '$CONTENT_FILE' does not exist or is not a regular file" >&2
  exit 1
fi
# Path containment: $PWD 配下・/tmp/rite-*・$TMPDIR/rite-* のみ許可。realpath 失敗時は
# fail-fast にして silent bypass (resolved path 不明のまま allowlist 判定が
# skip される経路) を塞ぐ。
resolved_content=$(realpath -- "$CONTENT_FILE") || {
  echo "ERROR: realpath failed for '$CONTENT_FILE' — cannot verify path containment" >&2
  echo "  hint: ensure the file exists and realpath is available (coreutils)" >&2
  exit 1
}
# Compare canonical paths on both sides. A logical $PWD can retain symlink
# components (notably macOS /var -> /private/var), while realpath above always
# returns the physical content path. Falling back to $PWD preserves the
# existing fail-closed boundary when the cwd itself cannot be canonicalized.
resolved_pwd=$(realpath -- "$PWD" 2>/dev/null) || resolved_pwd="$PWD"
# /tmp/* → /tmp/rite-* に限定して exfiltration 経路を縮小。macOS では realpath が
# /tmp → /private/tmp に symlink 解決するため /private/tmp/rite-* も同じ信頼境界
# (owner-managed /tmp/rite-* namespace) として allowlist に含める。
# sandbox 有効環境では /tmp 直下が読み込み専用で書込先が $TMPDIR (session-scoped,
# owner-managed) になるため、$TMPDIR/rite-* も realpath 解決後の実パス比較で同じ
# 信頼境界として受理する (。TMPDIR 未設定時は追加 arm なし = 従来挙動)。
resolved_tmpdir=""
if [[ -n "${TMPDIR:-}" ]]; then
  resolved_tmpdir=$(realpath -- "$TMPDIR" 2>/dev/null) || {
    # fail-closed (arm 縮小方向) だが、silent 無効化だと後段の rejection message が
    # 「$TMPDIR/rite-* も受容」と誤誘導するため診断用 WARNING を残す
    echo "WARNING: realpath on TMPDIR failed — \$TMPDIR/rite-* arm disabled" >&2
    resolved_tmpdir=""
  }
fi
case "$resolved_content" in
  "$resolved_pwd"/*|/tmp/rite-*|/private/tmp/rite-*)
    : # allowed ($PWD 配下 / /tmp/rite-* / /private/tmp/rite-* — 後者は macOS realpath 解決後)
    ;;
  *)
    if [[ -n "$resolved_tmpdir" ]] && [[ "$resolved_content" == "${resolved_tmpdir%/}"/rite-* ]]; then
      : # allowed ($TMPDIR/rite-* — sandbox 環境の session-scoped tmp namespace)
    else
      echo "ERROR: --content-file must be under \$PWD, /tmp/rite-*, or \$TMPDIR/rite-* (macOS: /private/tmp/rite-*)" >&2
      echo "  resolved path: $resolved_content" >&2
      echo "  hint: copy the file into the project directory first" >&2
      exit 1
    fi
    ;;
esac
if [[ ! -s "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file '$CONTENT_FILE' is empty" >&2
  exit 1
fi

# --- Wiki enable check (best-effort: checks rite-config.yml at STATE_ROOT) ---
# STATE_ROOT is resolved via state-path-resolve.sh at script entry (git-root
# anchored). When rite-config.yml is absent, we proceed and let /rite:wiki-ingest
# handle the strict validation later. The trigger only refuses when wiki.enabled
# is explicitly false.
#
# `set -euo pipefail` + `grep` returning rc=1 on no-match would abort the
# script. Stage the parse so a missing `wiki:` section or `enabled:` key
# leniently falls through to "not false" instead of killing the trigger.
#
# YAML parse logic sync: the canonical implementation lives in
# `hooks/scripts/lib/wiki-config.sh` (`parse_wiki_scalar()` / `validate_wiki_branch_name()`).
# The complete site inventory is `references/wiki-patterns.md` §分散実装ファイル一覧 (SoT);
# this comment lists only the sites that still re-implement the parse inline and
# must be kept in sync when the lib's parse contract changes:
#   1. this script (wiki-ingest-trigger.sh) — strict 3-arm with fail-fast `*` (safe-default policy)
#   2. hooks/scripts/wiki-growth-check.sh — lenient (layer 3 growth stall detection)
#   3. hooks/scripts/gitignore-health-check.sh — lenient (gitignore drift detection)
# The lib-using callers source the canonical implementation directly: the scripts
# wiki-ingest-commit.sh / wiki-worktree-commit.sh / wiki-worktree-setup.sh, and
# the skill bodies wiki-ingest / wiki-lint / cleanup / issue-close. A skill body
# cannot host its own parser — the Skill loader rewrites positional parameters in
# it (static check: hooks/scripts/dollar-zero-check.sh).
if [[ -f "$STATE_ROOT/rite-config.yml" ]]; then
  # Capture sed/awk stderr to a tempfile so syntax errors / binary corruption /
  # IO errors don't get conflated with "no match". The old `2>/dev/null || ...=""`
  # pattern silently treated all of those as "section absent" — leading the
  # Wiki enable check to misfire.
  _yaml_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-trigger-yaml-err-XXXXXX" 2>/dev/null) || _yaml_err=""
  # Fail closed on parse failure (exit 2 = treat as Wiki disabled). A lenient
  # fallback that continued staging would let a corrupted config quietly leak
  # raw sources to develop even when the user set wiki.enabled: false on purpose
  # — same threat model the .gitignore last-line-defense addresses.
  if wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' "$STATE_ROOT/rite-config.yml" 2>"${_yaml_err:-/dev/null}"); then
    :  # success (sed no-match は exit 0 なので legitimate)
  else
    _sed_rc=$?
    echo "ERROR: sed による rite-config.yml wiki セクション抽出が失敗 (rc=$_sed_rc)" >&2
    [ -n "$_yaml_err" ] && [ -s "$_yaml_err" ] && head -3 "$_yaml_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  safe-default: config parse 失敗のため staging を中止します (silent policy-violation 防止)" >&2
    [ -n "$_yaml_err" ] && rm -f "$_yaml_err"
    exit 2
  fi
  wiki_enabled_line=""
  if [[ -n "$wiki_section" ]]; then
    # `if ! var=$(cmd)` inverts the exit status, so `$?` inside the then-branch
    # would always read 0 even on real awk failure. Use if/else to preserve the
    # actual awk rc (locale=11, syntax=2, OOM via SIGKILL=137, etc.).
    if wiki_enabled_line=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' 2>"${_yaml_err:-/dev/null}"); then
      :
    else
      _awk_rc=$?
      echo "ERROR: awk による wiki.enabled 行抽出が失敗 (rc=$_awk_rc)" >&2
      [ -n "$_yaml_err" ] && [ -s "$_yaml_err" ] && head -3 "$_yaml_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "  safe-default: awk parse 失敗のため staging を中止します (silent policy-violation 防止)" >&2
      [ -n "$_yaml_err" ] && rm -f "$_yaml_err"
      exit 2
    fi
  fi
  [ -n "$_yaml_err" ] && rm -f "$_yaml_err"
  wiki_enabled=""
  if [[ -n "$wiki_enabled_line" ]]; then
    # YAML requires whitespace before inline comments; `true#comment` is a value,
    # not a commented `true`. The first sed strips comments with that in mind.
    # Wrap the whole pipe in if/else: under pipefail+set -e, a midstream failure
    # (locale, SIGPIPE, tr class differences) would abort and the user's
    # `wiki.enabled: false` setting would be silently treated as enabled. `if !`
    # would also collapse the rc to 0; if/else preserves the real exit code.
    if wiki_enabled=$(printf '%s' "$wiki_enabled_line" \
        | sed 's/[[:space:]]#.*//' \
        | sed 's/.*enabled:[[:space:]]*//' \
        | tr -d '[:space:]"'\''' \
        | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
      :
    else
      _enabled_rc=$?
      echo "ERROR: wiki.enabled 値の正規化が失敗 (rc=$_enabled_rc) — sed/tr pipeline" >&2
      echo "  safe-default: staging を中止します (silent policy-violation 防止)" >&2
      exit 2
    fi
  fi
  # `wiki_enabled_line` non-empty but normalized to empty means the YAML parser
  # produced a result the case statement can't classify (CRLF residue, locale
  # corruption, sed gobbling the value). Fail closed so a corrupt config doesn't
  # silently re-enable wiki staging the user disabled.
  if [[ -n "$wiki_enabled_line" && -z "$wiki_enabled" ]]; then
    echo "ERROR: wiki.enabled の値が正規化後 empty (元: '$wiki_enabled_line') — rite-config.yml の値を確認してください" >&2
    echo "  safe-default: staging を中止します (silent policy-violation 防止)" >&2
    exit 2
  fi
  # Explicit allowlist instead of letting unknown values silently enable
  # staging. The `""` arm represents the case where the `wiki:` section has
  # no `enabled:` key at all (lenient default = enabled). The strict guard
  # above already rejects `enabled:` with an empty value (key present but
  # value missing / commented out), so the only path that reaches the empty
  # arm here is "section absent" — preserving the historical opt-out default
  # without re-enabling typo bypass.
  case "$wiki_enabled" in
    ""|true|yes|1) ;;
    false|no|0)
      echo "ERROR: wiki.enabled is false in rite-config.yml — refusing to stage Raw Source" >&2
      echo "  hint: set wiki.enabled: true and run /rite:wiki-init first" >&2
      exit 2
      ;;
    *)
      echo "ERROR: wiki.enabled='$wiki_enabled' is not a recognised boolean (expected true|yes|1|false|no|0)" >&2
      echo "  safe-default: staging を中止します (typo による silent enable 防止)" >&2
      exit 2
      ;;
  esac
fi

# --- Slugify source-ref for filename ---
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-60 \
    | sed -E 's/-+$//'  # cut may slice mid-hyphen-run; strip the trailing dash again so slugs never end in `-`
}
slug=$(slugify "$SOURCE_REF")
if [[ -z "$slug" ]]; then
  echo "ERROR: --source-ref '$SOURCE_REF' produced an empty slug after sanitization" >&2
  exit 1
fi

# --- Anchor the write at STATE_ROOT ---
# All path-containment validation above evaluates `--content-file` against the
# ORIGINAL $PWD (and reads the body via the absolute realpath result
# $resolved_content), so they have already completed — moving cwd now does not
# relax that guard (AC-3). From here on the write must target the same root
# wiki-ingest-commit.sh scans (state-path-resolve.sh; the main checkout under a
# linked worktree), so cd into STATE_ROOT and keep target_dir relative. When
# STATE_ROOT == $PWD (single-session run from repo root, or non-git fallback)
# this is a no-op and behaviour is byte-identical to before (AC-2).
if [ "$STATE_ROOT" != "$PWD" ]; then
  # Detectable signal (re-divergence guard): surface that the raw is written to
  # the resolved state root rather than cwd, so a multi-session worktree /
  # subdirectory invocation is observable instead of silently redirecting.
  echo "NOTE: raw source を state-path-resolve ルート '$STATE_ROOT' 配下へ書き込みます (cwd='$PWD' とは別 — multi-session worktree / サブディレクトリ起動)。wiki-ingest-commit.sh の scan ルートと一致させる整合動作です。" >&2
fi
cd "$STATE_ROOT" || {
  echo "ERROR: state root '$STATE_ROOT' への cd に失敗しました — raw source の書込先を確定できません" >&2
  exit 3
}

# --- Compute target path ---
# Relative to STATE_ROOT (we cd'd into it above) so the printed path stays
# `.rite/wiki/raw/...` — the documented relative-path contract — and matches the
# relative path wiki-ingest-commit.sh resolves after its own `cd "$repo_root"`.
target_dir=".rite/wiki/raw/${TYPE}"
timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
timestamp_compact=$(date -u +"%Y%m%dT%H%M%SZ")
target_file="${target_dir}/${timestamp_compact}-${slug}.md"

# Ensure directory exists (for separate_branch strategy this only takes effect
# when /rite:wiki-ingest is later run from the wiki branch; on the dev branch
# the directory may not exist yet, so we create it on demand).
#
# Surface mkdir's root cause (permission denied / read-only filesystem /
# ancestor not a directory) — `2>/dev/null` would drop the diagnostic and
# leave the user staring at a bare "failed to create".
if ! mkdir -p "$target_dir"; then
  echo "ERROR: failed to create directory '$target_dir'" >&2
  echo "  hint: check filesystem permissions and ancestor path types" >&2
  exit 3
fi

# Escape backslash BEFORE double quote in TITLE — reversing the order would
# double-escape the backslashes that the second pass introduces, producing
# malformed YAML.
if [[ -n "$TITLE" ]]; then
  escaped_title=${TITLE//\\/\\\\}
  escaped_title=${escaped_title//\"/\\\"}
fi

# Partial-write rollback: leaving a truncated `ingested: false` Raw Source on
# disk lets the next `/rite:wiki-ingest` quietly merge incomplete content into
# a Wiki page and then flip `ingested: true`, sealing in the data loss. Arm
# the trap before the first write and disarm it just before the normal exit.
_rite_trigger_target_rollback() {
  local _rc=$1
  if [ -n "${target_file:-}" ] && [ -f "$target_file" ]; then
    rm -f "$target_file"
    echo "INFO: partial-write rollback により '$target_file' を自動削除しました (exit $_rc)" >&2
  fi
}
trap 'rc=$?; [ "$rc" -ne 0 ] && _rite_trigger_target_rollback "$rc"; exit $rc' EXIT
trap 'trap - EXIT; _rite_trigger_target_rollback 130; exit 130' INT
trap 'trap - EXIT; _rite_trigger_target_rollback 143; exit 143' TERM
trap 'trap - EXIT; _rite_trigger_target_rollback 129; exit 129' HUP

# --- Write Raw Source with YAML frontmatter ---
{
  printf -- '---\n'
  printf 'type: %s\n' "$TYPE"
  # Emit SOURCE_REF as a double-quoted YAML scalar so structural characters
  # (#, [, {, &, !, *) cannot be reinterpreted by the parser. Mirror the
  # TITLE escaping rules so both fields survive the same adversarial input.
  escaped_source_ref=${SOURCE_REF//\\/\\\\}
  escaped_source_ref=${escaped_source_ref//\"/\\\"}
  printf 'source_ref: "%s"\n' "$escaped_source_ref"
  printf 'captured_at: "%s"\n' "$timestamp_iso"
  if [[ -n "$PR_NUMBER" ]]; then
    printf 'pr_number: %s\n' "$PR_NUMBER"
  fi
  if [[ -n "$ISSUE_NUMBER" ]]; then
    printf 'issue_number: %s\n' "$ISSUE_NUMBER"
  fi
  if [[ -n "$TITLE" ]]; then
    printf 'title: "%s"\n' "$escaped_title"
  fi
  printf 'ingested: false\n'
  # `ingest_status` / `skip_reason` are intentionally NOT emitted at creation
  # (Sub-3): a raw source starts un-ingested with no skip status.
  # When `/rite:wiki-ingest` ステップ 5 decides to skip a raw, it adds
  # `ingest_status: skipped` + `skip_reason: "..."` to that raw's frontmatter.
  # Absence of `ingest_status` means "not skipped" (wiki-lint-skipped-refs.sh
  # treats it permissively — AC-6). The skip SoT lives here, not in log.md.
  printf -- '---\n\n'
  # `set -e` is suppressed on the LHS of `||`, so cat failures must be checked
  # explicitly. Reading from `$resolved_content` (the realpath result) instead
  # of `$CONTENT_FILE` closes the TOCTOU window where a symlink swap between
  # the `-L` check and the read could let the containment guard be bypassed.
  cat "$resolved_content" || { echo "ERROR: cat failed for '$resolved_content' (resolved from '$CONTENT_FILE')" >&2; exit 3; }
  # Ensure trailing newline
  printf '\n'
} > "$target_file" || {
  echo "ERROR: failed to write '$target_file'" >&2
  exit 3
}

if [[ ! -s "$target_file" ]]; then
  echo "ERROR: '$target_file' was created but is empty" >&2
  exit 3
fi

# Integrity verification: detect partial writes where frontmatter landed but
# the body is missing/truncated. A 3-state machine is required because a
# 2-state version would mis-count `---` lines that appear in the body as
# markdown horizontal rules or nested YAML markers — closing fm twice and
# treating valid files as incomplete.
#   - in_fm == 0: before frontmatter (waiting for the first `---`)
#   - in_fm == 1: inside frontmatter (waiting for the closing `---`)
#   - in_fm == 2: after frontmatter (body region — `---` is plain text)
# `cmd && a || b` would conflate "integrity check failed (rc=1)" with
# "awk binary IO / syntax error (rc>=2)" — both ending up as "incomplete"
# and triggering the rm hint, including for transient awk failures. Branch
# on the exit code explicitly so unexpected awk failures surface a WARNING
# instead of falsely telling the operator to delete the file.
awk_rc=0
awk '
  BEGIN { in_fm = 0 }
  /^---$/ {
    if (in_fm < 2) { in_fm++; next }
  }
  in_fm == 2 && NF > 0 { body_seen = 1; exit }
  END { exit !(in_fm == 2 && body_seen) }
' "$target_file" || awk_rc=$?
case "$awk_rc" in
  0) expected_status="ok" ;;
  1) expected_status="incomplete" ;;
  *)
    echo "WARNING: awk integrity check failed unexpectedly (rc=$awk_rc) for '$target_file' — treating as incomplete to fail safe" >&2
    expected_status="incomplete"
    ;;
esac
if [ "$expected_status" = "incomplete" ]; then
  echo "ERROR: '$target_file' integrity check failed (frontmatter present but body missing/truncated)" >&2
  echo "  対処: ファイルを削除して再実行してください: rm '$target_file'" >&2
  exit 3
fi

# All post-conditions (including the integrity check above) passed, so the
# normal exit must not delete the file. Disarming the trap before printing
# the path is the only thing that protects the result from the rollback hook.
trap - EXIT INT TERM HUP

# Print the relative path so callers (e.g. /rite:wiki-ingest) can pick it up
printf '%s\n' "$target_file"
