# Wiki Promotion Audit #2166 — Documentation Fidelity

Issue #2166 audited four `promote: rite-plugin` pages from promotion audit
#2091. All four are mechanized by the shared Documentation Fidelity Gate in the
reviewer base, so every specialist can catch the defect at the diff where it is
introduced rather than relying on local Wiki injection.

| Wiki page | Decision | Enforcement pointer |
|---|---|---|
| `design-pivot-stale-cross-reference-comment` | mechanized here | pivot and delegation sweep over old vocabulary, identifiers, comments, and prose |
| `recovery-command-verified-in-human-execution-context` | mechanized here | human-context recovery verification with sibling qualifiers, canonical path resolution, target existence, chain lifecycle, and user-visible surface tracing |
| `references-extraction-content-fidelity` | mechanized here | citation content fidelity via source Read and exact Grep anchor |
| `canonical-reference-sample-code-strict-sync` | mechanized here | complete-block synchronization covering control flow, arguments, initialization, prerequisites, and consumption |

## Scope decision

No page requires a follow-up. Existing Cross-File Impact and tech-writer checks
covered portions of comment and documentation drift, but did not require the
human execution context for recovery commands or complete canonical-block
comparison. None was already fully mechanized, so no page is shelved.

The shared gate is deliberately evidence-gated: it activates only for changed
explanations, commands, citations, or samples and reports a current-PR finding
only when the source/consumer mismatch or wrong target is demonstrable. Blocking
classification remains the responsibility of the measured-confirmed gate.
