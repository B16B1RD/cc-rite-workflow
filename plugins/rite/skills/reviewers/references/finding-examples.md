# Finding Examples Reference

All reviewers share these Few-shot examples to calibrate finding quality. Use these as a guide for what to report, what NOT to report, and how to handle borderline cases.

## Good Finding Examples

### Example 1: Security — Missing Input Validation at System Boundary

**Investigation process:**

1. Reviewed diff: new API endpoint `POST /api/users` added in `src/routes/users.ts:45`
2. Checked input handling: `req.body.email` is used directly in database query without validation
3. Searched for validation middleware: `Grep "validateEmail|sanitize" src/` — no matches in this route
4. Checked other endpoints for comparison: `src/routes/auth.ts:30` uses `zod` schema validation
5. Verified the route is publicly accessible (no auth middleware)

**Finding:**

| Severity | File:Line | Issue | Recommendation |
|----------|-----------|-------|----------------|
| HIGH | `src/routes/users.ts:45` | `req.body.email` is passed directly to `db.query()` without validation. Other endpoints (`auth.ts:30`) use `zod` schema validation. This is a system boundary where external input enters the application. | Add `zod` schema validation consistent with the existing pattern in `auth.ts`. Example: `const schema = z.object({ email: z.string().email() })` |

**Why this is a good finding:** Concrete evidence (specific file/line), investigation with tool usage, comparison with existing patterns, actionable recommendation.

### Example 2: Performance — N+1 Query in Loop

**Investigation process:**

1. Reviewed diff: new function `getProjectMembers()` in `src/services/project.ts:120`
2. Identified pattern: `for (const project of projects) { await db.query('SELECT * FROM members WHERE project_id = ?', [project.id]) }`
3. Checked dataset size: `Grep "projects.*limit|per_page" src/` — default pagination is 100 items
4. Verified no batch query exists: `Grep "WHERE project_id IN" src/services/` — found `getTasksByProjects()` at `src/services/task.ts:80` using `IN` clause

**Finding:**

| Severity | File:Line | Issue | Recommendation |
|----------|-----------|-------|----------------|
| HIGH | `src/services/project.ts:120-125` | N+1 query: `db.query()` is called inside a loop iterating over `projects` (up to 100 items per pagination default). Existing code (`task.ts:80`) already uses `WHERE project_id IN (...)` batch pattern. | Replace the loop with a single `WHERE project_id IN (...)` query, following the pattern in `task.ts:80`. |

**Why this is a good finding:** Quantified impact (up to 100 queries), existing pattern reference for the fix, clear before/after recommendation.

### Example 3: Prompt Engineering — Contradictory Instructions

**Investigation process:**

1. Reviewed diff: updated `commands/pr/review.md` with new review guidelines
2. Found instruction at line 45: "Report all potential issues, even if uncertain"
3. Found instruction at line 120: "Only report findings with concrete evidence"
4. Cross-referenced SKILL.md Finding Quality Policy: "No Hypothetical Concerns" principle
5. Verified this is not intentional scoping (e.g., different phases): both instructions apply to the same review phase

**Finding:**

| Severity | File:Line | Issue | Recommendation |
|----------|-----------|-------|----------------|
| MEDIUM | `commands/pr/review.md:45,120` | Contradictory instructions: line 45 says "report all potential issues, even if uncertain" while line 120 says "only report findings with concrete evidence." This contradicts SKILL.md's "No Hypothetical Concerns" principle. Agents receiving these instructions will produce inconsistent output. | Remove line 45 or scope it to a specific context (e.g., security-only). Align with SKILL.md's established "concrete evidence only" principle. |

**Why this is a good finding:** Identified a real contradiction by cross-referencing multiple documents, explained the downstream impact on agent behavior, provided specific resolution options.

## Findings That Should NOT Be Reported

### Non-Example 1: Style Preference Without Impact

**Investigation process:**

1. Reviewed diff: variable naming in `src/utils/format.ts:20`
2. Found: `const fmt = formatDate(input)` — abbreviated variable name
3. Checked surrounding code: all variables in this file use short names (`val`, `res`, `fmt`)
4. Checked project conventions: no linting rule for variable name length
5. Assessed impact: the function is 5 lines long, `fmt` is used only once, and the intent is clear from context

**Decision: Do NOT report.**

**Why:** The abbreviated name is consistent with the file's existing style, is used in a narrow scope (5-line function, single use), and does not impair readability. Reporting this would be nitpicking — the fix cost (renaming + review cycle) exceeds the value gained.

### Non-Example 2: Hypothetical Future Problem

**Investigation process:**

1. Reviewed diff: new config parser in `src/config/loader.ts:50`
2. Noticed: parser handles YAML and JSON but not TOML
3. Searched for TOML usage: `Grep "toml|\.toml" .` — no matches anywhere in codebase
4. Checked Issue requirements: Issue body specifies "support YAML and JSON config files"
5. Checked roadmap/issues: `gh issue list --search "TOML"` — no TOML-related issues

**Decision: Do NOT report.**

**Why:** TOML support is not requested, not used anywhere in the project, and not on the roadmap. "This might need TOML support in the future" is a hypothetical concern. Adding unused functionality increases maintenance burden with no current value.

### Non-Example 3: Framework-Guaranteed Behavior

**Investigation process:**

1. Reviewed diff: Express.js route handler in `src/routes/api.ts:30`
2. Noticed: no explicit `Content-Type` header set for JSON response
3. Investigated: `Read node_modules/express/lib/response.js` — `res.json()` automatically sets `Content-Type: application/json`
4. Verified: Express documentation confirms this is guaranteed behavior

**Decision: Do NOT report.**

**Why:** Adding explicit `Content-Type` headers when using `res.json()` is redundant — the framework guarantees this behavior. Reporting it would suggest distrust of well-documented framework guarantees, adding unnecessary code without benefit.

## Borderline Example

### Borderline: Error Handling Depth — Report or Not?

**Investigation process:**

1. Reviewed diff: `src/services/payment.ts:80` — new `processPayment()` function
2. Found: `try { await stripe.charges.create(...) } catch (e) { throw e }` — catch-and-rethrow without additional context
3. Checked if this is a pattern: `Grep "catch.*throw" src/services/` — found 3 other catch-and-rethrow patterns in the codebase
4. Checked calling code: `src/routes/payment.ts:40` has a top-level error handler that logs errors
5. Assessed impact: the bare rethrow loses the local context (which payment, which user) but the error still propagates

**Analysis of the judgment boundary:**

| Factor | Toward Reporting | Toward Not Reporting |
|--------|-----------------|---------------------|
| Impact | Debugging difficulty: when errors occur, the log won't show which payment failed | Error still propagates and is caught by the top-level handler |
| Consistency | 3 other services follow the same bare-rethrow pattern | Changing only this one creates inconsistency |
| Fix cost | Low: add `throw new Error(\`Payment failed for user ${userId}: ${e.message}\`)` | Risk: changing error type might break error handling in callers |
| Severity | Payment is a critical path | The current pattern works — no bugs reported |

**Decision: Report as LOW.**

| Severity | File:Line | Issue | Recommendation |
|----------|-----------|-------|----------------|
| LOW | `src/services/payment.ts:80` | Bare `catch (e) { throw e }` in payment processing loses local context (user ID, payment amount). While error propagation works, debugging production issues will be harder without this context. Note: 3 other services follow the same pattern — this finding applies to the changed code only per scope policy. | Wrap the rethrow: `throw new Error(\`Payment ${paymentId} for user ${userId} failed: ${e.message}\`)`. Consider addressing the pattern in other services via a separate Issue. |

**Why this is borderline:** The code works correctly today. The improvement is about observability, not correctness. The existing pattern in 3 other services suggests this may be an accepted trade-off. However, for payment processing (a critical path), the debugging benefit justifies a LOW finding. A MEDIUM would be too aggressive given the working status and existing pattern.

## Related

- [Output Format](./output-format.md) - Findings table format
- [Cross-Validation](./cross-validation.md) - Multi-reviewer validation logic
