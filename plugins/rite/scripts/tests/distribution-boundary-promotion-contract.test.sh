#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
PLUGIN_ROOT="$ROOT/plugins/rite"
failures=0
scan_root=$PLUGIN_ROOT
scan_only=false
case "$#:${1:-}" in
  0:) ;;
  2:--scan-root) scan_root=$2; scan_only=true ;;
  *) printf 'usage: %s [--scan-root DIR]\n' "$0" >&2; exit 2 ;;
esac

# These repository URLs are attribution and generated-footer targets, not
# environment-bound examples. Keep this allowlist narrow and line-oriented.
is_allowed() {
  local file=$1 line=$2
  [[ "$line" == *"https://github.com/B16B1RD/cc-rite-workflow"* ]] \
    || { [[ "$file" == "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]] \
      && [[ "$line" == *'"author": { "name": "B16B1RD" }'* ]]; }
}

report_hit() {
  local file=$1 line_no=$2 token=$3 line=$4
  if is_allowed "$file" "$line"; then
    printf 'ALLOW: %s:%s: %s — canonical rite attribution/author metadata\n' \
      "${file#"$ROOT/"}" "$line_no" "$token"
    return
  fi
  printf 'FAIL: %s:%s: environment token %s; replace examples with {owner}/{repo} or a neutral path, or keep domain-only knowledge in the project Wiki\n' \
    "${file#"$ROOT/"}" "$line_no" "$token" >&2
  failures=$((failures + 1))
}

scan_file() {
  local file=$1 line line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      *B16B1RD*) report_hit "$file" "$line_no" B16B1RD "$line" ;;
    esac
    case "$line" in
      *cc-rite-workflow*) report_hit "$file" "$line_no" cc-rite-workflow "$line" ;;
    esac
    case "$line" in
      */home/akiyoshi*) report_hit "$file" "$line_no" /home/akiyoshi "$line" ;;
    esac
    if [[ "$line" =~ /tmp/claude-[0-9]+ ]]; then
      report_hit "$file" "$line_no" "${BASH_REMATCH[0]}" "$line"
    fi
  done < "$file"
}

file_list=$(mktemp)
trap 'rm -f "$file_list"' EXIT
if ! find "$scan_root" -type f \
    \( -name '*.md' -o -name '*.sh' -o -name '*.py' -o -name '*.json' \) \
    ! -path '*/hooks/tests/*' \
    ! -path '*/scripts/tests/*' \
    -print0 > "$file_list"; then
  printf 'FAIL: cannot scan distribution boundary %s\n' "$scan_root" >&2
  exit 1
fi
while IFS= read -r -d '' file; do
  scan_file "$file"
done < "$file_list"

if [ "$failures" -ne 0 ]; then
  printf '%s distribution-boundary violation(s) found\n' "$failures" >&2
  exit 1
fi

[ "$scan_only" = true ] && exit 0

# Mutation checks pin detection, fixture exclusion, allowlist precedence, and
# actionable diagnostics independently from the repository's clean baseline.
fixture_root=$(mktemp -d)
trap 'rm -f "$file_list"; rm -rf "$fixture_root"' EXIT
while IFS='|' read -r planted expected; do
  printf '%s\n' "$planted" > "$fixture_root/leak.md"
  mutation_rc=0
  mutation_out=$(bash "$0" --scan-root "$fixture_root" 2>&1) || mutation_rc=$?
  if [ "$mutation_rc" -eq 0 ] \
    || ! grep -Fq 'leak.md:1' <<<"$mutation_out" \
    || ! grep -Fq "$expected" <<<"$mutation_out" \
    || ! grep -Fq 'replace examples with {owner}/{repo}' <<<"$mutation_out"; then
    printf '%s\n' "$mutation_out" >&2
    printf 'FAIL: planted %s token was not rejected with an actionable file/line diagnostic\n' "$expected" >&2
    exit 1
  fi
done <<'MUTATIONS'
owner=B16B1RD|B16B1RD
repo=cc-rite-workflow|cc-rite-workflow
home=/home/akiyoshi/project|/home/akiyoshi
tmp=/tmp/claude-1000/worktree|/tmp/claude-1000
MUTATIONS

mkdir -p "$fixture_root/hooks/tests"
mv "$fixture_root/leak.md" "$fixture_root/hooks/tests/environment-fixture.md"
bash "$0" --scan-root "$fixture_root" >/dev/null

printf '%s\n' 'https://github.com/B16B1RD/cc-rite-workflow' > "$fixture_root/attribution.md"
allow_out=$(bash "$0" --scan-root "$fixture_root")
grep -Fq 'ALLOW:' <<<"$allow_out" || {
  printf 'FAIL: canonical attribution allowlist did not take precedence\n' >&2
  exit 1
}

# Pin both routing surfaces so the second promotion axis cannot silently drift.
grep -Fq '環境非依存' "$ROOT/CLAUDE.md" || {
  printf 'FAIL: CLAUDE.md lacks the environment-independence promotion axis\n' >&2
  exit 1
}
grep -Fq '環境非依存' "$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md" || {
  printf 'FAIL: wiki-ingest routing lacks the environment-independence promotion axis\n' >&2
  exit 1
}
grep -Fq 'rite 挙動・スキル記述法かつ環境非依存（または一般化済み）' "$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md" || {
  printf 'FAIL: wiki-ingest promote field rule does not preserve the two-axis predicate\n' >&2
  exit 1
}

printf 'Distribution-boundary promotion contract passed.\n'
