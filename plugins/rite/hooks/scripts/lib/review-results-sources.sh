# shellcheck shell=bash
# rite workflow - review-results JSON sources for one PR
#
# Responsibility: list the review-results JSON files of one PR from both
# `<results_dir>/` and `<results_dir>/archive/`. Consumers that run after the
# merge (cleanup step 6.0 helper and its 6.0.V re-verification) must read the
# archive too: the orphan review reap in pr-cycle-cleanup.sh moves a MERGED
# PR's JSON to archive/ when it runs before /rite:cleanup (session start, a
# later cleanup of another PR). Reading only the top level turns that order
# into `no_json` and the remaining findings are never transcribed.
#
# Output: one path per line, ordered by basename in byte order (LC_ALL=C,
# = cycle order; the same order nb-sweep-collect.sh uses to pick the latest
# JSON, where a same-second `{ts}.json` sorts before `{ts}~{hex}.json`). The
# collation is pinned inside the function because both the glob expansion and
# `[[ < ]]` follow the caller's locale, and en_US.UTF-8 ignores the
# punctuation that separates those two names. The two
# directories are merged by basename, not concatenated, so an archived cycle
# does not sort after every top-level one. When the same basename exists in
# both, only the top-level path is printed: the reap and the cleanup archive
# step both keep the top-level file on a name collision, and printing both
# would count one cycle twice.
#
# Usage:
#   source .../lib/review-results-sources.sh
#   rite_review_results_sources <results_dir> <pr_number> <suffix>
#     <suffix> is the glob tail after `<pr>-*`: `.json*` (JSON and its
#     `.json.corrupt-*` renames) or `.json` (JSON only).
#
# Missing directories contribute nothing. Pure bash (no pipes), bash 3.2 safe.

rite_review_results_sources() {
  local LC_ALL=C results_dir="$1" pr="$2" suffix="$3" f
  local -a top=() arc=()
  # $suffix is intentionally unquoted so its `*` stays a glob.
  # shellcheck disable=SC2086
  for f in "$results_dir/$pr"-*$suffix; do
    { [ -e "$f" ] || [ -L "$f" ]; } && top+=("$f")
  done
  # shellcheck disable=SC2086
  for f in "$results_dir/archive/$pr"-*$suffix; do
    { [ -e "$f" ] || [ -L "$f" ]; } && arc+=("$f")
  done
  local i=0 j=0 a b
  while [ "$i" -lt "${#top[@]}" ] || [ "$j" -lt "${#arc[@]}" ]; do
    if [ "$j" -ge "${#arc[@]}" ]; then
      printf '%s\n' "${top[$i]}"; i=$((i + 1)); continue
    fi
    if [ "$i" -ge "${#top[@]}" ]; then
      printf '%s\n' "${arc[$j]}"; j=$((j + 1)); continue
    fi
    a=${top[$i]##*/}
    b=${arc[$j]##*/}
    if [ "$a" = "$b" ]; then
      printf '%s\n' "${top[$i]}"; i=$((i + 1)); j=$((j + 1))
    elif [[ "$a" < "$b" ]]; then
      printf '%s\n' "${top[$i]}"; i=$((i + 1))
    else
      printf '%s\n' "${arc[$j]}"; j=$((j + 1))
    fi
  done
}
