# Wiki promotion references

This directory is the distributed source of truth for the 38 rite-specific
knowledge pages selected by the promotion audit and tracked by [`manifest.txt`](manifest.txt).

## Promotion policy

- Every page in `anti-patterns/`, `heuristics/`, and `patterns/` uses the
  **full-text promotion** policy. No page in this batch is summary-only.
- The corresponding Wiki page remains as a discovery pointer. It keeps
  `promote: rite-plugin` and records the distributed path in `reference`.
- `sources[].ref` values and inline `Wiki provenance:` annotations identify
  paths in the experience Wiki. They are intentionally not bundled into the
  plugin or rendered as broken relative links.

## New knowledge

The full-text inventory above is retained for existing discovery pointers.
New rite workflow knowledge stays in raw promotion candidates rather than new
Wiki pages or additions to existing pages. Project domain knowledge continues
to use Wiki pages. Maintainers explicitly run `/rite:batch-run --promotions`
to group candidates and connect them to issue-create, open, and iterate.

New promotion integrates the knowledge into a helper, gate, principle, or
reference consumed by an actual caller. A candidate is complete only after
verification succeeds at the corresponding merged revision and the caller's
use is confirmed. Draft PRs and unused references remain unresolved. Raw
reasons and sources are retained, including legacy detector candidates.
See the [candidate contract](../wiki-patterns.md#昇格候補).

## Inventory

`manifest.txt` is the exact inventory approved by the promotion audit. The promotion
contract test compares it with the Markdown files byte-for-byte by relative
path and verifies required plugin frontmatter plus link portability.
