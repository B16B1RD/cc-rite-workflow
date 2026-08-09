# Wiki promotion references

This directory is the distributed source of truth for the 38 rite-specific
knowledge pages selected by promotion audit #2091 and tracked by Issue #2168.

## Promotion policy

- Every page in `anti-patterns/`, `heuristics/`, and `patterns/` uses the
  **full-text promotion** policy. No page in this batch is summary-only.
- The corresponding Wiki page remains as a discovery pointer. It keeps
  `promote: rite-plugin` and records the distributed path in `reference`.
- `sources[].ref` values and inline `Wiki provenance:` annotations identify
  paths in the experience Wiki. They are intentionally not bundled into the
  plugin or rendered as broken relative links.

## Inventory

`manifest.txt` is the exact inventory approved by Issue #2168. The promotion
contract test compares it with the Markdown files byte-for-byte by relative
path and verifies required plugin frontmatter plus link portability.
