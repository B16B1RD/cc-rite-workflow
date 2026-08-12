#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
references_root="$repo_root/plugins/rite/references/wiki-promotions"

manifest="$references_root/manifest.txt"
mapfile -t expected < <(sort "$manifest")
mapfile -t actual < <(find "$references_root" -mindepth 2 -type f -name '*.md' \
  | sed "s#^$references_root/##" | sort)

if [ "${#expected[@]}" -ne 38 ]; then
  echo "manifest must contain exactly 38 paths, found ${#expected[@]}" >&2
  exit 1
fi
if [ "${expected[*]}" != "${actual[*]}" ]; then
  echo "promoted Wiki reference inventory differs from manifest" >&2
  diff -u <(printf '%s\n' "${expected[@]}") <(printf '%s\n' "${actual[@]}") >&2 || true
  exit 1
fi

for relative_path in "${expected[@]}"; do
  page="$references_root/$relative_path"
  category=$(basename "$(dirname "$page")")
  if [ "$(grep -c '^promote: rite-plugin$' "$page")" -ne 1 ]; then
    echo "promote marker must occur exactly once: ${page#"$repo_root/"}" >&2
    exit 1
  fi
  if [ "$(grep -c '^promoted_from: ' "$page")" -ne 1 ]; then
    echo "promoted_from provenance must occur exactly once: ${page#"$repo_root/"}" >&2
    exit 1
  fi
  grep -Fqx "promoted_from: \"wiki:/pages/$relative_path\"" "$page" || {
    echo "promoted_from must match the manifest path: ${page#"$repo_root/"}" >&2
    exit 1
  }
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
