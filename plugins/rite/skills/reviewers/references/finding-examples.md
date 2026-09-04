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
6. 実測: dev サーバを起動して `curl -X POST localhost:3000/users -H 'Content-Type: application/json' -d '{"email":"a'\''--"}'` を実行し、500 SyntaxError と生値が `db.query()` に到達することを観測

**Finding:**

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| HIGH | current-pr | `src/routes/users.ts:45` | `req.body.email` is passed directly to `db.query()` without validation. Other endpoints (`auth.ts:30`) use `zod` schema validation. This is a system boundary where external input enters the application.<br>Likelihood-Evidence: new_call_site src/routes/users.ts:45 (本 PR で追加)<br>Verification: repro curl -X POST localhost:3000/users -H 'Content-Type: application/json' -d '{"email":"a'\''--"}' => 500 SyntaxError near "--" (db.query に生値が到達) | Add `zod` schema validation consistent with the existing pattern in `auth.ts`. Example: `const schema = z.object({ email: z.string().email() })` |

**Why this is a good finding:** Concrete evidence (specific file/line), investigation with tool usage, comparison with existing patterns, actionable recommendation. **実測の記録**: `Verification: repro` に再現コマンドと観測された誤動作を添えている (配線後は `measured=true` として保存される。記録経路の現況は `_reviewer-base.md` §Verification: runtime 実測の添付 の Rules を参照)。

### Example 2: Application — N+1 Query in Loop

**Investigation process:**

1. Reviewed diff: new function `getProjectMembers()` in `src/services/project.ts:120`
2. Identified pattern: `for (const project of projects) { await db.query('SELECT * FROM members WHERE project_id = ?', [project.id]) }`
3. Checked dataset size: `Grep "projects.*limit|per_page" src/` — default pagination is 100 items
4. Verified no batch query exists: `Grep "WHERE project_id IN" src/services/` — found `getTasksByProjects()` at `src/services/task.ts:80` using `IN` clause
5. 実測: 既存テストを実行 (`npx vitest run tests/services/project.test.ts`) し、`AssertionError: query count 100, expected 1` を観測

**Finding:**

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| HIGH | current-pr | `src/services/project.ts:120-125` | N+1 query: `db.query()` is called inside a loop iterating over `projects` (up to 100 items per pagination default). Existing code (`task.ts:80`) already uses `WHERE project_id IN (...)` batch pattern.<br>Likelihood-Evidence: new_call_site src/services/project.ts:120-125 (本 PR で追加)<br>Verification: failing_test tests/services/project.test.ts => AssertionError: query count 100, expected 1 | Replace the loop with a single `WHERE project_id IN (...)` query, following the pattern in `task.ts:80`. |

**Why this is a good finding:** Quantified impact (up to 100 queries), existing pattern reference for the fix, clear before/after recommendation. **実測の記録**: 調査手順 5 で実際にテストを走らせ、その失敗出力を `Verification: failing_test` に添えている (配線後は `measured=true` として保存される)。**実行していないテストのパスを書いてはならない**。

### Example 3: Prompt Engineering — Contradictory Instructions

**Investigation process:**

1. Reviewed diff: updated `skills/pr-review/SKILL.md` with new review guidelines
2. Found instruction at line 45: "Report all potential issues, even if uncertain"
3. Found instruction at line 120: "Only report findings with concrete evidence"
4. Cross-referenced SKILL.md Finding Quality Policy: "No Hypothetical Concerns" principle
5. Verified this is not intentional scoping (e.g., different phases): both instructions apply to the same review phase

**Finding:**

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| MEDIUM | current-pr | `skills/pr-review/SKILL.md:45,120` | Contradictory instructions: line 45 says "report all potential issues, even if uncertain" while line 120 says "only report findings with concrete evidence." This contradicts SKILL.md's "No Hypothetical Concerns" principle. Agents receiving these instructions will produce inconsistent output.<br>Likelihood-Evidence: new_call_site `skills/pr-review/SKILL.md:45,120` (本 PR で追加) | Remove line 45 or scope it to a specific context (e.g., security-only). Align with SKILL.md's established "concrete evidence only" principle. |

**Why this is a good finding:** Identified a real contradiction by cross-referencing multiple documents, explained the downstream impact on agent behavior, provided specific resolution options. **実測の記録**: この指摘に `Verification:` アンカーは付いていない — 矛盾した指示が生む出力の揺れは非決定的で、`<再現コマンド> => <観測される誤動作>` の形に落とせないため。実測できない指摘も 3 ゲートを満たすなら通常どおり報告する（配線後は `measured=false` として保存される）。アンカーを付けるために「reviewer を 3 回起動する」といった手順記述を再現コマンド欄に書いてはならない — 形式違反であり機械抽出できない。

### Example 4: Code Quality — Pre-existing Duplication Outside PR Scope (follow-up)

**Investigation process:**

1. Reviewed diff: new helper `formatOrderSummary()` added in `src/services/order.ts:200`
2. While reading the surrounding file, noticed three sibling helpers (`formatLineItems()` at `:80`, `formatTaxBreakdown()` at `:120`, `formatShippingDetails()` at `:160`) duplicate the same currency-parsing block (5 lines each, identical logic)
3. Verified the duplication is **pre-existing**: `git blame` shows these three helpers landed in unrelated PRs months ago, untouched by the current diff
4. Checked whether the PR's new helper introduces a 4th copy: it does NOT — the new code uses a shared `Money` helper from `src/utils/money.ts:30`
5. Assessed extraction effort: a proper DRY refactor would touch all three sibling functions, require new unit tests, and likely conflict with two other in-flight PRs that edit the same file (`gh pr list --state open --search "order.ts"` shows and)

**Finding:**

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| MEDIUM | follow-up | `src/services/order.ts:80,120,160` | Three sibling helpers (`formatLineItems`, `formatTaxBreakdown`, `formatShippingDetails`) duplicate the same 5-line currency-parsing block. The current PR's new helper already uses the shared `Money` utility (`src/utils/money.ts:30`) and does NOT add a 4th copy, so the duplication is pre-existing and not introduced by this PR. Refactoring would touch 3 functions, require new tests, and conflict with in-flight PRs.<br>Likelihood-Evidence: existing_call_site src/services/order.ts:80,120,160 | Track as a separate Issue: extract the currency-parsing block into `src/utils/money.ts` (following the existing `Money` utility pattern at `src/utils/money.ts:30`) and migrate the three sibling helpers. Coordinate with / to avoid merge conflicts. Example signature: `parseCurrency(raw: string): Money`. The three call sites then collapse from 5-line inline blocks to single-line calls: `const amount = parseCurrency(rawValue)`. |

**Why this is a good finding:** The duplication is real and worth tracking (3 sibling sites, identical logic), but the scope of a proper fix exceeds the current PR's diff and would create coordination overhead with two other open PRs. Reporting as `follow-up` honors the Severity × Scope Matrix rule that MEDIUM-class refactor opportunities outside the current diff belong in a separate Issue rather than being deferred silently. The investigation explicitly verifies the duplication is pre-existing and that the current PR does NOT add a 4th copy — this rules out the alternative reading that the PR introduced the problem (which would have made it `current-pr`). **実測の記録**: この指摘にも `Verification:` アンカーは付いていない — 重複それ自体は誤動作を起こさず (3 サイトとも現状は正しく動く)、再現コマンドも failing test も存在しないため。**推奨対応で新設を提案している関数 (`parseCurrency`) を failing_test の対象に書くのは誤り** — まだ存在しないコードのテストは実測ではない。

### Example 5: Application — Localized Style Inconsistency (nit-noted)

**Investigation process:**

1. Reviewed diff: three new React components added under `src/components/dashboard/`
2. Noticed style prop inconsistency: `Card.tsx:18` uses `style={{ padding: 12 }}` (numeric, React treats as `px`) while the sibling `Panel.tsx:22` (added in the same PR) uses `style={{ padding: '12px' }}` (string with explicit unit)
3. Verified rendered output is identical: React's style prop converts numeric values to px for known properties — no behavioral difference
4. Checked codebase convention: `Grep "style=\\{\\{" src/components/` returns 47 matches with mixed usage — 28 numeric, 19 string. No linting rule enforces either form
5. Assessed impact: bounded to the two adjacent component files in this PR; no runtime, accessibility, or maintainability cost beyond the visual inconsistency in the source

**Finding:**

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| LOW | nit-noted | `src/components/dashboard/Card.tsx:18`, `src/components/dashboard/Panel.tsx:22` | Style prop unit inconsistency within the same PR: `Card.tsx` uses `padding: 12` (numeric) while `Panel.tsx` uses `padding: '12px'` (string). Both produce identical output. The codebase has no linting rule on this and shows mixed usage (28 numeric vs 19 string across 47 sites).<br>Likelihood-Evidence: new_call_site src/components/dashboard/Card.tsx:18, src/components/dashboard/Panel.tsx:22 (本 PR で追加) | No action required for this PR. If a future refactor adopts a project-wide convention (e.g., always-numeric for px values), unify both sites at that time. |

**Why this is a good finding:** The inconsistency is real and localized to two sibling files in the same PR, but the blast radius is bounded (no runtime / accessibility / maintainability cost) and the codebase already has long-standing mixed usage with no project convention. Reporting as `nit-noted` honors the Severity × Scope Matrix rule that LOW-class style preferences with bounded blast radius are information sharing only, not actionable for this PR. The investigation rules out a stronger classification: there is no project-wide convention to enforce (would make it `current-pr`), the fix doesn't unlock a useful follow-up Issue (LOW × `follow-up` is a prohibited cell), and the impact is not zero (so it earns a mention rather than being dropped silently). The application reviewer is used deliberately — the Hypothetical Exception reviewers (`security` / `devops` / `dependencies`, plus `application` **for migration-related findings only**) are prohibited from emitting `scope=nit-noted`; a non-migration application finding like this style inconsistency is outside that prohibition and may legitimately be `nit-noted`. **実測の記録**: 両サイトとも出力は同一で誤動作がないため、実測できるものが無く `Verification:` アンカーは付かない (配線後は `measured=false` として保存される)。

## Weak Findings (Improve Before Reporting)

These findings have real issues but lack the WHY or EXAMPLE that makes them actionable for the fix agent.

### Weak Example 1: Missing WHY

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| HIGH | current-pr | `src/routes/users.ts:45` | `req.body.email` is passed directly to `db.query()` without validation.<br>Likelihood-Evidence: new_call_site src/routes/users.ts:45 (本 PR で追加) | Add validation. |

**Problem:** The Issue column states WHAT is wrong but not WHY it matters. The fix agent cannot prioritize or verify the fix without understanding the risk (e.g., SQL injection? Data integrity? System boundary violation?). The Recommendation lacks a concrete EXAMPLE.

**Improved version:**

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| HIGH | current-pr | `src/routes/users.ts:45` | `req.body.email` is passed directly to `db.query()` without validation. This is a system boundary where external input enters the application, and other endpoints (`auth.ts:30`) validate with `zod`.<br>Likelihood-Evidence: new_call_site src/routes/users.ts:45 (本 PR で追加) | Add `zod` schema validation consistent with `auth.ts`. Example: `const schema = z.object({ email: z.string().email() })` |

**Why the improved version is better:** The WHY ("system boundary where external input enters") tells the fix agent the severity class (injection risk, not just missing validation). The EXAMPLE (`z.object(...)`) gives a concrete code pattern to follow, reducing fix-review loop iterations.

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

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| LOW | current-pr | `src/services/payment.ts:80` | Bare `catch (e) { throw e }` in payment processing loses local context (user ID, payment amount). While error propagation works, debugging production issues will be harder without this context. Note: 3 other services follow the same pattern — this finding applies to the changed code only per scope policy.<br>Likelihood-Evidence: new_call_site src/services/payment.ts:80 (本 PR で追加) | Wrap the rethrow: `throw new Error(\`Payment ${paymentId} for user ${userId} failed: ${e.message}\`)`. Consider addressing the pattern in other services via a separate Issue. |

**Why this is borderline:** The code works correctly today. The improvement is about observability, not correctness. The existing pattern in 3 other services suggests this may be an accepted trade-off. However, for payment processing (a critical path), the debugging benefit justifies a LOW finding. A MEDIUM would be too aggressive given the working status and existing pattern.

## Confidence Calibration Examples

These examples illustrate how the internal confidence scoring system (defined in `_reviewer-base.md`) should be applied across different reviewer domains. The score determines whether a finding appears in the issues table (80+), recommendations (60-79), or is not reported at all (<60).

### High Confidence (90-100): Report in Issues Table

| Domain | Score | Finding | Why High Confidence |
|--------|-------|---------|---------------------|
| Error Handling | 95 | `catch(e) {}` in payment processing with no logging or propagation | Verified by `Read` — empty catch in critical path. `order.ts:40` logs and re-throws in adjacent code |
| Application | 95 | `status: string` with `Grep` showing 12 runtime comparisons against 3 specific values | Verified evidence of missing union type. Compiler could prevent invalid values |
| Application | 90 | N+1 query in loop with pagination default of 100 items | Verified by `Grep` showing `findMany` used for the same entity elsewhere |
| Security | 90 | API key hardcoded as string literal | Verified by `Grep` — no env var fallback, other keys use `process.env` |

### Medium Confidence (60-79): Report in Recommendations Only

| Domain | Score | Finding | Why Medium Confidence |
|--------|-------|---------|----------------------|
| Error Handling | 70 | Broad `catch(Error)` where specific `catch(NetworkError)` would be better | No `NetworkError` class exists in project — the fix would require new infrastructure |
| Application | 70 | Generic parameter could be more constrained | Current usage is correct — the constraint would improve safety but isn't critical |
| Application | 65 | Missing `useMemo` on a filter operation | Component renders infrequently and the array is small — impact is theoretical |
| Dependencies | 65 | Package has no updates in 2 years | No known CVEs, API is stable — abandonment is possible but not confirmed |

### Low Confidence (<60): Do NOT Report

| Domain | Score | Finding | Why Not Reported |
|--------|-------|---------|------------------|
| Error Handling | 50 | "Should use custom error classes" | Project doesn't use custom error classes anywhere — style preference |
| Application | 45 | "Should use branded types for IDs" | Project has no branded type pattern. Introducing one for a single type adds complexity |
| Application | 40 | "Should use a different CSS framework" | No evidence the current approach causes issues |
| Application | 30 | "Should implement HATEOAS" | Project doesn't follow HATEOAS. Hypothetical improvement with no immediate value |

### Key Takeaway

The confidence score answers one question: **"How certain am I that this is a real problem, verified by evidence?"**

- Tools used (Grep, Read, WebSearch) → higher confidence
- Comparison with existing project patterns → higher confidence
- Speculation without evidence → lower confidence
- Style preference without project convention → do NOT report

## Related

- [Output Format](./output-format.md) - Findings table format
- [Cross-Validation](./cross-validation.md) - Multi-reviewer validation logic
