# Wiki promotion references

This directory is the distributed source of truth for the 38 rite-specific
knowledge pages selected by promotion audit #2091 and tracked by Issue #2168.

## Promotion policy

- Every page in `anti-patterns/`, `heuristics/`, and `patterns/` uses the
  **full-text promotion** policy. No page in this batch is summary-only.
- The corresponding Wiki page remains as a discovery pointer. It keeps
  `promote: rite-plugin` and records the distributed path in `reference`.
- `sources[].ref` values inside promoted pages are provenance paths in the
  experience Wiki. They are intentionally not bundled into the plugin.
- Cross-page relative links continue to resolve when both pages belong to this
  promoted set. Links to Wiki-only pages are provenance pointers rather than
  bundled dependencies.

## Inventory

The inventory is mechanically defined by the Markdown files below this
directory, excluding this README. The promotion contract test fixes the batch
at 38 files and verifies the required frontmatter on both the plugin copy and
the Wiki pointer.

