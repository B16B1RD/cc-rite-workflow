# shellcheck shell=bash
# rite workflow - `git diff -U0` hunk ranges
#
# Responsibility: turn `git diff -U0` output into per-file line ranges and
# answer "does path:start-end overlap a changed range". Shared by every helper
# that has to decide whether a cited line was touched by a diff, so the parser
# (and its header-vs-content guard) exists once.
#
# Usage (source it — the parser sets variables in the caller's shell):
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/diff-hunks.sh"
#   diff_hunks_parse <<< "$(git diff -U0 base..HEAD)"
#   range_overlaps "$plus_hunks" "path/to/file" 10 12 && echo touched
#
# diff_hunks_parse sets:
#   plus_hunks  = "path:start:end" lines, inclusive new-file ranges (new_count > 0)
#   minus_hunks = "path:start:end" lines, inclusive old-file ranges of
#                 pure-delete hunks only (new_count == 0). A hunk that also adds
#                 lines is matched through plus_hunks, so a modified line's old
#                 number never matches.
#
# range_overlaps HUNKS PATH START END returns 0 when any HUNKS record for PATH
# overlaps [START, END], 1 otherwise.

diff_hunks_parse() {
  local line current_file="" current_src="" in_hunk=0 dest
  local minus old_start old_count plus new_start new_count new_end old_end
  plus_hunks=""
  minus_hunks=""

  # ヘッダ区間（diff --git から最初の @@ まで）でだけ --- / +++ をファイルヘッダとして読む。
  # -U0 の diff では hunk 内の内容行の先頭 "++ " / "-- " がそれぞれ "+++ " / "--- " になり、
  # in_hunk のガードが無いとファイルヘッダと誤読して current_file / current_src を上書きする。
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      diff\ --git\ *)
        current_file=""
        current_src=""
        in_hunk=0
        ;;
      ---\ a/*)
        if [ "$in_hunk" -eq 0 ]; then
          current_src=${line#--- a/}
          current_src=${current_src%%$'\t'*}
        fi
        ;;
      ---\ /dev/null)
        [ "$in_hunk" -eq 0 ] && current_src=""
        ;;
      +++\ b/*)
        if [ "$in_hunk" -eq 0 ]; then
          dest=${line#+++ b/}
          dest=${dest%%$'\t'*}
          current_file="$dest"
        fi
        ;;
      +++\ /dev/null)
        [ "$in_hunk" -eq 0 ] && current_file="$current_src"
        ;;
      @@\ *)
        in_hunk=1
        [ -n "$current_file" ] || continue
        minus=${line#@@ -}
        minus=${minus%% *}
        old_start=${minus%%,*}
        if [ "$minus" = "$old_start" ]; then
          old_count=1
        else
          old_count=${minus#*,}
        fi
        case "$old_start" in ''|*[!0-9]*) old_start="" ;; esac
        case "$old_count" in ''|*[!0-9]*) old_start="" ;; esac
        plus=${line#* +}
        plus=${plus%% *}
        new_start=${plus%%,*}
        if [ "$plus" = "$new_start" ]; then
          new_count=1
        else
          new_count=${plus#*,}
        fi
        case "$new_start" in ''|*[!0-9]*) continue ;; esac
        case "$new_count" in ''|*[!0-9]*) continue ;; esac
        if [ "$new_count" -gt 0 ]; then
          new_end=$((new_start + new_count - 1))
          plus_hunks="${plus_hunks}${current_file}:${new_start}:${new_end}"$'\n'
        elif [ -n "$old_start" ] && [ "$old_count" -gt 0 ]; then
          old_end=$((old_start + old_count - 1))
          minus_hunks="${minus_hunks}${current_file}:${old_start}:${old_end}"$'\n'
        fi
        ;;
    esac
  done
}

range_overlaps() {
  local hunks="$1" f="$2" start="$3" end="$4" rec h_start h_end rest
  while IFS= read -r rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    case "$rec" in
      "$f":*)
        rest=${rec#"$f":}
        h_start=${rest%%:*}
        h_end=${rest#*:}
        if [ "$start" -le "$h_end" ] && [ "$h_start" -le "$end" ]; then
          return 0
        fi
        ;;
    esac
  done <<EOF
$hunks
EOF
  return 1
}
