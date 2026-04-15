#!/bin/bash
# rite workflow - Wiki Ingest Trigger
#
# Saves a Raw Source artifact under .rite/wiki/raw/{type}/ so that the
# /rite:wiki:ingest command can later read & integrate it into Wiki pages.
#
# This script is the staging primitive for the Ingest cycle described in
# docs/designs/experience-heuristics-persistence-layer.md (F2). It does not
# perform LLM integration itself — that responsibility belongs to
# /rite:wiki:ingest (commands/wiki/ingest.md). The script's only job is to
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
#     (separate_branch strategy) is left to /rite:wiki:ingest, which has the
#     full branch-switching machinery.
#   - The script does NOT do any LLM work — it is a pure file-writing utility.
set -euo pipefail

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
integration by /rite:wiki:ingest.

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
# F-07 fix + F-14 fix: reject all ASCII control chars to prevent YAML frontmatter injection
# F-14: 改行/CR/タブ以外の制御文字 (0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F, 0x7F) もフィルタ
if [[ "$SOURCE_REF" =~ [[:cntrl:]] ]]; then
  echo "ERROR: --source-ref must not contain control characters (newlines, tabs, or other ASCII control chars)" >&2
  echo "  reason: control characters can break YAML frontmatter (early --- close, key injection, escape sequences)" >&2
  exit 1
fi

# F-09 fix: validate PR_NUMBER / ISSUE_NUMBER as positive integers BEFORE write
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

# F-08 fix + F-14 fix: reject all ASCII control chars in TITLE (SOURCE_REF と対称)
if [[ -n "$TITLE" ]]; then
  if [[ "$TITLE" =~ [[:cntrl:]] ]]; then
    echo "ERROR: --title must not contain control characters (newlines, tabs, or other ASCII control chars)" >&2
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
# cycle 3 fix (F-16): path containment + symlink 拒否。
# LLM 駆動フローからの prompt injection で /etc/passwd 等を渡され、
# 後続 /rite:wiki:ingest が wiki ブランチへ commit & push する exfiltration 経路を防ぐ。
if [[ -L "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file '$CONTENT_FILE' is a symlink (rejected for security)" >&2
  echo "  hint: provide the actual file, not a symlink" >&2
  exit 1
fi
if [[ ! -f "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file '$CONTENT_FILE' does not exist or is not a regular file" >&2
  exit 1
fi
# Path containment: $PWD 配下または /tmp/rite-* のみ許可
# F-01 fix: realpath 失敗時を fail-fast にする (silent bypass 防止)
resolved_content=$(realpath -- "$CONTENT_FILE") || {
  echo "ERROR: realpath failed for '$CONTENT_FILE' — cannot verify path containment" >&2
  echo "  hint: ensure the file exists and realpath is available (coreutils)" >&2
  exit 1
}
# F-02 fix: /tmp/* → /tmp/rite-* に制限 (exfiltration 経路の縮小)
# F-11 fix: macOS では /tmp → /private/tmp の symlink があり、realpath 解決後は
#   /private/tmp/rite-* が返る。同じ信頼境界 (owner-managed /tmp/rite- namespace) として
#   allowlist に追加する。exfiltration リスク増加なし (どちらも owner-writable /tmp 直下の rite prefix)
case "$resolved_content" in
  "$PWD"/*|/tmp/rite-*|/private/tmp/rite-*)
    : # allowed ($PWD 配下 / /tmp/rite-* / /private/tmp/rite-* — 後者は macOS realpath 解決後)
    ;;
  *)
    echo "ERROR: --content-file must be under \$PWD or /tmp/rite-* (macOS: /private/tmp/rite-*)" >&2
    echo "  resolved path: $resolved_content" >&2
    echo "  hint: copy the file into the project directory first" >&2
    exit 1
    ;;
esac
if [[ ! -s "$CONTENT_FILE" ]]; then
  echo "ERROR: --content-file '$CONTENT_FILE' is empty" >&2
  exit 1
fi

# --- Wiki enable check (best-effort: only checks rite-config.yml in CWD) ---
# This guard is intentionally lenient: when rite-config.yml is absent, we
# proceed and let /rite:wiki:ingest handle the strict validation later. The
# trigger only refuses when wiki.enabled is explicitly false.
#
# F-01 fix: avoid `set -euo pipefail` × `grep no-match` silent abort.
# When `wiki:` section or `enabled:` key is missing, grep returns exit 1, which
# under pipefail aborts the entire script. We split the pipeline into stages and
# explicitly tolerate empty results so missing keys lenient-fall-through to "not false".
#
# Note — YAML パースロジック同期: 本ブロックの YAML パースは以下の 4 箇所に同型のロジックが存在する
# (F-23 修正版: awk + YAML コメント除去 + クォート除去):
#   1. 本スクリプト (wiki-ingest-trigger.sh) — lenient (false/no/0 のみ reject)
#   2. hooks/scripts/wiki-ingest-commit.sh — `parse_wiki_scalar` helper、lenient だが stderr 退避は
#      簡素化されている (shell deterministic commit path 用、MEDIUM #8 in PR #529 で sync 範囲に追加)
#   3. hooks/scripts/wiki-growth-check.sh — lenient (layer 3 growth stall 検出用。wiki.enabled /
#      wiki.branch_name / wiki.growth_check.threshold_prs を参照。PR #529 cycle 2 MEDIUM で sync 範囲に追加)
#   4. commands/wiki/ingest.md Phase 1.1 — strict 4 分岐 (page integration 用)
# パース方式を変更する場合は 4 箇所全てを同期すること。wiki-patterns.md の reference パターンも参照先。
if [[ -f "rite-config.yml" ]]; then
  # cycle 9 MEDIUM fix: sed/awk の stderr を tempfile に捕捉 (silent swallow 禁止)。
  # 旧実装 `2>/dev/null || wiki_section=""` は grep no-match だけでなく sed/awk の構文エラー /
  # binary 破損 / IO エラーも silent に空扱いし、Wiki enable check が誤動作する経路を持っていた。
  _yaml_err=$(mktemp /tmp/rite-wiki-trigger-yaml-err-XXXXXX 2>/dev/null) || _yaml_err=""
  if wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>"${_yaml_err:-/dev/null}"); then
    :  # success (sed no-match は exit 0 なので legitimate)
  else
    _sed_rc=$?
    echo "WARNING: sed による rite-config.yml wiki セクション抽出が失敗 (rc=$_sed_rc)" >&2
    [ -n "$_yaml_err" ] && [ -s "$_yaml_err" ] && head -3 "$_yaml_err" | sed 's/^/  /' >&2
    echo "  lenient fallback: wiki セクションを空として扱い、enable check を継続します" >&2
    wiki_section=""
  fi
  wiki_enabled_line=""
  if [[ -n "$wiki_section" ]]; then
    # awk -- skip non-matches gracefully (exit 0 even with no output)
    if ! wiki_enabled_line=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' 2>"${_yaml_err:-/dev/null}"); then
      _awk_rc=$?
      echo "WARNING: awk による wiki.enabled 行抽出が失敗 (rc=$_awk_rc)" >&2
      [ -n "$_yaml_err" ] && [ -s "$_yaml_err" ] && head -3 "$_yaml_err" | sed 's/^/  /' >&2
      echo "  lenient fallback: wiki.enabled を未設定として扱います" >&2
      wiki_enabled_line=""
    fi
  fi
  [ -n "$_yaml_err" ] && rm -f "$_yaml_err"
  wiki_enabled=""
  if [[ -n "$wiki_enabled_line" ]]; then
    # cycle 3 fix (F-23): YAML 仕様上 inline コメントの直前にスペースが必須。
    # `true#comment` (スペースなし) は値の一部であり、`sed 's/#.*//'` は誤動作する。
    wiki_enabled=$(printf '%s' "$wiki_enabled_line" | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'\''' | tr '[:upper:]' '[:lower:]')
  fi
  case "$wiki_enabled" in
    false|no|0)
      echo "ERROR: wiki.enabled is false in rite-config.yml — refusing to stage Raw Source" >&2
      echo "  hint: set wiki.enabled: true and run /rite:wiki:init first" >&2
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
    | sed -E 's/-+$//'  # cycle 3 fix (F-07): cut 境界の末尾ハイフンを再 strip
}
slug=$(slugify "$SOURCE_REF")
if [[ -z "$slug" ]]; then
  echo "ERROR: --source-ref '$SOURCE_REF' produced an empty slug after sanitization" >&2
  exit 1
fi

# --- Compute target path ---
target_dir=".rite/wiki/raw/${TYPE}"
timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
timestamp_compact=$(date -u +"%Y%m%dT%H%M%SZ")
target_file="${target_dir}/${timestamp_compact}-${slug}.md"

# Ensure directory exists (for separate_branch strategy this only takes effect
# when /rite:wiki:ingest is later run from the wiki branch; on the dev branch
# the directory may not exist yet, so we create it on demand).
#
# F-13 fix: do NOT silently suppress mkdir stderr. Surface root cause
# (permission denied / read-only filesystem / ancestor not a directory).
if ! mkdir -p "$target_dir"; then
  echo "ERROR: failed to create directory '$target_dir'" >&2
  echo "  hint: check filesystem permissions and ancestor path types" >&2
  exit 3
fi

# F-08 fix: properly escape backslash before double-quote in TITLE
#   - escape backslash first (otherwise the next escape doubles them)
#   - then escape double quote
if [[ -n "$TITLE" ]]; then
  escaped_title=${TITLE//\\/\\\\}
  escaped_title=${escaped_title//\"/\\\"}
fi

# cycle 9 CRITICAL fix: partial-write rollback trap.
# 旧実装は integrity check 失敗 / cat mid-write failure で exit 3 する経路で $target_file を
# 残したままユーザーに手動削除を指示していた。stderr を見逃した / hook 経由実行時に次の
# /rite:wiki:ingest が truncated Raw Source を `ingested: false` として読み込み、LLM が不完全な
# 内容を Wiki ページに統合した後 `ingested: true` で永久封印する silent data degradation 経路があった。
# trap を武装して非 0 exit 経路で target_file を自動削除し、正常経路の直前で trap を解除する。
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
  # cycle 3 fix (F-15): SOURCE_REF を double-quoted YAML scalar にして YAML 構造文字
  # (#, [, {, &, !, *) が plain scalar として誤解釈される injection を防ぐ。
  # TITLE と対称のエスケープ処理を適用する。
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
  printf -- '---\n\n'
  # F-02 fix: cat 失敗を明示検査 (set -e は || の LHS で抑制されるため silent swallow を防ぐ)
  # cycle 6 fix: TOCTOU 緩和 — realpath 解決済みパス ($resolved_content) を cat に使用する。
  # symlink check (-L) と realpath 解決の間にファイルが symlink に差し替えられた場合でも、
  # realpath が解決した実パスから読み込むことで path containment bypass を緩和する。
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

# F-21 fix: integrity verification — partial-write 検出
# (frontmatter のみが書き込まれて body 部分が欠落する truncated 書き込みを catch)
#
# cycle 2 H1 fix: body に `---` (markdown 水平線 / 別 YAML マーカー) を含む Raw Source を
# 誤検出していた問題を修正する。state machine を 3 値化し、frontmatter が closed (in_fm == 2)
# した後は `^---$` パターンを fm_close カウンタに反映しない。
#   - in_fm == 0: frontmatter 開始前 (1 つ目の `---` を待つ)
#   - in_fm == 1: frontmatter 内 (2 つ目の `---` を待つ)
#   - in_fm == 2: frontmatter 終了後 (body 領域 — `---` は通常テキストとして扱う)
expected_status=$(awk '
  BEGIN { in_fm = 0 }
  /^---$/ {
    if (in_fm < 2) { in_fm++; next }
    # in_fm == 2: body 内の `---` は水平線等の通常テキストとして扱う
  }
  in_fm == 2 && NF > 0 { body_seen = 1; exit }
  END { exit !(in_fm == 2 && body_seen) }
' "$target_file" && echo "ok" || echo "incomplete")
if [ "$expected_status" = "incomplete" ]; then
  echo "ERROR: '$target_file' integrity check failed (frontmatter present but body missing/truncated)" >&2
  echo "  対処: ファイルを削除して再実行してください: rm '$target_file'" >&2
  exit 3
fi

# cycle 9 CRITICAL fix: integrity check も含めてすべての post-condition を通過したため、
# partial-write rollback trap を解除する (正常経路で target_file を保護)。
trap - EXIT INT TERM HUP

# Print the relative path so callers (e.g. /rite:wiki:ingest) can pick it up
printf '%s\n' "$target_file"
