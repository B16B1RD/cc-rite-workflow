#!/usr/bin/env bash
# wiki-okf-migrate.sh
#
# One-shot, idempotent migration of a rite Wiki bundle from the v0.1-era
# page frontmatter shape (`sources[].ref` + `updated`) to OKF v0.2
# (`sources[].resource` + `generated: {by, at}`).
#
# Invoked by /rite:wiki-ingest after wiki.enabled is confirmed true and
# the wiki root is resolved. The helper itself does not read
# rite-config.yml — the caller owns the enabled gate (AC-7).
#
# Mapping (applied to every page under pages/**.md):
#   sources[].ref  → sources[].resource  (value unchanged)
#   updated        → generated.at; generated.by = "rite-wiki-ingest/unknown"
#                    (only when generated is absent). updated key is removed.
#   other keys     unchanged
#
# After every page rewrite succeeds:
#   index.md  — set / create okf_version: "0.2"
#   SCHEMA.md — ensure type: Reference frontmatter
#   log.md    — append one human-facing migration entry
#
# Fail-loud: a single page rewrite failure exits non-zero and does NOT
# bump okf_version, so a later re-run can finish the remaining pages.
# raw/** is never opened (AC-6).
#
# Inputs:
#   --wiki-root DIR   bundle root that contains index.md / pages / SCHEMA.md / log.md
#                     (required). same_branch: .rite/wiki
#                     separate_branch: {wiki_worktree}/.rite/wiki
#
# stdout:
#   [CONTEXT] WIKI_OKF_MIGRATE=skipped; reason=already_v0.2
#   [CONTEXT] WIKI_OKF_MIGRATE=migrated; pages=N; schema=updated|unchanged; index=updated
#
# Exit codes:
#   0  skipped (already 0.2) or migrated
#   1  migration failed (page rewrite / missing index / write error)
#   2  invocation error

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"

wiki_root=""

usage() {
  cat <<'EOF'
Usage: wiki-okf-migrate.sh --wiki-root DIR

Migrate a rite Wiki bundle from v0.1-era frontmatter to OKF v0.2.
Idempotent: a bundle whose index.md already declares okf_version: "0.2"
exits 0 without touching files.

Options:
  --wiki-root DIR   Bundle root (contains index.md). Required.
  -h, --help        Show this help

Exit codes:
  0  skipped or migrated
  1  migration failed (okf_version not bumped)
  2  invocation error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --wiki-root) wiki_root="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$wiki_root" ]; then
  echo "ERROR: --wiki-root は必須です" >&2
  usage >&2
  exit 2
fi
case "$wiki_root" in "{"*"}")
  echo "ERROR: --wiki-root placeholder が literal substitute されていません (値: '$wiki_root')" >&2
  exit 2
  ;;
esac

if [ ! -d "$wiki_root" ]; then
  echo "ERROR: wiki-root がディレクトリではありません: $wiki_root" >&2
  exit 1
fi

index_path="$wiki_root/index.md"
if [ ! -f "$index_path" ]; then
  echo "ERROR: 移行対象 bundle に index.md がありません: $index_path" >&2
  echo "  wiki-init 未完了の壊れた bundle を握り込みません" >&2
  exit 1
fi

# ---- read okf_version from index.md frontmatter (absent = pre-v0.2) --------
read_okf_version() {
  awk '
    NR == 1 && /^---[[:space:]]*$/ { infm=1; next }
    infm && /^---[[:space:]]*$/ { exit }
    infm && /^okf_version:[[:space:]]*/ {
      sub(/^okf_version:[[:space:]]*/, "")
      gsub(/^["'\'']|["'\'']$/, "", $0)
      print
      exit
    }
  ' "$1"
}

current_ver=$(read_okf_version "$index_path")
if [ "$current_ver" = "0.2" ]; then
  echo "[CONTEXT] WIKI_OKF_MIGRATE=skipped; reason=already_v0.2"
  exit 0
fi

# ---- page frontmatter rewrite ----------------------------------------------
# Portable awk: rename sources[].ref → resource; drop updated; emit generated
# from the dropped updated value when generated is not already present.
migrate_page() {
  local page="$1"
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/rite-okf-page-XXXXXX") || {
    echo "ERROR: mktemp に失敗しました ($page)" >&2
    return 1
  }
  if ! awk '
    BEGIN { infm=0; in_sources=0; generated_seen=0; updated_val="" }
    NR == 1 && /^---[[:space:]]*$/ { infm=1; print; next }
    infm && /^---[[:space:]]*$/ {
      if (updated_val != "" && generated_seen == 0) {
        printf "generated: { by: \"rite-wiki-ingest/unknown\", at: \"%s\" }\n", updated_val
      }
      infm=0
      in_sources=0
      print
      next
    }
    infm && /^updated:[[:space:]]*/ {
      v = $0
      sub(/^updated:[[:space:]]*/, "", v)
      gsub(/^["'\'']|["'\'']$/, "", v)
      updated_val = v
      next
    }
    infm && /^generated:[[:space:]]*/ { generated_seen=1; print; next }
    infm && /^sources:[[:space:]]*$/ { in_sources=1; print; next }
    infm && in_sources && /^[a-zA-Z]/ { in_sources=0 }
    infm && in_sources && /^---[[:space:]]*$/ { in_sources=0 }
    infm && in_sources && /^[[:space:]]*-[[:space:]]*ref:[[:space:]]*/ {
      sub(/-[[:space:]]*ref:/, "- resource:")
      print
      next
    }
    infm && in_sources && /^[[:space:]]+ref:[[:space:]]*/ {
      indent = $0
      sub(/ref:.*$/, "", indent)
      sub(/^[[:space:]]+ref:/, indent "resource:")
      print
      next
    }
    { print }
  ' "$page" > "$tmp"; then
    echo "ERROR: $page の変換に失敗しました" >&2
    rm -f "$tmp"
    return 1
  fi
  if ! cat "$tmp" > "$page"; then
    echo "ERROR: $page への書き込みに失敗しました" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

pages_migrated=0
if [ -d "$wiki_root/pages" ]; then
  # collect first so a mid-loop find failure cannot skip remaining files silently
  page_list=$(find "$wiki_root/pages" -type f -name '*.md' | LC_ALL=C sort) || {
    echo "ERROR: pages/ の列挙に失敗しました" >&2
    exit 1
  }
  if [ -n "$page_list" ]; then
    while IFS= read -r page; do
      [ -z "$page" ] && continue
      if ! migrate_page "$page"; then
        echo "ERROR: ページ書換え失敗のため okf_version を bump せず終了します: $page" >&2
        exit 1
      fi
      pages_migrated=$((pages_migrated + 1))
    done <<EOF
$page_list
EOF
  fi
fi

# ---- SCHEMA.md: ensure type: Reference frontmatter -------------------------
schema_path="$wiki_root/SCHEMA.md"
schema_result="unchanged"
if [ -f "$schema_path" ]; then
  schema_has_type=$(awk '
    NR == 1 && /^---[[:space:]]*$/ { infm=1; next }
    infm && /^---[[:space:]]*$/ { exit }
    infm && /^type:[[:space:]]*/ { print "yes"; exit }
  ' "$schema_path")
  if [ "$schema_has_type" != "yes" ]; then
    schema_tmp=$(mktemp "${TMPDIR:-/tmp}/rite-okf-schema-XXXXXX") || {
      echo "ERROR: SCHEMA.md 用 mktemp に失敗しました" >&2
      exit 1
    }
    if [ "$(head -n 1 "$schema_path")" = "---" ]; then
      awk 'NR==1 { print; print "type: Reference"; next } { print }' "$schema_path" > "$schema_tmp" || {
        echo "ERROR: SCHEMA.md の変換に失敗しました" >&2
        rm -f "$schema_tmp"
        exit 1
      }
    else
      {
        printf '%s\n' '---' 'type: Reference' '---' ''
        cat "$schema_path"
      } > "$schema_tmp" || {
        echo "ERROR: SCHEMA.md の変換に失敗しました" >&2
        rm -f "$schema_tmp"
        exit 1
      }
    fi
    if ! cat "$schema_tmp" > "$schema_path"; then
      echo "ERROR: SCHEMA.md への書き込みに失敗しました" >&2
      rm -f "$schema_tmp"
      exit 1
    fi
    rm -f "$schema_tmp"
    schema_result="updated"
  fi
fi

# ---- index.md: set okf_version last (only after pages + schema succeed) ----
index_tmp=$(mktemp "${TMPDIR:-/tmp}/rite-okf-index-XXXXXX") || {
  echo "ERROR: index.md 用 mktemp に失敗しました" >&2
  exit 1
}
if [ "$(head -n 1 "$index_path")" = "---" ]; then
  if ! awk '
    NR == 1 && /^---[[:space:]]*$/ { infm=1; print; next }
    infm && /^---[[:space:]]*$/ {
      if (!ver_seen) print "okf_version: \"0.2\""
      infm=0
      print
      next
    }
    infm && /^okf_version:[[:space:]]*/ { print "okf_version: \"0.2\""; ver_seen=1; next }
    { print }
  ' "$index_path" > "$index_tmp"; then
    echo "ERROR: index.md の変換に失敗しました" >&2
    rm -f "$index_tmp"
    exit 1
  fi
else
  {
    printf '%s\n' '---' 'okf_version: "0.2"' '---' ''
    cat "$index_path"
  } > "$index_tmp" || {
    echo "ERROR: index.md の変換に失敗しました" >&2
    rm -f "$index_tmp"
    exit 1
  }
fi
if ! cat "$index_tmp" > "$index_path"; then
  echo "ERROR: index.md への書き込みに失敗しました" >&2
  rm -f "$index_tmp"
  exit 1
fi
rm -f "$index_tmp"

# ---- log.md: one migration entry (newest-first) ----------------------------
log_path="$wiki_root/log.md"
if [ -f "$log_path" ]; then
  today=$(date -u +%Y-%m-%d)
  log_tmp=$(mktemp "${TMPDIR:-/tmp}/rite-okf-log-XXXXXX") || {
    echo "ERROR: log.md 用 mktemp に失敗しました" >&2
    exit 1
  }
  bullet='* **Update**: Migrated bundle frontmatter to OKF v0.2 (`sources[].ref` → `resource`, `updated` → `generated`)'
  if ! awk -v today="$today" -v bullet="$bullet" '
    BEGIN { inserted=0 }
    $0 == "# Directory Update Log" {
      print
      print ""
      print "## " today
      print bullet
      inserted=1
      next
    }
    NR == 1 && $0 == "## " today {
      print
      print bullet
      inserted=1
      next
    }
    NR == 1 && !inserted {
      print "## " today
      print bullet
      print ""
      inserted=1
    }
    { print }
  ' "$log_path" > "$log_tmp"; then
    echo "ERROR: log.md の変換に失敗しました" >&2
    rm -f "$log_tmp"
    exit 1
  fi
  if ! cat "$log_tmp" > "$log_path"; then
    echo "ERROR: log.md への書き込みに失敗しました" >&2
    rm -f "$log_tmp"
    exit 1
  fi
  rm -f "$log_tmp"
fi

echo "[CONTEXT] WIKI_OKF_MIGRATE=migrated; pages=$pages_migrated; schema=$schema_result; index=updated"
exit 0
