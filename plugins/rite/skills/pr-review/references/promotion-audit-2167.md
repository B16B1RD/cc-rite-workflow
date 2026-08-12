# Wiki Promotion Audit #2167 — Contract and Provenance Fidelity

 audited eight `promote: rite-plugin` pages from promotion audit
#2091. Six pages add missing detection work to the shared Documentation
Fidelity Gate. Two pages are shelved because an existing shared gate already
mechanizes the complete rule; duplicating them would create another drift site.

| Wiki page | Decision | Enforcement pointer |
|---|---|---|
| `dogfooding-anchor-hardcode` | mechanized here | consumer portability requires distributed anchors or an exact precondition plus anchor-independent fallback |
| `dry-helper-aggregation-effect-overstate` | mechanized here | aggregation truthfulness enumerates centralized and still-distributed state and sweeps every old caller |
| `multi-pr-provenance-aggregation-error` | mechanized here | aggregation and provenance truthfulness requires per-literal `git log -S`, same-file cross-reference comparison, and a repository-wide propagation scan |
| `prose-design-without-backing-implementation` | shelved as already mechanized | Defense Mechanism Integrity Gate code-level structural enforcement already requires an explicit check and helper-level accept/reject tests |
| `result-based-justification-logical-fallacy` | mechanized here | counterfactual branch-outcome analysis rejects ordering claims whose swapped stages have identical outcomes |
| `gh-pr-list-related-pr-resolution` | mechanized here | command semantics rejects wildcard-looking exact-match filters and requires explicit state coverage plus client-side structured-field filtering |
| `cwd-corruption-success-check-exit-code-and-nonempty` | mechanized here | success predicates require producer exit status, non-empty required values, and lifecycle-prerequisite verification |
| `mechanical-test-over-declarative-invariant` | shelved as already mechanized | Defense Mechanism Integrity Gate already requires helper-level tests for structural claims; the Documentation Fidelity Gate now points to that executable contract instead of duplicating prose mappings |

## Scope decision

No follow-up is required. The six promoted rules are cross-language review
obligations, so the shared reviewer base is the narrowest durable enforcement
point. The two shelved pages name behavior already required by an existing
mandatory gate. Their decision rows retain provenance without copying the same
contract into another checklist.

The gate remains evidence-gated: reviewers report a current-PR finding only
when a changed claim or command demonstrably fails a check. Blocking
classification remains the responsibility of the measured-confirmed gate.
