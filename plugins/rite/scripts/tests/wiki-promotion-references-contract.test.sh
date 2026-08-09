#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
references_root="$repo_root/plugins/rite/references/wiki-promotions"

mapfile -t pages < <(find "$references_root" -mindepth 2 -type f -name '*.md' | sort)

if [ "${#pages[@]}" -ne 38 ]; then
  echo "expected 38 promoted Wiki references, found ${#pages[@]}" >&2
  exit 1
fi

for page in "${pages[@]}"; do
  category=$(basename "$(dirname "$page")")
  if [ "$(grep -c '^promote: rite-plugin$' "$page")" -ne 1 ]; then
    echo "promote marker must occur exactly once: ${page#"$repo_root/"}" >&2
    exit 1
  fi
  if [ "$(grep -c '^promoted_from: ' "$page")" -ne 1 ]; then
    echo "promoted_from provenance must occur exactly once: ${page#"$repo_root/"}" >&2
    exit 1
  fi
  grep -q "^type: \"$category\"$" "$page" || {
    echo "type must match category '$category': ${page#"$repo_root/"}" >&2
    exit 1
  }
  if grep -Eq '\]\([^)]*\.md(#[^)]*)?\)' "$page"; then
    echo "non-portable relative Markdown link: ${page#"$repo_root/"}" >&2
    exit 1
  fi
done

echo "wiki promotion references contract: ok (38 pages)"
