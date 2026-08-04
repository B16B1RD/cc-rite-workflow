#!/usr/bin/env bash
# wiki-index-update.sh
#
# Deterministic implementation of wiki/ingest.md ステップ 6 (index.md の更新).
# Updates the 5-column GFM table (ページ / ドメイン / サマリー / 更新日 / 確信度)
# in the `## ページ一覧` section of index.md, then reclaims duplicate rows and
# syncs the `## 統計` section. The LLM only substitutes page metadata into the
# invocation and reads the result markers — all line manipulation happens here.
#
# Why a helper:
#   The prose procedure (identification predicate, escaping, positional summary
#   extraction, stats sync) is a deterministic algorithm. Keeping it as prose in
#   SKILL.md made review⇄fix loops re-litigate the wording (the prose-only fix
#   of this step diverged over multiple runs) while code+test anchored changes
#   converged. Moving the algorithm here gives the loop a code anchor and
#   removes LLM Edit application variance.
#
# ── Spec (moved 1:1 from wiki-ingest SKILL.md ステップ 6) ────────────────────
#
# Registration-row identification predicate (procedures 1 / 2 / 3 shared):
#   Within the range from the `## ページ一覧` heading to the next `##` heading,
#   a row is any line starting with `|` (header row and separator row excluded).
#   The row "registers" the page identified by the `{domain}/{slug}` pair of
#   the FIRST occurrence of `](pages/{domain}/{slug}.md)` in that line — page
#   identity is the page path, so two pages sharing a slug across domains are
#   distinct pages (a slug-only key would delete one of them as a "duplicate"
#   in procedure 3a). The page column is defined as
#   "from the leading `|` to the closing paren of that first link" — NOT "the
#   first `|`-split cell" — because a title containing an unescaped raw `|`
#   pushes the link into later cells and cell-splitting would fail to identify
#   the existing row (procedure 1 would then add a duplicate the same predicate
#   in procedure 3 could not reclaim). Looking only at the FIRST link makes
#   cross-reference links in the summary column automatically non-identifying.
#   The predicate is positional, NOT "lines GFM renders as table rows": a blank
#   line inside the section makes GFM render only the leading block as a table,
#   so a rendering-based predicate would miss real registration rows.
#
# Abort clause (procedures 1 / 2 ONLY):
#   If identification finds 2+ rows for the target page, emit WARNING and abort
#   this page's add/update (no "take the first match" fallback — that would
#   silently rewrite the wrong row). Procedure 3a is explicitly NOT subject to
#   this clause: it takes the 2+ row state as input and deletes the later rows.
#   Applying the abort clause to 3a as well would permanently wedge the index
#   (1/2 abort forever, and the only repair path is closed too).
#
# Cell-delimiter escaping (applied on both the add and update paths):
#   (a) frontmatter-derived raw values (--title / --description): escape `\` to
#       `\\` first, then `|` to `\|` (so a value containing a literal `\|` is
#       not misread by GFM consuming the backslash). Inline code spans are NOT
#       exempt — GFM treats a raw `|` inside a code span as a cell delimiter.
#       Rewording the value to avoid `|` is prohibited (the title contract
#       requires literal identity with frontmatter `title`).
#   (b) summary values preserved from an existing row: already-escaped text —
#       do NOT re-escape (re-escaping `\|` would grow one `\` per update cycle,
#       unrecoverably). Only a raw `|` whose preceding character is not `\` is
#       escaped.
#   Escaping applies to the index registration row only; page frontmatter is
#   never modified. {path}/{domain}/{updated}/{confidence} are slug / enum /
#   ISO 8601 values that cannot contain `|` (validated below, fail-loud).
#
# Procedure 0 (unconditional, every invocation):
#   If the `## ページ一覧` section is missing, create the heading + the 2 table
#   header lines. Insertion position: after existing body / HTML comments —
#   directly before `## 統計` if that section exists, else at EOF. If the
#   section exists but the header/separator rows are missing, insert them right
#   after the heading (before existing registration rows). Blank lines between
#   `|`-starting lines inside the section are removed (a blank line splits the
#   GFM table block and the rows after it stop rendering as a table).
#
# Procedure 1 (add):
#   If a row already matches the predicate, route to procedure 2 instead (no
#   double registration). Old-format bullet lines OUTSIDE the table never count
#   as registration (a page that only has a bullet line is added as new; the
#   old bullet is left untouched — GFM keeps them as a separate block).
#   Otherwise append to the end of the table:
#     | [{title}]({path}) | {domain} | {description} | {updated} | {confidence} |
#   {path} keeps the `pages/{domain}/{slug}.md` shape (wiki-lint-orphans.sh
#   greps `](pages/...)` for survival). {updated}/{confidence} carry no YAML
#   quotes.
#
# Procedure 2 (update):
#   Regenerate the identified row whole in the procedure-1 format (never edit a
#   single cell by counting columns). Summary column resolution order:
#     (1) --description non-empty -> that value (escape rule (a));
#     (2) empty -> PRESERVE the existing row's summary (rule (b) escaping only).
#   Never overwrite an accumulated summary with an empty string — description
#   is optional in the page schema and summary regeneration only happens at
#   page creation, so the accumulated value is unrecoverable.
#   Positional extraction of the existing summary: take everything after the
#   page column, split by `|`; the first and last fragments stem from the
#   leading/trailing delimiters and are always blank — drop them. Of the rest,
#   the head is the domain cell, the LAST TWO are updated/confidence, and
#   everything in between re-joined with `|` is the summary. Counting from the
#   end is deterministic even when a raw `|` remains in the summary, because
#   updated (ISO 8601) and confidence (enum) cannot contain `|`. This also
#   heals rows previously misaligned by a raw `|` back to a proper 5 columns.
#
# Procedure 3a (duplicate-row reclamation, runs every invocation):
#   For any page whose predicate matches 2+ rows, delete the later rows. Not
#   gated on the stats section or stats sync success. Unregistered pages and
#   old-format bullet-only pages are left to wiki-lint (speculatively adding or
#   deleting pages not read this cycle would destroy the orphan-detection
#   signal).
#
# Procedure 3b (`## 統計` 3-line sync):
#   Only when the `## 統計` section exists (never create it). total = count of
#   `*.md` files under --pages-root (non-page files like .gitkeep excluded by
#   the `*.md` filter); breakdown = per-domain `*.md` counts; 最終更新 = this
#   invocation's --updated. When the pages listing fails or is empty, emit a
#   WARNING and skip the sync (keeping the previous cycle's values is safer
#   than overwriting correct stats with an undercount). Line shapes follow the
#   existing lines (`- 総ページ数: {n}` / `- ドメイン別: patterns={n},
#   heuristics={n}, anti-patterns={n}` / `- 最終更新: {updated}`); a missing
#   line is warned about and skipped, never invented. A total that differs from
#   the table's row count triggers nothing here — duplicates were reclaimed by
#   3a and unregistered pages are wiki-lint's job.
#
# ── Interface ────────────────────────────────────────────────────────────────
#
# Inputs:
#   --index PATH        index.md path, resolved by the caller per branch
#                       strategy (required; must exist and be readable)
#   --title VALUE       page frontmatter `title` raw value (required)
#   --domain VALUE      patterns|heuristics|anti-patterns (required)
#   --slug VALUE        page slug, [A-Za-z0-9._-]+ (required)
#   --description VALUE summary raw value; empty/omitted = preserve existing
#                       summary on the update path (optional)
#   --updated VALUE     ISO 8601 timestamp, no `|` (required)
#   --confidence VALUE  high|medium|low (required)
#   --pages-root DIR    pages/ directory for procedure 3b counting (optional;
#                       when omitted and `## 統計` exists, 3b is skipped with a
#                       WARNING)
#
# stdout contract (the LLM transcribes these markers; no other write channel):
#   row_action={added|updated|aborted_duplicate}
#   dedup_removed={n}
#   stats_sync={synced|skipped_no_section|skipped_unreadable}
#   [CONTEXT] WIKI_INDEX_UPDATE=row_action={...}; dedup_removed={n}; stats_sync={...}
#
# Exit codes:
#   0  normal (aborted_duplicate included — 3a ran as the repair path)
#   1  fail-loud (index.md missing/unreadable, duplicated `## ページ一覧`
#      heading, write failure — nothing is partially applied: the file is
#      rewritten once via tmp + mv only on full success)
#   2  invocation error (missing/invalid arguments)
#
# NOTE on shell flags: sibling helpers と同じく per-command rc 管理のため
# `set -e` は意図的に設定しない。

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"

# C0+DEL detection that lets UTF-8 multibyte content pass. The shared
# contains_ctrl() also rejects C1 bytes (0x80-0x9f) byte-wise, which
# false-positives on UTF-8 continuation bytes — its in-repo callers pass
# ASCII-fixed values, but title/description here are Japanese frontmatter
# text. A raw C1 byte is invalid UTF-8 to begin with; the row-integrity
# concern is C0 (newline breaks the single-row model) + DEL.
_has_c0_del() {
  local _in_bytes _stripped_bytes
  _in_bytes=$(printf '%s' "$1" | LC_ALL=C wc -c) || return 0
  _stripped_bytes=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C wc -c) || return 0
  _in_bytes=${_in_bytes//[[:space:]]/}
  _stripped_bytes=${_stripped_bytes//[[:space:]]/}
  case "${_in_bytes}:${_stripped_bytes}" in
    *[!0-9:]*|:*|*:) return 0 ;;
  esac
  [ "$_in_bytes" -ne "$_stripped_bytes" ]
}

index_path=""
title=""
domain=""
slug=""
description=""
updated=""
confidence=""
pages_root=""

usage() {
  cat <<'EOF'
Usage: wiki-index-update.sh --index PATH --title VALUE --domain DOMAIN --slug SLUG \
         [--description VALUE] --updated TS --confidence LEVEL [--pages-root DIR]

Applies wiki-ingest ステップ 6 (index.md registration-row add/update, duplicate
reclamation, stats sync) deterministically. See the header comment for the spec.
EOF
}

# `shift; shift` (not `shift 2`): a valueless flag at the end of argv leaves
# $#=1, where `shift 2` returns rc=1 WITHOUT consuming — with no `set -e` the
# while loop then spins forever. Two single shifts always consume (the second
# is a no-op at $#=0), so the empty value falls through to the required-value
# guards below and exits 2 as documented (suite: tests/shift2-loop-hardening.test.sh).
while [ $# -gt 0 ]; do
  case "$1" in
    --index)       index_path="${2-}"; shift; shift ;;
    --title)       title="${2-}"; shift; shift ;;
    --domain)      domain="${2-}"; shift; shift ;;
    --slug)        slug="${2-}"; shift; shift ;;
    --description) description="${2-}"; shift; shift ;;
    --updated)     updated="${2-}"; shift; shift ;;
    --confidence)  confidence="${2-}"; shift; shift ;;
    --pages-root)  pages_root="${2-}"; shift; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "ERROR: wiki-index-update: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── Invocation validation (exit 2) ──────────────────────────────────────────
[ -n "$index_path" ] || { echo "ERROR: wiki-index-update: --index is required" >&2; exit 2; }
[ -n "$title" ] || { echo "ERROR: wiki-index-update: --title is required (must equal page frontmatter title)" >&2; exit 2; }
[ -n "$slug" ] || { echo "ERROR: wiki-index-update: --slug is required" >&2; exit 2; }
[ -n "$updated" ] || { echo "ERROR: wiki-index-update: --updated is required" >&2; exit 2; }
case "$domain" in
  patterns|heuristics|anti-patterns) ;;
  *) echo "ERROR: wiki-index-update: --domain must be patterns|heuristics|anti-patterns (got: '$(printf '%s' "$domain" | neutralize_ctrl)')" >&2; exit 2 ;;
esac
case "$confidence" in
  high|medium|low) ;;
  *) echo "ERROR: wiki-index-update: --confidence must be high|medium|low (got: '$(printf '%s' "$confidence" | neutralize_ctrl)')" >&2; exit 2 ;;
esac
case "$slug" in
  *[!A-Za-z0-9._-]*) echo "ERROR: wiki-index-update: --slug must match [A-Za-z0-9._-]+ (got: '$(printf '%s' "$slug" | neutralize_ctrl)')" >&2; exit 2 ;;
esac
# updated feeds both the row and the stats line; a `|` (or any control char)
# would break the no-escape assumption for that column — reject, never escape.
case "$updated" in
  *'|'*) echo "ERROR: wiki-index-update: --updated must not contain '|' (got: '$(printf '%s' "$updated" | neutralize_ctrl)')" >&2; exit 2 ;;
esac
if _has_c0_del "$updated"; then
  echo "ERROR: wiki-index-update: --updated contains control characters" >&2; exit 2
fi
# title/description become single-row cell content: a newline (or any control
# char) cannot be represented in one table row — reject rather than mangle.
if _has_c0_del "$title"; then
  echo "ERROR: wiki-index-update: --title contains control characters (multi-line titles cannot form a table row)" >&2; exit 2
fi
if _has_c0_del "$description"; then
  echo "ERROR: wiki-index-update: --description contains control characters (multi-line summaries cannot form a table row)" >&2; exit 2
fi

# ── Fail-loud preconditions (exit 1) ────────────────────────────────────────
if [ ! -f "$index_path" ]; then
  echo "ERROR: wiki-index-update: index.md not found: $index_path" >&2; exit 1
fi
if [ ! -r "$index_path" ]; then
  echo "ERROR: wiki-index-update: index.md not readable: $index_path" >&2; exit 1
fi

heading_count=$(LC_ALL=C grep -c '^##[[:blank:]]*ページ一覧[[:blank:]]*$' "$index_path")
if [ "$heading_count" -gt 1 ]; then
  echo "ERROR: wiki-index-update: index.md has $heading_count '## ページ一覧' headings — ambiguous target, refusing to guess (fix the index structure first)" >&2
  exit 1
fi

tmp_dir=$(dirname "$index_path")
tmp_rows=$(mktemp "$tmp_dir/.wiki-index-update.rows.XXXXXX") || { echo "ERROR: wiki-index-update: mktemp failed in $tmp_dir" >&2; exit 1; }
result_file=$(mktemp) || { rm -f "$tmp_rows"; echo "ERROR: wiki-index-update: mktemp failed" >&2; exit 1; }
trap 'rm -f "$tmp_rows" "$result_file"' EXIT

# ── Procedures 0 / 1 / 2 / 3a (single awk pass, buffered) ───────────────────
# Values are passed via ENVIRON (awk -v applies C-escape processing and would
# corrupt a literal backslash in the title). LC_ALL=C keeps substr/length
# byte-based; the per-byte scan only compares ASCII `\` and `|`, so UTF-8
# multibyte content passes through unchanged.
WIU_TITLE="$title" WIU_DOMAIN="$domain" WIU_SLUG="$slug" \
WIU_DESCRIPTION="$description" WIU_UPDATED="$updated" WIU_CONFIDENCE="$confidence" \
WIU_RESULT_FILE="$result_file" \
LC_ALL=C awk '
  # escape rule (a): frontmatter-derived raw value
  function esc_frontmatter(s,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\")     out = out "\\\\"
      else if (c == "|") out = out "\\|"
      else               out = out c
    }
    return out
  }
  # escape rule (b): preserved summary — only a raw `|` not preceded by `\`
  function esc_preserved(s,   out, i, c, prev) {
    out = ""; prev = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "|" && prev != "\\") out = out "\\|"
      else                          out = out c
      prev = c
    }
    return out
  }
  function trim(s) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
    return s
  }
  function is_heading(s)   { return s ~ /^##[^#]/ || s ~ /^##$/ }
  function is_list_head(s) { return s ~ /^##[ \t]*ページ一覧[ \t]*$/ }
  function is_stats_head(s){ return s ~ /^##[ \t]*統計[ \t]*$/ }
  function is_pipe_row(s)  { return s ~ /^\|/ }
  function is_header_row(s){ return s ~ /^\|[ \t]*ページ[ \t]*\|/ }
  function is_sep_row(s)   { return s ~ /^\|[ \t:|-]+$/ }
  # page key (`{domain}/{slug}`) of the FIRST `](pages/{domain}/{slug}.md)`
  # link; "" when none. Page identity is the path (pages/{domain}/{slug}.md),
  # so the key includes the domain — a slug-only key would misidentify two
  # pages sharing a slug across domains and silently delete one as a
  # "duplicate" in procedure 3a.
  # Also records the byte offset just past the closing paren in _link_end.
  function first_link_key(s,   path, nparts, parts) {
    if (match(s, /\]\(pages\/[^\/)]+\/[^\/)]+\.md\)/) == 0) { _link_end = 0; return "" }
    _link_end = RSTART + RLENGTH
    path = substr(s, RSTART + 2, RLENGTH - 3)          # pages/{domain}/{slug}.md
    nparts = split(path, parts, "/")
    sub(/\.md$/, "", parts[nparts])
    return parts[2] "/" parts[nparts]
  }
  function build_row(summary) {
    return "| [" esc_frontmatter(TITLE) "](pages/" DOMAIN "/" SLUG ".md) | " DOMAIN " | " summary " | " UPDATED " | " CONFIDENCE " |"
  }
  # summary of an existing row by positional extraction (see header spec)
  function extract_summary(s,   rest, n, parts, m, mid, i) {
    first_link_key(s)                                   # sets _link_end
    rest = substr(s, _link_end)
    n = split(rest, parts, "|")
    m = n - 2                                           # drop first and last fragment
    if (m < 3) return ""                                # no summary cell survives
    mid = ""
    for (i = 3; i <= n - 3; i++) mid = mid (mid == "" ? "" : "|") parts[i]
    return trim(mid)
  }

  { lines[++N] = $0 }

  END {
    TITLE = ENVIRON["WIU_TITLE"];       DOMAIN = ENVIRON["WIU_DOMAIN"]
    SLUG = ENVIRON["WIU_SLUG"];         DESCRIPTION = ENVIRON["WIU_DESCRIPTION"]
    UPDATED = ENVIRON["WIU_UPDATED"];   CONFIDENCE = ENVIRON["WIU_CONFIDENCE"]
    RESULT = ENVIRON["WIU_RESULT_FILE"]
    HEADER = "| ページ | ドメイン | サマリー | 更新日 | 確信度 |"
    SEP    = "|--------|---------|---------|--------|--------|"

    # ── locate the section ──
    H = 0
    for (i = 1; i <= N; i++) if (is_list_head(lines[i])) { H = i; break }

    # ── procedure 0: create the section when missing ──
    if (H == 0) {
      S = 0
      for (i = 1; i <= N; i++) if (is_stats_head(lines[i])) { S = i; break }
      P = (S > 0) ? S : N + 1                           # insert before ## 統計, else EOF
      for (i = N; i >= P; i--) lines[i + 4] = lines[i]
      lines[P] = "## ページ一覧"; lines[P + 1] = ""      # blank line matches index-template.md
      lines[P + 2] = HEADER; lines[P + 3] = SEP
      N += 4; H = P
      # keep a blank line between the new section and its neighbours
      if (H > 1 && lines[H - 1] != "") {
        for (i = N; i >= H; i--) lines[i + 1] = lines[i]
        lines[H] = ""; N++; H++
      }
      if (H + 4 <= N && lines[H + 4] != "") {
        for (i = N; i >= H + 4; i--) lines[i + 1] = lines[i]
        lines[H + 4] = ""; N++
      }
    }

    # section end = next `##` heading after H
    E = N + 1
    for (i = H + 1; i <= N; i++) if (is_heading(lines[i])) { E = i; break }

    # ── procedure 0: restore missing header/separator rows ──
    has_header = 0; has_sep = 0
    for (i = H + 1; i < E; i++) {
      if (is_header_row(lines[i])) has_header = 1
      else if (is_sep_row(lines[i])) has_sep = 1
    }
    ins = 0
    if (!has_header && !has_sep)      { add1 = HEADER; add2 = SEP; ins = 2 }
    else if (!has_header)             { add1 = HEADER; ins = 1 }
    else if (!has_sep)                { add1 = SEP; ins = 1 }
    if (ins > 0) {
      # insert right after the heading (before existing registration rows);
      # when a header exists and only the separator is missing, insert after it
      P = H + 1
      if (has_header && !has_sep) {
        for (i = H + 1; i < E; i++) if (is_header_row(lines[i])) { P = i + 1; break }
      }
      for (i = N; i >= P; i--) lines[i + ins] = lines[i]
      lines[P] = add1
      if (ins == 2) lines[P + 1] = add2
      N += ins; E += ins
    }

    # ── procedure 0: drop blank lines between `|` rows inside the section ──
    out_n = 0
    for (i = 1; i <= N; i++) {
      if (i > H && i < E && lines[i] ~ /^[ \t]*$/) {
        prev_pipe = 0; next_pipe = 0
        for (j = i - 1; j > H; j--) if (lines[j] !~ /^[ \t]*$/) { prev_pipe = is_pipe_row(lines[j]); break }
        for (j = i + 1; j < E; j++) if (lines[j] !~ /^[ \t]*$/) { next_pipe = is_pipe_row(lines[j]); break }
        if (prev_pipe && next_pipe) { drop[i] = 1; continue }
      }
      keep[++out_n] = i
    }
    n2 = 0
    delete map
    for (k = 1; k <= out_n; k++) {
      i = keep[k]
      n2++; buf[n2] = lines[i]
      if (i == H) H2 = n2
      if (i == E) E2 = n2
    }
    if (E > N) E2 = n2 + 1
    N = n2; H = H2; E = E2
    for (i = 1; i <= N; i++) lines[i] = buf[i]

    # ── identification over the section rows ──
    match_count = 0; last_pipe = 0
    for (i = H + 1; i < E; i++) {
      s = lines[i]
      if (!is_pipe_row(s)) continue
      last_pipe = i
      if (is_header_row(s) || is_sep_row(s)) continue
      rs = first_link_key(s)
      if (rs != "" && rs == DOMAIN "/" SLUG) { match_count++; match_idx[match_count] = i }
    }
    if (last_pipe == 0) last_pipe = H + 1                # fresh section: after separator

    # ── procedures 1 / 2 (abort clause applies here only) ──
    if (match_count >= 2) {
      printf "WARNING: wiki-index-update: %d rows register page \x27%s/%s\x27 — aborting this page\x27s add/update (no first-match fallback); procedure 3a reclaims the later rows\n", match_count, DOMAIN, SLUG > "/dev/stderr"
      row_action = "aborted_duplicate"
    } else if (match_count == 1) {
      i = match_idx[1]
      if (DESCRIPTION != "") summary = esc_frontmatter(DESCRIPTION)
      else                   summary = esc_preserved(extract_summary(lines[i]))
      lines[i] = build_row(summary)
      row_action = "updated"
    } else {
      new_row = build_row(esc_frontmatter(DESCRIPTION))
      for (i = N; i > last_pipe; i--) lines[i + 1] = lines[i]
      lines[last_pipe + 1] = new_row
      N++; if (E > last_pipe) E++
      row_action = "added"
    }

    # ── procedure 3a: reclaim duplicate rows (all pages, keep first) ──
    dedup_removed = 0
    delete seen
    n2 = 0
    for (i = 1; i <= N; i++) {
      if (i > H && i < E) {
        s = lines[i]
        if (is_pipe_row(s) && !is_header_row(s) && !is_sep_row(s)) {
          rs = first_link_key(s)
          if (rs != "") {
            if (rs in seen) { dedup_removed++; continue }
            seen[rs] = 1
          }
        }
      }
      buf2[++n2] = lines[i]
    }

    for (i = 1; i <= n2; i++) print buf2[i]
    printf "row_action=%s\n", row_action > RESULT
    printf "dedup_removed=%d\n", dedup_removed > RESULT
  }
' "$index_path" > "$tmp_rows"
awk_rc=$?
if [ "$awk_rc" -ne 0 ] || [ ! -s "$tmp_rows" ]; then
  echo "ERROR: wiki-index-update: row rewrite failed (awk rc=$awk_rc) — index.md left unmodified" >&2
  exit 1
fi

row_action=$(sed -n 's/^row_action=//p' "$result_file")
dedup_removed=$(sed -n 's/^dedup_removed=//p' "$result_file")
if [ -z "$row_action" ] || [ -z "$dedup_removed" ]; then
  echo "ERROR: wiki-index-update: row rewrite produced no result markers — index.md left unmodified" >&2
  exit 1
fi

# ── Procedure 3b: `## 統計` 3-line sync (on the buffered content) ───────────
stats_sync="skipped_no_section"
if LC_ALL=C grep -q '^##[[:blank:]]*統計[[:blank:]]*$' "$tmp_rows"; then
  pages_list=""
  if [ -z "$pages_root" ]; then
    echo "WARNING: wiki-index-update: index.md has a '## 統計' section but --pages-root was not given。誤った値で正しい統計を上書きしないため、本サイクルの統計同期をスキップします" >&2
    stats_sync="skipped_unreadable"
  # find の stderr は捨てない (読めないディレクトリがあれば errno がそのまま画面に残る)。
  # find は 1 つでも読めない経路があると非ゼロ終了するため、rc 検査が部分失敗も拾う。
  elif ! pages_list=$(find "$pages_root" -type f -name '*.md') || [ -z "$pages_list" ]; then
    echo "WARNING: wiki-index-update: pages 一覧を取得できないか 0 件です (root=$pages_root)。誤った値で正しい統計を上書きしないため、本サイクルの統計同期をスキップします" >&2
    stats_sync="skipped_unreadable"
  else
    total=$(printf '%s\n' "$pages_list" | wc -l | tr -d ' ')
    # 内訳は $pages_root を前方一致の anchor にする — 素の "/${d}/" は基点より上の
    # ディレクトリ名にも一致し、内訳だけが膨張して総数と別の述語になる。case の
    # literal 前方一致なら正規表現メタ文字を含むチェックアウトパスでも誤らない。
    counts=""
    for d in patterns heuristics anti-patterns; do
      n=0
      while IFS= read -r p; do
        case "$p" in "${pages_root}/${d}/"*) n=$((n + 1)) ;; esac
      done <<< "$pages_list"
      counts="$counts${counts:+ }$d=$n"
    done
    set -- $counts
    breakdown_patterns="${1#patterns=}"
    breakdown_heuristics="${2#heuristics=}"
    breakdown_anti="${3#anti-patterns=}"
    tmp_stats=$(mktemp "$tmp_dir/.wiki-index-update.stats.XXXXXX") || { echo "ERROR: wiki-index-update: mktemp failed in $tmp_dir" >&2; exit 1; }
    trap 'rm -f "$tmp_rows" "$result_file" "$tmp_stats"' EXIT
    WIU_TOTAL="$total" WIU_P="$breakdown_patterns" WIU_H="$breakdown_heuristics" \
    WIU_A="$breakdown_anti" WIU_UPDATED="$updated" WIU_RESULT_FILE="$result_file" \
    LC_ALL=C awk '
      { lines[++N] = $0 }
      END {
        TOTAL = ENVIRON["WIU_TOTAL"]; PN = ENVIRON["WIU_P"]; HN = ENVIRON["WIU_H"]
        AN = ENVIRON["WIU_A"]; UPDATED = ENVIRON["WIU_UPDATED"]
        RESULT = ENVIRON["WIU_RESULT_FILE"]
        S = 0
        for (i = 1; i <= N; i++) if (lines[i] ~ /^##[ \t]*統計[ \t]*$/) { S = i; break }
        E = N + 1
        for (i = S + 1; i <= N; i++) if (lines[i] ~ /^##[^#]/ || lines[i] ~ /^##$/) { E = i; break }
        f_total = 0; f_breakdown = 0; f_updated = 0
        for (i = S + 1; i < E; i++) {
          if (lines[i] ~ /^-[ \t]*総ページ数:/)   { lines[i] = "- 総ページ数: " TOTAL; f_total = 1 }
          else if (lines[i] ~ /^-[ \t]*ドメイン別:/) { lines[i] = "- ドメイン別: patterns=" PN ", heuristics=" HN ", anti-patterns=" AN; f_breakdown = 1 }
          else if (lines[i] ~ /^-[ \t]*最終更新:/)  { lines[i] = "- 最終更新: " UPDATED; f_updated = 1 }
        }
        for (i = 1; i <= N; i++) print lines[i]
        printf "stats_missing=%s%s%s\n", (f_total ? "" : " 総ページ数"), (f_breakdown ? "" : " ドメイン別"), (f_updated ? "" : " 最終更新") > RESULT
      }
    ' "$tmp_rows" > "$tmp_stats"
    awk_rc=$?
    if [ "$awk_rc" -ne 0 ] || [ ! -s "$tmp_stats" ]; then
      echo "ERROR: wiki-index-update: stats sync rewrite failed (awk rc=$awk_rc) — index.md left unmodified" >&2
      exit 1
    fi
    mv "$tmp_stats" "$tmp_rows" || { echo "ERROR: wiki-index-update: stats buffer swap failed — index.md left unmodified" >&2; exit 1; }
    stats_missing=$(sed -n 's/^stats_missing=//p' "$result_file" | tail -1)
    if [ -n "$stats_missing" ] && [ "$stats_missing" != "" ]; then
      stats_missing_trimmed=$(printf '%s' "$stats_missing" | sed 's/^ *//')
      [ -n "$stats_missing_trimmed" ] && echo "WARNING: wiki-index-update: '## 統計' 節に既存行が見つからない統計行があります (${stats_missing_trimmed})。行を新設せずスキップします" >&2
    fi
    stats_sync="synced"
  fi
fi

# ── Single atomic apply ─────────────────────────────────────────────────────
if ! mv "$tmp_rows" "$index_path"; then
  echo "ERROR: wiki-index-update: failed to write $index_path — original left unmodified" >&2
  exit 1
fi

echo "row_action=$row_action"
echo "dedup_removed=$dedup_removed"
echo "stats_sync=$stats_sync"
echo "[CONTEXT] WIKI_INDEX_UPDATE=row_action=$row_action; dedup_removed=$dedup_removed; stats_sync=$stats_sync"
exit 0
