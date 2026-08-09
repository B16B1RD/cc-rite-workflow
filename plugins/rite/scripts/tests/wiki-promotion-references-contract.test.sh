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
  grep -q '^promote: rite-plugin$' "$page" || {
    echo "missing promote marker: ${page#"$repo_root/"}" >&2
    exit 1
  }
  grep -q '^promoted_from: ' "$page" || {
    echo "missing promoted_from provenance: ${page#"$repo_root/"}" >&2
    exit 1
  }
done

echo "wiki promotion references contract: ok (38 pages)"
