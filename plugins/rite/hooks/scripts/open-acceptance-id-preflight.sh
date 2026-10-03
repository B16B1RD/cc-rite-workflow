#!/bin/bash
# Open acceptance-ID entry check. Uses the unchanged strict reader and safe
# Issue-body writer; only missing IDs can be repaired.
# Usage: bash open-acceptance-id-preflight.sh --issue N --repo OWNER/REPO --cwd ABS_PATH
# --repo is held at the outer entry; --cwd is validated inside this helper.
# Exit: 0 unchanged or repaired and recorded; 1 check/update failure; 2 usage.
# Output: OPEN_AC_PREFLIGHT=unchanged|failed; OPEN_AC_IDS_ASSIGNED on recorded repair.
# Safe-writer failure reasons and strict-reader diagnostics remain visible.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_root=$(cd "$script_dir/../.." && pwd)
issue="" owner_repo="" execution_cwd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue|--repo|--cwd)
      option="$1"
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "ERROR: missing value for $option" >&2; exit 2; }
      case "$option" in
        --issue) issue="$2" ;; --repo) owner_repo="$2" ;; --cwd) execution_cwd="$2" ;;
      esac
      shift; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$issue" in ''|*[!0-9]*) echo "ERROR: --issue must be numeric" >&2; exit 2 ;; esac
[ -n "$owner_repo" ] || { echo "ERROR: --repo is required" >&2; exit 2; }
case "$execution_cwd" in /*) ;; *) echo "ERROR: --cwd must be absolute" >&2; exit 2 ;; esac
cd "$execution_cwd"
repo_line=$(bash "$script_dir/lib/git-remote.sh" resolve-owner-repo)
IFS=$'\t' read -r cwd_owner cwd_repo <<< "$repo_line"
[ -n "$cwd_owner" ] && [ -n "$cwd_repo" ] &&
  [ "${cwd_owner}/${cwd_repo}" = "$owner_repo" ] || {
    echo "ERROR: repository context mismatch: expected=$owner_repo; cwd_repo=$cwd_owner/$cwd_repo" >&2
    exit 1
  }
reader="$plugin_root/scripts/acceptance-criteria-check.sh"
safe="$plugin_root/hooks/issue-body-safe-update.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/rite-open-ac-XXXXXX")
original="" candidate=""
trap 'rm -rf "$scratch"; rm -f "${original:-}" "${candidate:-}"' EXIT
stop_ac() {
  echo "ERROR: Issue #$issue の受入条件入口検査に失敗: $1" >&2
  echo "[CONTEXT] OPEN_AC_PREFLIGHT=failed; issue=$issue; reason=$1" >&2
  exit 1
}
bash "$safe" fetch --issue "$issue" > "$scratch/fetch"
cat "$scratch/fetch"
original=$(sed -n 's/^tmpfile_read=//p' "$scratch/fetch")
candidate=$(sed -n 's/^tmpfile_write=//p' "$scratch/fetch")
length=$(sed -n 's/^original_length=//p' "$scratch/fetch")
[ -n "$original" ] && [ -f "$original" ] && [ -n "$candidate" ] && [ -n "$length" ] \
  || stop_ac issue_body_fetch_failed
if bash "$reader" extract --body-file "$original" > "$scratch/ids" 2> "$scratch/check"; then
  cat "$scratch/check" >&2
  echo "[CONTEXT] OPEN_AC_PREFLIGHT=unchanged; issue=$issue"
  exit 0
fi
cat "$scratch/check" >&2
python3 - "$original" "$candidate" > "$scratch/added" <<'PY'
import re, sys
from pathlib import Path
body = Path(sys.argv[1]).read_bytes().decode('utf-8')
lines = body.splitlines(keepends=True)
sections, section, fence, width = [], None, None, 0
for index, raw in enumerate(lines):
    line = re.sub(r'^ {0,3}', '', raw.rstrip('\r\n'))
    mark = re.match(r'^\s*(`{3,}|~{3,})(.*)$', line)
    if mark:
        chars, tail = mark.groups()
        if fence is None:
            fence, width = chars[0], len(chars)
        elif chars[0] == fence and len(chars) >= width and not tail.strip():
            fence = None
        continue
    if fence is not None:
        continue
    heading = re.match(r'^(#+)\s+(.+?)\s*$', line)
    if heading:
        level, title = len(heading[1]), heading[2]
        if level <= 2:
            section = None
        title = re.sub(r'^\d+\.\s+', '', title.lower())
        if level == 2 and title in ('acceptance criteria', '受入基準', '受入条件', '受け入れ条件'):
            section = []
            sections.append(section)
    if section is not None:
        section.append((index, line))
used, missing = set(), []
for section in sections:
    for index, line in section:
        match = re.match(r'^(?:###\s+|[-*+]\s+\[[ xX]\]\s+)(AC-(\d+))(?=[:\s]|$)', line)
        if match:
            used.add(int(match[2]))
        elif re.match(r'^-\s+\[ \]\s+', line):
            content = re.sub(r'^-\s+\[ \]\s+', '', line)
            # Malformed explicit IDs are errors, not missing IDs to disguise.
            if content and not content.startswith('AC-'):
                missing.append(index)
added, number = [], 1
for index in missing:
    while number in used:
        number += 1
    identifier = f'AC-{number}'
    lines[index] = re.sub(r'^( {0,3}-\s+\[ \]\s+)', lambda m: m[1] + identifier + ': ', lines[index], count=1)
    used.add(number)
    added.append(identifier)
Path(sys.argv[2]).write_bytes(''.join(lines).encode('utf-8'))
print(','.join(added))
PY
added=$(cat "$scratch/added")
[ -n "$added" ] || stop_ac format_not_repairable
bash "$reader" extract --body-file "$candidate" > "$scratch/ids" \
  || stop_ac repaired_body_invalid
cp "$candidate" "$scratch/expected"
bash "$safe" apply --issue "$issue" --tmpfile-read "$original" \
  --tmpfile-write "$candidate" --original-length "$length" > "$scratch/apply"
cat "$scratch/apply"
# apply returns zero even on failure; only a fresh remote body can prove repair.
gh issue view "$issue" -R "$owner_repo" --json body --jq '.body' > "$scratch/fresh" \
  || stop_ac refreshed_body_fetch_failed
bash "$reader" extract --body-file "$scratch/fresh" > "$scratch/ids" \
  || stop_ac refreshed_body_invalid
# Record only the IDs actually present in the repaired remote body.
cmp -s "$scratch/expected" "$scratch/fresh" || {
  # gh adds a final newline; compare content without changing the stored body.
  python3 - "$scratch/expected" "$scratch/fresh" <<'PY'
import sys
from pathlib import Path
assert Path(sys.argv[1]).read_bytes().rstrip(b'\n') == Path(sys.argv[2]).read_bytes().rstrip(b'\n')
PY
} || stop_ac refreshed_body_mismatch
printf '%s\n' "受入条件の ID 欠落を入口で補いました。Issue #$issue / 付与 ID: $added" > "$scratch/record"
gh issue comment "$issue" -R "$owner_repo" --body-file "$scratch/record" \
  || stop_ac assignment_record_failed
echo "[CONTEXT] OPEN_AC_IDS_ASSIGNED=1; issue=$issue; ids=$added"
