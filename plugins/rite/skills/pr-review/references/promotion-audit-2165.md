# Wiki Promotion Audit #2165 — Defense Mechanism Integrity

 audited five `promote: rite-plugin` pages from promotion audit
#2091. The shared enforcement point is the Defense Mechanism Integrity Gate in
the reviewer base, inherited by every specialist reviewer. The contract test
keeps each distinct check present so later prompt refactors cannot silently
drop one link.

| Wiki page | Decision | Enforcement pointer |
|---|---|---|
| `silent-precondition-omit-disables-and-defense-chain` | mechanized here | precondition-chain continuity + natural-entrypoint evidence |
| `new-script-inherits-latest-sibling-defenses` | mechanized here | latest-sibling history and hardening-target sweep |
| `single-condition-defense-vs-defect-class` | mechanized here | defect-class representative and class-predicate review |
| `silent-fallback-observability-via-debug-log` | mechanized here | fail-fast-first plus fallback visibility policy |
| `structural-guarantee-code-level-enforcement` | mechanized here | trust-boundary check plus three-case helper test |

## Scope decision

No page was shelved or split into a follow-up. Existing fail-fast and cross-file
checks covered parts of the subject, but none enforced the complete page-level
contract. One shared gate is preferable to five reviewer-specific copies because
the trigger shapes span Bash, hooks, application helpers, and documentation of
structural invariants.
