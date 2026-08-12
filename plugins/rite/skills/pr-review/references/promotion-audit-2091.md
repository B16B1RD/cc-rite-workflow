# Wiki Promotion Audit #2091 — Review/Fix Loop

 audited the eight `promote: rite-plugin` pages from promotion audit
#2091. This table is the durable routing log. A page is shelved when an existing
mechanical contract already enforces it; otherwise the named gate is the
mechanization target.

| Wiki page | Decision | Enforcement pointer |
|---|---|---|
| `aggregate-recommendation-label-evasion` | shelve — already mechanized | recommendation classification and disposition gate |
| `fix-induced-drift-in-cumulative-defense` | shelve — already mechanized | `review-trend-divergence.sh` and the `iterate` circuit breaker |
| `reviewer-likelihood-evidence-omission-induces-mechanical-demotion` | follow-up — producer enforcement incomplete | existing measured gate records demotion but does not prevent omitted evidence; tracked as an explicit follow-up |
| `convention-escalation-has-no-terminus` | shelve — already mechanized | structured review JSON, helper gates, and fail-loud enum validation |
| `differential-scope-review-blind-outside-diff` | mechanized here | `iterate/SKILL.md` post-breaker full review transition and normal review routing |
| `reviewer-scope-split-escalates-to-user` | mechanized here | Scope Split Gate below and `pr-review/SKILL.md` |
| `scope-creep-rejection-empirical-gate` | mechanized here | Rejection Evidence Gate below and `fix/SKILL.md` |
| `bugfix-new-error-path-needs-regression-test` | mechanized here | New Error-Path Regression Gate in reviewer prompts |

## Scope Split Gate

After finding collection, group independently reported findings by normalized
root cause. If one group contains both `current-pr` and `follow-up`, do not
collapse the scopes by severity or majority vote. Escalate the treatment choice
to the user and record it. `follow-up` is deferred work, not an alias for
`current-pr`; accepting it requires a durable follow-up destination.

## Rejection Evidence Gate

Before persisting an `acknowledged` finding whose reason is `scope-creep`,
`out-of-scope`, `minor`, or `user-override`, require independent reviewer cross-validation and an
empirical counterfactual/revert test. If either artifact is absent, return the
finding to fix selection or ask the user; do not persist its accepted fingerprint
or commit trailer.

## New Error-Path Regression Gate

When a fix adds a fallback, warning, catch/else branch, or other error path, a
regression test must enter that branch and assert its observable outcome. The
test must be non-vacuous: restoring the pre-fix behavior, or an equivalent
mutation, must make it fail.
