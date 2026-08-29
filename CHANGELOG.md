# Changelog

All notable changes to Rite Workflow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Phase number policy: Entries describe changes at the feature-name level, not
internal `Phase X.Y.Z` implementation identifiers. Phase numbers inside
`review.md` / `fix.md` / `pr/open.md` may be renumbered between releases, so
CHANGELOG entries must remain stable across such refactors. When a change
genuinely needs locational precision, prefer referencing the file name
(e.g. `review.md`) over internal phase numbers. See Keep a Changelog 1.1.0
"Guiding Principles" for the rationale and conventions.

History-dependent phrasing policy: Entries describe each change at the feature
level. A Fixed/Changed/Removed entry may state the prior behavior it corrects —
that is the change log's purpose — but it must name the specific key, feature,
or behavior involved (e.g. `multi_session.enabled`, `max_review_fix_loops`)
rather than a vague implicit reference ("the previous behavior", "the old way")
whose baseline a new reader cannot resolve. Each version section is itself the
comparison anchor, so avoid cross-version "used to / previously" framing that is
not tied to a named key or feature. Breaking-change notices and migration guides
that aid upgraders are kept verbatim.

Number-reference policy: Entries MAY include GitHub Issue numbers as
parenthetical pointers (e.g. `(#NNNN)`). CHANGELOG.md / CHANGELOG.ja.md are
repository documents, not marketplace-distributed plugin files, so they are
outside the number-free surface guarded by `number-reference-check.sh`. The
`/release` skill template writes these pointers; do not strip them.
-->

## [Unreleased]

### Fixed

- **`/rite:merge` waits for pending CI checks instead of stopping immediately** — when `statusCheckRollup` is pending and `--force-ci` is not set, merge polls every 15 seconds for up to 540 seconds, then rejoins the existing healthy / unhealthy / unknown classification. A timeout still fail-closes with `[merge:not-ready]` and the unfinished check names. (#2449)
- **Consumed release-promotion attestations are deleted** — `pr-cycle-cleanup.sh` now removes `.rite/release-promotions/{N}.json` when the corresponding GitHub PR is MERGED or CLOSED. OPEN and undetermined states are kept with an observable reason so the merge gate still works. `.gitignore` in that directory is never deleted. (#2427)

## [0.13.2] - 2026-08-28

### Added

- **`/rite:iterate` sweeps remaining non-blocking findings after `[review:mergeable]`** — the post-mergeable sweep in `iterate` invokes `/rite:fix --nb-sweep`, which consumes each finding as a fix, a rejection with a mandatory judgement statement, or a new Issue, and finalizes with `[fix:sweep-done]`. `nb-sweep-collect.sh` / `nb-sweep-ledger.sh` back the collection and the rejection ledger, and the completion notice requires zero remaining findings after overlay. (#2409)
- **`/rite:open` runs a multi-perspective self-review of the implementation plan before approval** — `open` runs the self-review once for Complexity S and above, applying the four perspectives in `open/references/plan-self-review.md` to the plan and folding the findings back into it before the approval gate. A failed review is reported as a WARNING rather than blocking. (#2411)
- **Findings that delete or weaken existing text are excluded from consequence-class demotion** — the classification map takes an optional `exclusion` key, and `review-class-demotion-gate.sh` keeps an excluded class B finding blocking even in a cycle with zero class A findings. Wording polish on newly added text is demoted as before. (#2410)

### Fixed

- **A `{rejected_ledger}` retrieval failure in `/rite:pr-review` no longer degrades into an empty ledger** — a failing `gh api`, extract, or `mktemp` now yields `REJECTED_LEDGER=failed` with a stderr WARNING and a one-line note in the placeholder. A successful retrieval that finds no matching comment stays `empty`, and the review itself does not stop. (#2415)
- **The `nb-sweep` contract test pins the ledger retrieval failure path** — T-07 asserts `REJECTED_LEDGER=failed`, the stderr WARNING, and the placeholder note, so a regression back to a silent empty ledger no longer passes green. (#2418)

### Changed

- **The `exclusion` judgement statement in `_reviewer-base.md` is addressed to the consolidation side** — reviewers leave anchored material under `内容`, and the consolidation side of `pr-review` writes the `exclusion` judgement into the classification map. (#2413)

## [0.13.1] - 2026-08-27

### Added

- **Non-measured review findings are recorded on the related Issue instead of the PR** — `review-nonblocking-record.sh` posts the cycle-time record as a related-Issue comment, resolving the Issue through a closing keyword or the `issue-{N}` branch name and failing loud with `related_issue_unresolved` when neither resolves. The update-in-place comment id is persisted in the related Issue body, and `severity-levels.md` / `assessment-rules.md` describe the same channel. Record contract D-01 is unchanged; only the posting channel moves. (#2377, #2379, #2386, #2388, #2396, #2398, #2402)
- **`/rite:cleanup` opens a `follow-up` Issue for non-measured findings left on a merged PR** — `cleanup-follow-up-issue.sh` creates one Issue per PR, none when the finding count is zero, and stays idempotent across re-runs through a machine marker in the Issue body. The Issue is registered to Projects as `Todo` and opened before the review JSON is moved to `archive/`. (#2378)

### Fixed

- **`/rite:fix` no longer posts the `## レビュー指摘対応完了` report or `nit、認知済` replies to the PR** — PR thread replies are limited to human-authored findings and the fix details are recorded in the fix commit message instead. `nit-noted` is surfaced as a display and a count only. (#2376, #2381)
- **The cleanup follow-up reader anchors on the first body line and scopes recency to the follow-up side** — existing-Issue detection compares the first line's HTML comment for equality, so a complete marker on the second body line still yields `created`. The `{review_cleanup_check}` recency selection applies to the follow-up side only, while the state deletion side keeps its presence check. (#2385, #2390, #2392, #2394)
- **`/release` Phase 1.3 no longer misclassifies an empty PR body as a `gh` error** — the branch is rebuilt around the `gh pr view` exit status, so a successful call returning an empty body is treated as "no closing keyword". (#2372)
- **`lint/SKILL.md` and `docs/SPEC.md` describe the actual number-free scan surface** — both still listed CHANGELOG after it was removed from `number-reference-check.sh`'s `DEFAULT_TARGETS`. (#2370)

### Changed

- **`/release` Phase 1.3 resolves PR numbers to Issue numbers** — the trailing number of each squash-merge subject is resolved through `gh pr view` and printed as a `PR #N → Issue #M` table. A number that cannot be resolved to a PR is taken as an Issue number, and a missing closing keyword is reported as a resolution failure rather than falling back to the PR number. (#2368)
- **CHANGELOG number references are canonical and outside the number-free scan surface** — `number-reference-check.sh` no longer scans `CHANGELOG.md` / `CHANGELOG.ja.md`, and the header note in both files documents the policy. (#2367)

## [0.13.0] - 2026-08-26

### Added

- **`Verification:` anchors are mandatory on statically verified review findings** — a reviewer that confirmed a finding by grep, file comparison, artifact reading, or command execution must attach a `Verification:` anchor. When an environment constraint blocks the check, `Measurement-Blocked:` records it in a structured form and the integrated report surfaces the count in a `### 実測阻害` section plus a `| measurement-blocked: {n}` suffix on the E2E line. The three-valued measured gate (true / false / undetermined) is unchanged; `review-result-schema.md` documents that `Measurement-Blocked:` produces no `verification` field and does not intervene in that gate. (#2345, #2354)
- **`/rite:iterate` mergeable completion notices carry a mandatory unresolved non-blocking count** — the notice splits into zero / non-zero / retrieval-failure forms with the count read mechanically from the latest review JSON, so remaining items no longer depend on the model volunteering them. `stop-loop-continuation.sh` sends the turn back once when the field is missing or cannot be inspected. The `[review:mergeable]` sentinel is unchanged. (#2346)
- **`/rite:ready` refuses to promote when HEAD differs from the last reviewed commit** — `ready-reviewed-head-gate.sh` compares the latest review JSON's `commit_sha` against `git rev-parse HEAD`. A mismatch, an absent JSON (including archived), or a `rev-parse` failure stops fail-loud without marking the PR ready and points to `/rite:iterate {pr}`. (#2347)
- **Out-of-scope triage must post a handoff comment on the receiving Issue** — when `pr-review` routes a finding to an existing Issue, the Decision Log entry alone is not sufficient; the handoff comment is a required action. A CLOSED receiving Issue gets no comment and the triage returns to reselection. (#2348)

### Fixed

- **`stop-loop-continuation.sh` no longer re-requests a completion notice it already saw** — the FINALIZE path now inspects the latest assistant output for the `## /rite:iterate 完了` / `## /rite:iterate 中断` markers and sends the turn back only when the notice is absent or uninspectable. A mergeable notice missing the unresolved non-blocking field is still sent back. (#2349)
- **`pr-cycle-cleanup.sh` keeps review JSON for PRs that are still open** — the orphan reap gained a GitHub PR state gate, so only MERGED / CLOSED PRs have their review JSON moved to `archive/`; OPEN (including draft) and undeterminable states are retained. (#2350)
- **`/rite:cleanup` reaps flow-state and run-queue entries left by other sessions** — `flow-state.sh reap-issue --issue N` deactivates every flow-state for the Issue, deactivates run-queues with no remaining work, and collects the corresponding and orphaned `.flow-state.lock` files. Failures continue with a WARNING naming the path, and batch run-queues that still hold other Issues are left untouched. (#2351)
- **`PHASE_7_ASKUSER_INVOKED` is emitted only after the confirmation completes** — in interactive out-of-scope triage the marker now carries `mode` / `choice` / `reason` and is emitted after the user answers, closing the path that reached the Decision Log before confirmation. Automatic Decision Log entries for E2E and batch modes are unchanged. (#2352)

## [0.12.3] - 2026-08-23

### Fixed

- **`post-tool-wm-sync` reduces GitHub API round-trips from 9 to 2 per phase transition** — `issue-comment-wm-sync.sh` now exposes `fetch` / `patch`; `update` is a fetch → transform → patch wrapper. Replica-absent first detect (`no_comment`) is fail-loud via PostToolUse `systemMessage`; subsequent `wm_replica: "absent"` is a negative cache (no gh, empty stdout). Unresolved `branch.base` skips `update-progress` with `systemMessage` instead of a `develop` fallback. (#2336)
- **`issue-comment-wm-sync.sh` update mode keeps `COMMENT_ID` outside a subshell** — `do_fetch` stdout is read via a temp file so PATCH still succeeds when flow-state is absent. T-11 restores `TMPDIR`; the hook success path emits `status=success round_trips=2`. (#2338)

## [0.12.2] - 2026-08-21

### Changed

- **Japanese prose replaces 「正本」 by usage** — `cleanup`'s WM source selection uses 「採用元 / 採用する」, `pr-review`'s retained-flag rationale and intro-video provenance use 「判断基準 / 従う」, and the video location uses 「原本」. Runtime values (`WM_SOURCE`, sentinels, WARNING text) are unchanged. (#2328)
- **awk extraction anchors are annotated at the source comment** — `iterate` / `cleanup` SKILL.md and `issue-comment-wm-sync.sh` now carry a one-line note immediately above each comment that tests use as an awk extraction start, so the coupling is visible at the edit site. Extraction method, fail-loud hard exit, and test-side awk patterns are unchanged. (#2330)

## [0.12.1] - 2026-08-15

### Fixed

- **`/release` Phase 2.5 merges the prep PR with `--squash`** — `release-promotion-verify.sh` requires every develop commit since the last release to be a squash commit (the SHA itself is a merged PR's `merge_commit_sha`). Phase 2.5 now uses `gh pr merge {PREP_PR_NUMBER} --squash` so the next develop→main promotion can pass that invariant. Branch deletion is left to `/rite:cleanup`. (#2323)

## [0.12.0] - 2026-08-14

### Changed

- **Wiki bundles migrate to Open Knowledge Format (OKF) v0.2 conformance** — page frontmatter `sources[].ref` is renamed to the v0.2 reserved shape `sources[].resource`, and `updated` is consolidated into the trust family `generated: {by, at}`. Reinforcement-only ingest cycles append one `verified` entry (revision cycles leave `verified` untouched), and `status: deprecated` / `stale_after` are written only when their triggering event occurs. Existing v0.1-shaped bundles are bulk-migrated on first contact by `wiki-okf-migrate.sh` (invoked from `wiki-ingest`; idempotent, fail-loud, supports both branch strategies), declaring `okf_version: "0.2"` in `index.md`. The three consumer scripts (`wiki-lint-source-refs.sh` / `wiki-query-inject.sh` / `wiki-index-update.sh`) read only the migrated single shape. (#2315)

## [0.11.0] - 2026-08-13

### Changed

- **SKILL description diet: outcome + verification + mechanical steps, with rationale exiled to bundled references** — prose (`bytes_prose`) is compressed and moved to per-skill `references/`, while mechanical rails (fenced bash, branch tables, sentinels) stay byte-identical. The method is recorded in `plugins/rite/references/skill-diet-method.md` (line-drawing checklist, pin-transfer procedure, measurement template) and piloted on `open` (~−36%) (#2278). Wave 1 applied it to `iterate` (−33.3%) / `fix` (−32.3%) / `pr-review` (−25.5%) (#2285, #2286, #2287). Wave 2 covered the remaining skills: the large four (`setup` / `cleanup` / `wiki-lint` / `wiki-ingest`) (#2292), the medium four (`pr-create` / `lint` / `issue-implement` / `issue-close`) (#2293), and the remaining 19 small skills (#2294). CLAUDE.md's skill line-count principle is rewritten around the diet generation: `bytes_prose` is the primary metric, and the 4,000-line cap is no longer treated as a writing budget (#2295).
- **README Demo points at the v0.11.0 English/Japanese v2 intro videos** (~55s full cuts from `media/intro-video-v2`). The retired HyperFrames `PROVENANCE.md` opening claim is updated so it no longer says the README still references that cut. (#2297, #2307)
- **Autonomous-execution preamble forbids stopping for a context-budget reason and limits reports to outcome / next action.** Resume after exhaustion stays with the existing compact/recovery path. (#2279)

### Fixed

- **`iterate` promotes a missing review-result JSON at the cycle boundary to a repair gate** — if the previous cycle's result is still in context it is saved immediately through the existing helper; otherwise the cycle counter is held (`INC=held`) and the review is re-run. LOST annotation and trend calculation stay unchanged. (#2305)
- **`/rite:cleanup` / `/rite:issue-close` still sync a parent Issue's Projects Status to Done when the parent is already CLOSED** — close-idempotency skip and board sync are separated, so an already-closed parent with all children closed still reaches Done. (#2301)
- **Reviewer spawn-spread is measured from the orchestrator's spawn timestamp**, not from the time the report is written, so a long parallel review is no longer misclassified as serialized. Reviewers in the same message share one value. (#2281)
- **`/rite:batch-run --merge` completion text no longer says "excluding failed" when `failed=[]`.** A non-empty failed list is still listed on its own line. (#2299)
- **The project-local `/release` skill can complete a develop→main promotion safely** — the prep PR now runs `/rite:iterate`; promotion commits must already have arrived via merged PRs (`release-promotion-verify.sh`); the verified head SHA is pinned with `--match-head-commit`; Phase 2.5 stages only the seven release files (sandbox-safe); with `multi_session.enabled` the prep branch is placed in the issue session worktree; Phase 3 exits that worktree (`action: keep`) before touching `main`. (#2269, #2268, #2270, #2271)

## [0.10.0] - 2026-08-12

### Added

- **XS/S lanes make per-phase ceremony cost proportional to the Issue's declared Complexity** — every phase previously ran at full weight regardless of change size: a one-line config change still spawned a full reviewer set with the full verification mandate attached. The Issue's declared Complexity (never auto-inferred, always present in the Issue's Section 0 Meta) now selects a binary lane — XS/S run `light`, while M/L/XL and every fail-safe path run `full` (identical to prior behavior; a missing or unreadable Complexity always falls back to `full` with a WARNING, since the safe side is never to reduce ceremony). `light` changes exactly two things in `pr-review`: `complexity_max=3` is passed into the reviewers Phase 5 `effective_max` resolution (merged into that resolution rather than applied as a separate filter, so the `mandatory` protection and the reviewer floor are not re-implemented — it is applied before the final clamp, so it is not a hard "at most 3" cap), and the verification mandate is reduced to the touched tests (full-suite sandbox duplication and mutation experiments become M-and-above equipment). In `issue-implement`, XS/S suppress new test files in favor of adding asserts to existing suites, and XS additionally forbids introducing new descriptive derived prose. Adoption criteria, consequence classes, and the Cross-File Impact Check are unchanged — the latter also absorbs an under-declared Complexity. (#2142)
- **`merge` halts on an unhealthy CI state instead of trusting `mergeable` alone** — `mergeStateStatus` and the actual job execution record are now inputs to the pre-merge safety judgment, unknown CI states halt first (fail-closed), and pending check schemas are normalized before evaluation. A merge gate whose PR token is an unresolvable variable form is denied rather than guessed. (#2194, #2176)
- **`/rite:setup` covers environment bootstrap end-to-end** — dependency verification (`bash` ≥ 4 / `jq` / `flock`) with per-platform install guidance (#2005), a GitHub authentication flow (#2236), a repository creation flow (#2237), and automatic generation of the GitHub templates (`ISSUE_TEMPLATE`, `PULL_REQUEST_TEMPLATE`) (#2238). `getting-started` now delegates prerequisites to `setup` instead of duplicating them. (#2239)
- **GitHub Actions CI on an ubuntu + macos matrix** — the matrix workflow (#2007) runs the hook and script test suites on both platforms, `shellcheck` is blocking with its error backlog cleared (#2009), the macOS suite is green with BSD/GNU differences absorbed (#2013), and the `rite-dev` tests are wired into it (#2182).
- **`findings[].verification` is added to the review-result schema** — additive, with read-side type guards so older result JSON stays readable (#2035), and the canonical write version moved to 1.1.0 (#2211).
- **`issue-create` fact-checks the assertions in the Issue body it generates** before creating the Issue, so generated claims about existing behavior are verified against the code rather than asserted. (#2056)
- **`no_speculative_structure` coding principle** — structures, reserved fields, extension points, and config keys added in anticipation of future needs are rejected without a real Issue; the Guardrail additionally requires runtime reachability and a fail-loud default. (#2092)
- **Fix-side policy gates: Simplification-First in `fix`** (#2071), a **contract-literal mandate across all Complexity levels in `issue-implement`** — the Issue contract's literal text is the implementation ceiling and expansion requests are returned to the Issue (#2254) — and **finding response limited to the minimal diff** (#2255).
- **Hook decisions are persisted as a machine-readable audit trail** — `pre-tool-bash-guard` deny decisions (#2180) and the reviewer guardrail audit (#2222) are written to durable logs instead of existing only in session output.
- **`flow-state` records phase transitions to an append log**, so per-phase wall-clock time is collected automatically across a run. (#2120)
- **`wiki-ingest` routes machine-detectable heuristics to detector candidates** rather than filing them as prose-only Wiki entries, and its promotion classification is recorded in one line per entry with explicit `promote` field guidance. (#2170, #2169)
- **New lint detectors** — `grep -q` pipelines under `pipefail` (#2218), symlinks crossing the plugin distribution boundary (#2199), environment-specific tokens leaking into distributed files (#2189), and descriptive Issue/PR number references, whose detection was extended to bare `PR #N` / `Issue #N` forms, to `index.md`, and to an added-line gate (#2066, #2070, #2224, #2225, #2257).
- **`scripts/rite-dev` (at the repository root, not the plugin's own `scripts/`), a development launcher shared across hosts**, with its own test suite and CONTRIBUTING documentation. (#2178)
- **An in-house frame-step video rendering pipeline** — HTML → mp4 is produced by a repository-owned renderer and scene contract driven by virtual-clock seeking rather than real-time capture, so the same scene yields an md5-identical mp4. (#2242) The intro video was rebuilt on it, first as v2 (#2243) and then re-storyboarded around rite's differentiators — pre-implementation exploration, the measured-evidence gate, and Wiki heuristics compounding over time — with the default draft-PR stop reflected instead of the opt-in `--merge` path. (#2260)

### Changed

- **The review/fix loop now has a reachable termination condition: `blocking` is redefined as measured** — a finding counts as blocking only when it is CONFIRMED, `verification.measured == true`, and `scope ∈ {current-pr, follow-up}`; non-measured findings leave `total_findings` and are recorded in the integrated report's "findings without measurement" section (#2036). The classification itself moved out of LLM discretion into `scripts/review-measured-gate.sh`, which runs deterministically before the mergeable judgment — the "demote my own finding to non-blocking and declare mergeable" decision collides head-on with the reviewers' own thoroughness instructions, so as long as it stayed discretionary it was structurally not performed (one observed PR ran all 9 cycles without a single demotion, keeping a loop alive for over 8 hours on prose-precision findings that contractually must not block a merge). `mergeable` is decided on the blocking subset of `scope ∈ {current-pr, follow-up}` being empty, not on `findings[]` being empty, since `nit-noted` entries remain in the array by design. (#2074)
- **A consequence-class demotion axis terminates the churn tail without a manual freeze** — blocking findings are split into class A (leaving it unaddressed changes the deliverable's runtime behavior) and class B (consequences confined to detection coverage, readability, or document consistency). In a cycle where class A is 0, all class B findings are demoted to non-blocking and the run ends through the existing mergeable path. Classification is an LLM judgment made in the consolidation context (separate from the finding's author) while enforcement is mechanical (`scripts/review-class-demotion-gate.sh`), and anything undecidable — missing entry, invalid class, no rationale, duplicates — is treated as class A with a WARNING rather than rounded down into a demotion. (#2248)
- **The circuit breaker detects divergence from the convergence trend instead of firing on a cycle count** — a cycle-count ceiling cannot distinguish effort from waste: healthily converging loops were cut off a few findings short of done, and diverging loops burned to the ceiling. The per-cycle blocking series for the current run is reconstructed from the persisted review JSON, and "the last two values both exceed the best level so far and are not still descending" is the mechanical divergence test (the formula is trajectory-backtested, not window-width based). `safety.max_review_cycles` is demoted to a distant backstop for slow non-convergence that slips past divergence detection, and its default is raised from 5 to 15 (#2099, #2135). Breaker firing halts mechanically in both batch and interactive modes (#2044), a breaker-induced stop is distinguished from an ordinary interruption so a halted run is not misreported as completed (#2220), and a full review is forced after the breaker so no blind spot outside the diff scope is left behind (#2195).
- **From cycle 2 the review is scoped to the fix diff and reviewers are selected dynamically** — findings concentrate on the surface the fix touched, yet every reviewer re-examined the full diff and codebase each cycle. Termination semantics are unchanged (blocking 0 = fix surface clean + all prior findings resolved; unchanged surfaces were reviewed in cycle 1). The judgment input is the persisted review JSON only, because with the default `pr_review.post_comment: false` there are no PR comments to read. Reviewer narrowing replaces the pattern-match input file list with the fix diff rather than filtering after the cap, so the sole-reviewer guard / `min_reviewers` / `mandatory` invariants of Phase 5 stay in one place. (#2126)
- **Blocking is limited to behavioral-consequence classes for prose findings** (#2095), **test-pin findings block only where they correspond to the Issue contract's MUST/AC** (#2122), and a **Likelihood-Evidence producer gate** is applied at the finding source (#2198).
- **Record comments are identified by durable comment id rather than body matching, and carry a pointer instead of the full text** (#2112, #2114), with their recording path moved into a helper whose execution guarantee is pinned to a completion sentinel (#2038).
- **Account migration asakaguchi → B16B1RD** — owner and author references in `marketplace.json` / `plugin.json`, README badge URLs and `marketplace add` examples, and example values across `docs/SPEC.md`, templates, skills, scripts, and test fixtures are updated. (#2029)
- **Skill-level execution conventions are shared as one contract** — the autonomous-execution preamble and effort guidance are consolidated into a shared contract (#2256), reversible recommendation-level judgments are handled autonomously instead of escalated (#2250), and environment-induced workarounds are silent on success and a single line on failure (#2162).
- **Wiki heuristics specific to rite's own behavior are promoted into the plugin's references and gates** rather than left in the project Wiki, which can only remind and never enforce — review/fix loop knowledge (#2183), defensive-mechanism completeness (#2187), document verification (#2191), contract and history knowledge (#2192), and remaining rite-specific entries (#2193), with the inline-content delegation promotion audit recorded in `pr-create` (#2186).
- **`pr-review`'s SKILL.md rationale is moved to its bundled references**, leaving one-line pointers and restoring line-count headroom in the executable procedure. (#2155)
- **Installation and template documentation** — the install procedure gains the `/reload-plugins` step (#1992), README dependency requirements are expanded in both languages alongside a `.gitattributes` (#2004), and the Issue template's Section 9 states the acceptance criteria for the Decision Log (#2084).
- **Recurring internal mechanisms are consolidated into tested helpers** — `wiki-ingest`'s index manipulation (#2111), marker emit and matching on the `iterate` path (now shared functions with fixture tests) (#2137), ownership of the `[CONTEXT]` marker's value-side matching convention (#2151), and `.gitignore` bundling (#2219). The completed one-time Wiki backfill helper is removed (#2215).
- **Documentation is re-synced to the shipped implementation** — the guard decision contract in CONTRIBUTING (#2208), `max_review_cycles`'s documented default (#2209), `review.loop` comments in the config template (#2210), schema invariant 6 and its gate wiring (#2212), the test coverage gate's connection to its decision point (#2213), the active guard and sentinel file listing in SPEC (#2214), unqualified "0 findings" phrasing left over after the measured-evidence gate (#2043, #2106), parenthetical claims in `fix` / SPEC AC-3 whose premises the gate wiring changed (#2102, #2104), `wiki-ingest`'s index instructions corrected to the actual 5-column table form (#2052), and two omissions in SPEC's Plugin Structure reference listing (#2108).

### Fixed

- **The merge gate blocked exactly the PRs that had been through a full review** — it required `schema_version` / `verdict` / `reviewers` (length ≥ 2) in the review-results JSON, but the latter two had no definition in the schema Single-Source-of-Truth and neither canonical writer emitted them; merges had been passing only because hand-written JSON happened to fit. The writers are extended so the gate's requirement becomes the specification. (#2229)
- **Review-result integrity gates now verify the artifact rather than its absence** — the cycle-level execution-guarantee gate on saving review-result JSON (#2078), a positive check of the current cycle's result JSON in the pre-merge gate (#2130) pinned to the real HEAD (#2197), orphaned review JSON and run-start pins reclaimed mechanically (#2181), malformed Verification anchors treated as undecided (staying blocking) (#2081), and `ready`'s pre-gates matched to the PR head (#2196), and a review-existence positive gate added at the merge execution point (#2161).
- **Reviewer spawn parallelism is verified mechanically** — serialization of reviewer spawns is detected from machine-recorded spawn timestamps (#2231), and the spawn-spread description and its static pin are hardened (#2234).
- **Sandbox and macOS/BSD portability in hooks** — `pr-cycle-cleanup.sh`'s `TMPDIR` decision resolves symlinks to physical paths (#2172), `mktemp` templates place the `X` run at the end so BSD/macOS regains filename uniqueness (#2080), tempfile lifecycle is extracted to a lib with lint detectors for the two remaining patterns (#2124), `pr-cycle-cleanup` reclaims detached mutation worktrees under `TMPDIR` — its skip condition moves from "the working tree is dirty", which rejected every intended target since a mutation worktree is inherently dirty, to "the commit is unreachable from every named ref", with an undecidable check skipped under a WARNING (#2156, #2160), stale issue-claim takeover works on macOS (#2201), `flow-state`'s `_atomic_write` guards the `flock` call with `command -v` (#2003), and the diagnostic-neutralization parity sweep is extended to `scripts/` (#2206).
- **Guard path handling is canonicalized** — `pre-tool-edit-guard`'s AC-2 symlink resolution no longer depends on `realpath` (#2017), edit path and audit normalization are aligned (#2204), the cwd content guard canonicalizes its input (#2203), and the live cwd is detected from `lsof` output (#2202).
- **Silent failures in hooks are made loud** — a failed pending-marker deletion is reported instead of swallowed (#2205), and working-memory checklist integration no longer returns a no-op success (#2152).
- **Working memory survives the paths that used to drop it** — `pr_number` / `loop_count` are carried forward through the ordinary update path (#2094) and the canonical-copy selection is decided by content inspection rather than mere existence (#2154).
- **`cleanup` no longer stalls or over-deletes** — a session started inside a worktree splits its items and delegates main-checkout operations (#2150), branch-delete guards are hardened (#2223) with the remote-branch delete guard switched to `--exit-code` so `merge`'s guarantee matches reality (#2022), a transient `ls-remote` rc=128 gets one retry (#2153), and `recovery=auto` is synchronized with the reaper's dirty gate (#2200).
- **`wiki-query` and `wiki`** — Pass 1 candidate extraction handles the table-formatted index (#2097) and a zero-candidate result is fail-loud instead of silently empty (#2098), diagnostic wording uses ASCII in place of em-dashes that macOS CI corrupted into invalid UTF-8 (#2100), Japanese titles no longer trigger the C1 false positive (#2235), and Wiki pushes are retried outside the sandbox (#2221).
- **`lint` and skill-definition parsing** — board-drift detection no longer restricts itself to a closure reason (#2227), and positional-parameter expansion inside fenced bash no longer makes the YAML parser return every key empty (#2051).
- **Test suites no longer pass vacuously** — TC-036a's floor condition is derived from the blocking gate rather than a Linux check (#2096), TC-124 (d) gains a positive control (#2020), comment-journal mutation survivors are killed (#2217), the bash-guard suite continues past a `jq` extraction failure instead of aborting the run (#2207), the backlink checker is excluded across worktrees (#2216), and the ERE bare-pipe hazard is documented in the grep assert helpers' docstrings (#2157).
- **Intro video assets** — v2's BGM audibility and loop phase are corrected (#2245), Pixabay BGM provenance is restored (#2262), and `assemble.sh`'s `-P` follows the current scene composition (#2263).

## [0.9.2] - 2026-07-24

### Changed

- Intro video (Japanese and English) badge/ending-meta version stamps are updated from `v0.8.0` to `v0.9.1`, and the README Demo section video links point to the new BGM-mixed final renders. Scene composition and duration (~125s) are unchanged. (#1985, #1986)

## [0.9.1] - 2026-07-23

### Added

- **`cleanup`/`wiki-ingest`/`batch-run`/`recover` completion reports now aggregate an Outstanding Items section** instead of leaving non-blocking failures (a skipped wiki push, a deferred branch deletion, etc.) scattered only as inline checklist annotations that were easy to miss — the aggregated section states "none" explicitly when there are zero outstanding items. `cleanup` emits a `[cleanup:outstanding:N]` sentinel that `batch-run` rolls up across the whole batch's `--merge` completion notice, and `recover` gained an informational check (only when the resolved phase is `cleanup`/`completed`) that detects unpushed wiki commits or leftover local branches directly from git state. (#1946, #1975)

### Fixed

- **`setup` Phase 4.8/4.9 guidance messages are now output verbatim instead of being paraphrased into indirect reporting language by the executing agent** — an explicit instruction to output the template text verbatim, without summarizing, was added immediately before each message block. (#1976, #1978)
- **Corpse worktrees (admin-dir half-broken and unrecognized by git) are now reclaimed immediately instead of waiting on the 24h age guard** — `cleanup`'s Step 4-W now records the worktree path to the reap manifest (`.rite/tmp-artifacts.tsv`) whenever removal is skipped (busy failure or sandbox mask) and the PR is confirmed merged, since a corpse worktree can't resolve its checked-out branch for the existing branch-name-based bypass (#1966) to apply. (#1945, #1974)
- **`pr-review`'s worktree-axis drift detection no longer false-positives from sandbox ghost-mount entries** appearing on only one side of the snapshot/verify comparison — both `post-review-state-verify.sh`'s `current_worktree_hash` and `pr-review`'s Step 4.0.A `ORIG_WTH` now compute through the existing ghost-mount filter (`lib/git-status-filtered.sh`, #1936) instead of raw `git status --porcelain`. (#1944, #1973)
- **Session worktree creation now duplicates `.claude/settings.local.json`** — `git worktree add` doesn't copy the gitignored `.claude/` directory, so the dogfooding override (`enabledPlugins["rite@rite-marketplace"]: false`) was lost in session worktrees, causing the cached marketplace version of skills to load instead of local changes. `open`'s Step 2.3-W and `ensure_session_worktree`'s branch_local/branch_remote paths both now copy the file when present. (#1943, #1970)
- **Session-start's lazy reap (`pr-cycle-cleanup.sh`) output is now redirected to `.rite/logs/pr-cycle-cleanup.log`** instead of being discarded, so a silent reap skip (dirty skip, liveness skip, corpse age guard, etc.) can be diagnosed after the fact. (#1968, #1969)
- **Merged-PR session worktrees and their local branches no longer leak permanently** — once a claim is released, the free-claim path fell into the "mtime under 24h → skip" branch forever, because the worktree root's mtime is refreshed every session by harness `.claude/.cc-writes` churn. The manifest-recorded free-claim path now bypasses that age guard so the next session's reap can reclaim it. (#1966, #1967)
- **Sandbox mask-mounted worktrees no longer half-break during `cleanup`'s `git worktree remove --force`** — when the sandbox has bind-mounted a character device over the admin dir's `config.worktree`, Step 4-W now detects the mask beforehand and skips the remove attempt entirely (deferring to lazy reap via a `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` marker + WARNING) instead of corrupting the admin dir (missing `HEAD`) into an unrecoverable "not a git repository" state. Lazy reap's Step 5 also gained corpse detection (missing admin `HEAD` AND unrecognized by git) that bypasses Gate 3's previous permanent skip. (#1957, #1959)

### Changed

- **`setup` Phase 4.8 now auto-configures the sandbox write allowlist instead of only guiding the user to do it manually** — when `multi_session` is enabled and a filesystem-write-restricted sandbox is detected, `/rite:setup` ensures `.claude/settings.local.json` is covered by the repo's `.gitignore` (added if missing — a personal global gitignore alone doesn't protect other contributors) and idempotently appends the main checkout root's absolute path to that file's `sandbox.filesystem.allowWrite` (the shared `.claude/settings.json` is never modified). This resolves the manual-setup burden noted in 0.9.0's Known Limitations. A sandbox-caused write failure is retried once with the sandbox disabled; only a failure that persists after retry falls back to the previous manual-guidance message. (#1942, #1965)
- **`wiki-ingest` now pushes to the `wiki` branch once at the end of the flow instead of after every raw-source commit / lint pass**, cutting sandbox-bypass repetition on SSH host alias remotes (previously up to 8 pushes in one session, some duplicated 11 seconds apart). Per-source commits use a new `--commit-only` mode; a single `--push-only` runs in the new Step 8.6 regardless of `auto_lint`. `wiki-lint`'s standalone invocation is unaffected (still commits and pushes immediately); only its `--auto` (ingest-invoked) path defers to ingest's push. (#1941, #1955)

## [0.9.0] - 2026-07-21

### Added

- **`setup` proactively detects and warns about two sandbox-related environment constraints at `/rite:setup` time, instead of only surfacing them after a failure** — (1) Phase 4.8 (requires `multi_session` enabled): a session worktree's cwd is rejected when writing state (`flow-state.sh` / `issue-claim.sh` etc.) into the main checkout after `EnterWorktree`; (2) Phase 4.9 (independent of `multi_session`): a sandboxed session with an SSH host alias remote (e.g. `git@github.com-work:owner/repo.git`) hits a Bad Gateway failure on `git push`/`fetch`. Sandbox-enabled detection can't be done from bash, so both phases use the same approach (Claude's own execution-context judgment). (#1907, #1925, #1938)

### Changed

- **BREAKING: the reviewer read-only guarantee is re-layered — `pre-tool-bash-guard.sh` no longer machine-blocks working-tree git verbs, keeping only the `.git`-write machine gate** — the static verb denylist (sub-blocks (A)–(G): `checkout`/`reset`/`add`/`commit`/`branch`/`stash`/`fetch` flags/`worktree` sub-actions and 20+ more, plus that denylist's whole-command git global-flag normalization and the worktree-add argument scan) is removed from the PreToolUse hook (cut by roughly a third, 922 → under 600 lines) — the surviving `.git`-write gate (sub-block (N) below) retains a global-flag normalization scoped to just its four subcommands, ending the recurring bypass-patch churn (11 hardening commits in 3 months) and structurally eliminating its false-positive class. Working-tree mutations are visible and recoverable via `git status`, so their guarantee is now Layer 1 (the READ-ONLY contract in `_reviewer-base.md`, unchanged) + Layer 3 (`post-review-state-verify.sh` branch/stash/branch-list/worktree drift detection after each review — detection logic unchanged; its header and drift-WARNING guidance messages were updated for the new layering). The machine gate keeps only what those layers cannot cover — all still fail-closed: writes into a `.git` directory via a redirect or file-mutating verb (invisible to `git status`, irreversible, RCE-grade — sub-block (H)); native `.git`-writing git subcommands that no redirect/file-verb detection can see — `git config` write forms (`core.hooksPath` / `core.fsmonitor` / `alias.*=!cmd` are the RCE vector), mutating `git remote`, `git update-ref`, `git symbolic-ref` — as a fixed 4-subcommand closed set (sub-block (N); read forms like `git config --list/--get` stay allowed); the shell-wrapper block (`eval`/`sh -c`/… would trivially hide a `.git` write); and the oversized-command length guard (timeout→fail-open bypass prevention). Deny pattern names change accordingly: `reviewer-state-mutating-git` no longer exists; the surviving gates emit `reviewer-gitdir-write` (both (H) and (N)) / `reviewer-shell-wrapper` / `reviewer-oversized-command`. If a regression appears, individual verbs can be re-added without reviving the whole harness. (#1879)
- **BREAKING: the 5 overlapping specialist reviewers (`api` / `frontend` / `performance` / `database` / `type-design`) are consolidated into a single `application-reviewer`** — their checklists mutually overlapped (N+1 was covered by both performance and database, XSS by both security and frontend, etc.), and each spawned reviewer injects the shared `_reviewer-base.md` (~430 lines) again, so a mixed PR that selected all 5 paid `base×5` injection for largely redundant perspectives. The consolidated `application` reviewer holds the combined purpose (application-code correctness, performance, data operations, interface design) as a persona + first-suspect lenses and delegates detailed checkpoint selection to model judgment; it inherits the Database-migration Hypothetical Exception (migration findings only, `severity-levels.md` unchanged). Reviewer registry shrinks from 13 to 9 types. Legacy type names appearing as input (rite-config values, stored review-result JSON, manual input) are substituted with `application` after a WARNING — never silently skipped.

  **Migration table (legacy reviewer type → new type):**

  | Legacy reviewer type | New type |
  |----------------------|----------|
  | `api` | `application` |
  | `frontend` | `application` |
  | `performance` | `application` |
  | `database` | `application` |
  | `type-design` | `application` |

### Fixed

- **Sandbox-enabled environments (bubblewrap-based) now work around the permanent `.git/config` write rejection** — worktree creation's upstream-tracking setup (`branch.autoSetupMerge`) and `git push -u`'s upstream setup both hit this rejection, leaving the open→implement→pr-create flow stalled mid-way (branch created, not yet pushed). Worktree creation now adds `--no-track`, `git push -u` / bare `git push` are unified to `git push origin {branch}` (upstream tracking is no longer needed since flow-state always retains the branch name), and `gh pr create` gets an explicit `--head` to resolve the correct head without an upstream. (#1898)
- **`gh` shorthand commands (`gh repo view` etc.) failed to resolve the repo when `origin` is an SSH host alias remote** (e.g. `git@github.com-work:owner/repo.git`) — `gh`'s host allowlist can't recognize aliases. A new `resolve_owner_repo()` (`hooks/scripts/lib/git-remote.sh`) parses owner/repo directly from the `git remote` URL instead of depending on `gh repo view`, and `-R`/`--repo` is now propagated explicitly across internal scripts, SKILL.md procedure snippets, and recovery-hint commands wherever they depend on repo context. (#1913, #1917, #1919, #1921)
- **`mktemp`'s hardcoded `/tmp`-root templates are eliminated project-wide for sandbox environments**, where writes are confined to `$TMPDIR` and `/tmp` itself is read-only — both production code and the test harness now use the `${TMPDIR:-/tmp}/rite-*` form, and a new `tmp-hardcode-check.sh` lint guard (check table #16) prevents regressions. (#1902, #1909, #1910)
- **Sandbox write-blocking mounts (character-device `/dev/null` bind mounts) were misdetected as untracked (`??`) by `git status`**, causing `cleanup`/`recover`/`issue-update`/`pr-create`'s dirty checks to false-positive with no real changes present — a new shared filter (`lib/git-status-filtered.sh`) excludes only untracked character-device entries, and the 4 affected skills' dirty checks now go through it. (#1936, #1937)
- **`issue-implement` replaces `git add .` with explicit path staging (`git add {changed_files}`)** — sandboxed sessions mask read-denied home dotfiles (`~/.ssh`, `.bashrc`, `.gitconfig`, etc.) as untracked character devices, and `git add .` hard-failed (exit 1) trying to pick them up as "not a regular file," stalling the implementation-phase commit. (#1926)

### Known Limitations

- `git push`/`fetch` over an SSH host alias (e.g. `git@github.com-work:...`) has no permanent fix on Linux/WSL2 with sandbox enabled — `sandbox.excludedCommands` cannot bypass the network sandbox (upstream: not planned). The supported workaround is re-running the specific blocked command with `dangerouslyDisableSandbox: true`; `/rite:setup` now warns about this proactively.
- With `multi_session` and sandbox both enabled, writes from a session worktree's cwd into the main checkout (state files written by `flow-state.sh` / `issue-claim.sh` etc.) can be rejected. The main checkout root's absolute path must be added to the sandbox write allowlist manually; `/rite:setup` now guides this proactively.
- Reviewer subagents spawned via Task cannot be passed a sandbox-bypass flag equivalent to `dangerouslyDisableSandbox`.

## [0.8.3] - 2026-07-16

### Fixed

- **`/rite:batch-run`'s `run-queue.json` is now session-scoped to stop concurrent batch-runs from clobbering each other** — the queue file is renamed `run-queue-{session_id}.json` (session_id derived from `flow-state.sh path`, reusing the canonical `_resolve_session_id`), so two sessions running `/rite:batch-run` in parallel under `multi_session` worktrees each hold an independent queue instead of overwriting/deleting a shared repo-global `run-queue.json` (which caused mis-reported completion and unrecoverable resume). All readers/writers follow suit — `batch-run/SKILL.md` steps 0-8 (fail-loud if session_id is unresolvable rather than falling back to the global name), `iterate/SKILL.md` step 6's circuit-breaker batch detection, and `recover/SKILL.md` Phase 5.5 (both read-only sites degrade safely to interactive / no-continuation on an unresolvable session_id). Batch resume is now strictly same-session; single-session behavior (compact-crossing persistence, arg-less resume, Phase 5.5 detection) is unchanged since session_id is stable across compaction and turns.
- **Reviewer subagents can no longer mutate the parent working tree or `.git` via Edit/Write** — a new `pre-tool-edit-guard.sh` PreToolUse hook (matcher `Edit|Write|MultiEdit|NotebookEdit`) denies a reviewer subagent's Edit/Write when the target is inside the repo but outside an isolation worktree. Isolation is judged by the target's owning git worktree root (resolved via dirname walk-up + `git -C`) rather than a path substring match, so `..`-reentry and token-in-filename bypasses no longer slip through while worktree-only mutation testing (`rite-review-mutation-*` / `rite-revert-test-*`) is not misdetected. Writes into the parent `.git` directory (e.g. `.git/hooks/pre-commit`, `.git/config`) are denied too, since those enable arbitrary code execution in the non-sandboxed main session. `post-review-state-verify.sh` gains a 4th worktree-hash axis (advisory), and `_reviewer-base.md` documents the isolation-worktree-only constraint for Edit/Write/MultiEdit/NotebookEdit. (#1860, #1863)
- **Reviewer subagents can no longer reach the parent `.git` via Bash or symlink** — closing the residual gap left by the Edit/Write guard (#1863). `pre-tool-bash-guard.sh` gains sub-block (H) that denies `.git`-directory writes through redirection (`> .git/…`) and positional file-writing verbs (`tee`/`cp`/`mv`/`ln`/`install`/`rsync`/`truncate`/`dd of=`/`sponge`/`patch`), while `.git` reads (`cat`/`ls`/`grep`, `dd if=`) and isolation-worktree creation are not misdetected. The `.git`-path check runs over a pre-normalization snapshot with full quote- and backslash-dequoting (mirroring POSIX quote-removal) on both the path and verb tokens to close static-obfuscation bypasses, the tokenizer is `set -f`/`set +f` noglob-wrapped to prevent hook-CWD glob pollution and timeout→fail-open, and the verb allowlist is declared non-exhaustive (COMMON-SET). `pre-tool-edit-guard.sh` also physically resolves a symlinked final path component before the isolation check. (#1864, #1865)
- **`pre-tool-bash-guard.sh`'s `git worktree add` argument scan is now glob-safe** — the `for tok in $WT_ARGS` loop is wrapped in a `set -f`/`set +f` noglob scope (matching the (H) tokenizer), closing two exposures: an over-DENY where a flag-named file (`-b` etc.) in the hook CWD let `*` expand and misclassify a valid `git worktree add <path> <ref>` as the new-branch form, and a timeout→fail-open where a large-directory glob made the loop iterate unbounded until the PreToolUse hook timed out and bypassed the worktree-add branch-leak check. (#1866, #1867)
- **`/rite:batch-run` no longer stalls on `open`'s plan approval or `pr-review`'s configuration prompt** — reconciling batch-run's declared fully-autonomous (no-confirmation) contract with actual behavior. `open` step 3.4 now auto-approves the implementation plan when a batch run is active (run-queue detection, same shape as `iterate` step 6), while standalone runs still use `AskUserQuestion`; `pr-review` step 3.3 skips the reviewer-configuration `AskUserQuestion` on the E2E (iterate-driven) path via a flow-state phase-whitelist check (same shape as `ready` Phase 2.1), keeping the launched/omitted-reviewer summary lines on both paths. Both fall back to interactive/standalone on helper failure. (#1861, #1868)

## [0.8.2] - 2026-07-15

### Added

- **`setup` detects and warns on a version mismatch between `plugin-path-resolution.md`'s two resolution methods** — step 4.5.0's marketplace branch now cross-checks the direct key lookup against the canonical one-liner resolution and displays both paths, the mismatch, and remediation guidance when they disagree (non-blocking; matching resolution is unaffected). Adding a third resolution method is now explicitly disallowed in `plugin-path-resolution.md`. (#1833, #1841)

### Fixed

- **`installPath` semantics are now consistent across all consumers** — real-environment verification against `rite@rite-marketplace` v0.8.1 confirmed `installPath` points at the plugin root itself (`hooks/`, `skills/`, `scripts/`, `references/` sit directly under it, with no `plugins/rite/` intermediate directory). `hook-preamble.sh`'s incorrect `$current_install_path/plugins/rite/hooks` reference (which had silently turned the version-redirect logic into dead code) is corrected, and `plugin-path-resolution.md` now documents the verified semantics. (#1842, #1852, #1854)
- **Work Memory (WM) sync route is repaired** — `open/SKILL.md` step 2.5's initial WM post now wires an explicit `issue-comment-wm-sync.sh init` call with a status branch table (previously prose-only, so the call was never actually made), and `work-memory-update.sh` no longer discards the accumulated `## Detail` section on every phase-transition rewrite — it extracts and preserves that section verbatim, regenerating only the `Phase:`/`Branch:` header lines. (#1830, #1838)
- **WM sync route follow-up hardening** — `work-memory-update.sh` surfaces a return-code-bearing WARNING when `detail_extra` awk extraction fails instead of silently falling back, `issue-comment-wm-sync.sh`'s init pre-check gains a regression test pinning its non-blocking-degrade contract, 10 parent-shell tempfiles are protected under one file-wide cleanup function with an EXIT/INT/TERM/HUP trap, and the WM-sync architecture diagram is updated to match. (#1844, #1849)
- **Review-result and PR-state storage is unified onto `state-path-resolve.sh`** — `review-result-save.sh`'s `REVIEW_RESULTS_DIR` default and `review-source-resolve.sh`'s local-JSON read priority now resolve through the same state-root anchor `wiki-ingest-trigger.sh` already used, fixing a `multi_session` mismatch where a session worktree wrote review results and PR-state (accepted-fingerprints, fix-cycle-state) cwd-relative inside the worktree while the main checkout read/deleted from a different path (an explicit `--results-dir`/`--repo-root` still takes priority; resolution failure falls back to cwd-relative with a WARNING). (#1831, #1839)
- **Regression tests pin the 4 observation points changed by the state-path-resolve unification** — a new `state-root-observers.test.sh` (11 assertions) covers `review-schema-version-check.sh --all` drift detection from a worktree cwd, `review-skip-notification.sh`'s state-root path display, and `distributed-fix-drift-check.sh` Pattern 6's `--repo-root` non-propagation contract, closing a gap where these behaviors were verified only by manual sandbox testing. (#1845, #1850)
- **`open`/`cleanup`'s GitHub Projects Status update is inlined to stop silent skips** — both `open/SKILL.md` step 2.4(A) (Status → In Progress) and `cleanup/SKILL.md` step 8 (Status → Done) previously described delegation to `projects-status-update.sh` in prose only, with no actual bash call in the skill body; inside long autonomous chains like `/rite:batch-run` this reference-only step was skipped, leaving Status stuck at Todo/In Progress instead of reaching its final state. (#1846, #1847)
- **`projects-status-update.sh` call sites no longer discard failure detail** — the `status_json=$(bash ...) || status_json=""` pattern used in `ready/SKILL.md`, `issue-close/SKILL.md`, and `cleanup/references/archive-procedures.md` overwrote the script's already-emitted failure JSON (including `.warnings[]`) with an empty string whenever the script exited non-zero; the fallback is unnecessary since command substitution captures stdout regardless of exit status, and is removed from the 4 remaining sites. (#1848, #1851)
- **`multi_session` gains a dirty-main-checkout guard in `open`/`cleanup`** — `open` step 2.2-W detects uncommitted changes in the main checkout before creating a session worktree and asks (via `AskUserQuestion`) whether to carry them into the worktree, proceed anyway, or abort, only when they overlap the Issue's target files; `cleanup` step 4 verifies merge success after 3 failed `git merge --ff-only` retries and offers a diff-confirmed discard or a stash-and-terminate path instead of silently discarding uncommitted work or leaving conflicting state. (#1832, #1840)
- **`pr-review` step 4.3.1 requires an explicit `run_in_background: false` on every reviewer Task spawn** — the prior prohibition ("do NOT use `true`") left the parameter's default unstated, and the harness's default of background execution meant omitting the parameter silently spawned reviewers in the background; this is now a MUST with rationale documented. (#1834, #1843)
- **`issue-create` pre-creates labels idempotently and surfaces helper failures** — label creation no longer fails when a label already exists, and helper failures are surfaced as a result instead of being swallowed. (#1829, #1837)
- **`lint`'s `gitignore-health-check` false positives are fixed** — the check now performs an effective-ignore determination instead of a naive pattern match, and unreachable entries introduced by `setup` are excluded from the scan. (#1836)
- **`setup` re-runs `gh project link` idempotently after Project creation** — fixes a first-Issue-create Projects registration failure that occurred when the newly created Project wasn't yet linked to the repository. (#1835)

## [0.8.1] - 2026-07-11

### Fixed

- **`recover` now detects and resumes an interrupted `/rite:batch-run` queue** — a new Phase 5.5 in `recover/SKILL.md` autonomously judges whether an interruption occurred mid-active-batch (via `run-queue.json`'s `active` flag, cursor match, and a 2-hour freshness check reusing `session-ownership.sh`'s `parse_iso8601_to_epoch`) and, if so, continues processing the remaining queue by following `batch-run/SKILL.md`'s existing step 3-8 branch table rather than duplicating it; stale `run-queue.json` leftovers no longer trigger a false continuation. `run-queue.json` gains an `updated_at` timestamp field, updated on every cursor advance / active-flag write. (#1820, #1821)

## [0.8.0] - 2026-07-10

### Changed

- **Four skills are renamed to resolve base-name collisions with Claude Code's built-in slash commands** — `run` → `batch-run`, `review` → `pr-review`, `init` → `setup`, and `resume` → `recover`. **Breaking change — invoke skills by their new names:** `/rite:run` → `/rite:batch-run`, `/rite:review` → `/rite:pr-review`, `/rite:init` → `/rite:setup`, `/rite:resume` → `/rite:recover`. All in-repo references, cross-links, and sentinel-contract identifiers are updated accordingly; these are pure renames with no behavior change. (#1788, #1790, #1793, #1794, #1795, #1796, #1800, #1803, #1804)
- **The reviewer registry's three-way sync (`agents/*-reviewer.md` ⇔ the `pr-review/SKILL.md` Available Reviewers table ⇔ its Reviewer Type Identifiers table) is now verified by a single machine check** instead of only the tech-writer-row equality check, catching agent-only additions, one-sided table updates, and slug mismatches that previously passed silently. (#1743)
- **Per-call hooks gain an early-exit fast path and consolidated `jq` calls for non-rite projects**, reducing the per-Bash/Edit-call subprocess cost outside rite projects while leaving rite-project inputs, outputs, and side effects unchanged. (#1737)
- **`pr-review/SKILL.md` and `fix/SKILL.md` are put on a context diet** — design rationale, historical background, and external-spec narration move out of the skill body into `references/`, shrinking `fix/SKILL.md` by 8.2% (4,040 → 3,709 lines) and `pr-review/SKILL.md` by 13.1% (4,040 → 3,510 lines). The "SKILL.md < 500 lines" principle is revised to match this two-tier reality (entry skills stay under 500 lines; execution-procedure skills are capped at 4,000). (#1774)

### Added

- **`/rite:unknowns` skill** — a new explicitly-invoked pre-implementation exploration session (blind-spot pass, multi-approach brainstorming, throwaway HTML prototypes, requirements interview) that ends by emitting an exploration summary for downstream skills like `issue-create`. Wired to `wiki-query-inject.sh` so accumulated Wiki lessons feed the blind-spot pass. (#1805)
- **`issue-create` recognizes a `/rite:unknowns` exploration summary and lightens Assumption Surfacing accordingly** — questions and blind spots already resolved by the summary skip re-asking, and unresolved questions flow directly into the existing three-way classification. (#1806)
- **`issue-create` Step 4.0 gains a "blind spot pass" (unknown unknowns) sub-step** for Complexity M+ issues, feeding discoveries into the existing derive/ask/defer classification without new code paths. (#1755)
- **`open` Step 3.3's implementation-plan template adopts a volatile-first ordering rule** — items likely to change under user judgment (data model changes, type/interface definitions, user-visible behavior/UX) are presented before mechanical refactors and boilerplate, focusing plan-approval review on substantive decisions. (#1752)
- **`pr-review` Step 7 is redesigned from "automatic Issue creation" to "out-of-scope finding triage"** — the AskUserQuestion recommendation moves from agent discretion to a rule-table machine decision, gains a "record to Decision Log" option, and approved records are appended to the source Issue's Section 9 Decision Log (or work memory as fallback). (#1802)
- **`pr-review` gains a `max_reviewers` cap and a pre-spawn cost-estimate summary** — reviewer selection now caps the spawned reviewer count after the existing min-reviewer/mandatory-Security guards, and always surfaces which reviewers were dropped and why instead of silently capping. Default `max_reviewers: 6` preserves prior selection for matches within the cap. (#1729)
- **`pr-create` PR bodies now summarize the Decision Log and plan-deviation log** — Phase 3.2.2 reads the Issue's Section 9 Decision Log and work memory's plan-deviation log, surfacing implementation-time judgment calls that a diff alone can't show; the section is omitted when both are empty. (#1756)
- **`iterate`'s review⇄fix loop gains a circuit breaker** — `safety.max_review_cycles` (default 5) bounds non-convergent review/fix cycling; on `batch-run`, a maxed-out PR is recorded as failed and the cursor advances instead of stalling the whole batch. (#1728)
- **`recover` detects merge-conflict and interrupted-rebase state** — unmerged markers, `MERGE_HEAD`, and `rebase-merge`/`rebase-apply` (resolved worktree-safely via `git rev-parse --git-path`) are surfaced ahead of phase inference, so conflict resolution isn't skipped in favor of a generic "implementation in progress" recovery. (#1734)
- **`batch-run` shows a pre-run summary before starting** — issue count, run mode, a rough time estimate, and interrupt/resume guidance are shown once right after the queue is finalized, plus an "N/M done" progress line per completed Issue. (#1733)
- **`setup` now writes a `safety` section into `rite-config.yml`** — previously commented out below the `--- Advanced ---` marker, `safety` (`max_implementation_rounds`, `max_review_cycles`, etc.) is promoted to the active block alongside `wiki`/`multi_session`/`tdd`, so a fresh config surfaces these safety limits instead of hiding them. (#1732)
- **The sentinel contract (~29 `[skill:action]` strings) is now Single-Source-of-Truth documented and CI-verified** — `sentinel-contract.md` centralizes the emitter/consumer table, `sentinel-contract-check.sh` verifies it bidirectionally, and the check runs as `lint` Phase 3.20 and in a dedicated GitHub Actions workflow on every push/PR. (#1771)

### Fixed

- **`fix.md` Step 5.1's sentinel-based continuation check now correctly handles an `accept` decision** — the prior logic keyed off a nonexistent "separate Issue count" left over from a policy removed in commit `0dee5b22`; it now checks the `ACCEPT_FINGERPRINT_PERSISTED` marker that Step 2.1.A already emits, so an accept decision doesn't fall through to an unconditional "normal completion" without confirming the suppression actually took effect on the next review. (#1813)
- **`flow-state.sh`'s `cmd_set` no longer silently drops `wm_comment_id`** — the field written directly by `issue-comment-wm-sync.sh`'s `cache_comment_id()` was missing from the merge-preserve whitelist used when `cmd_set` rebuilds the JSON, so it vanished on the next unrelated phase-transition `set`. (#1812)
- **`issue-comment-wm-sync.sh` and `cleanup-work-memory.sh` are schema_v2/v3 multi-state aware** — both resolved `FLOW_STATE` by writing directly to the legacy shared file (`.rite-flow-state`) instead of going through the canonical per-session resolver (`.rite/sessions/{sid}.flow-state`), causing `wm_comment_id` cache misses (extra `gh api` scans) and stale `active:true`/`phase:cleanup` sessions to linger past `/rite:cleanup`, confusing `/rite:recover` and the Stop hook. Both now resolve via `flow-state.sh path` and fall back to the legacy file (with a warning) only on resolver failure. (#1808, #1809)
- **`pre-tool-bash-guard`'s Pattern 4 (blocking reviewer-subagent state-mutating git commands) is fail-closed and has a timeout** — Pattern 4 shared a fail-open `ERR` trap with convenience Patterns 1–3, so a parser crash on unexpected input converged on `exit 0` (allow), letting a single crash bypass the reviewer read-only guard; Pattern 4 now fails closed independently, and `PreToolUse:Bash` gains the timeout every other hook already had. (#1736)
- **`test-distributed-fix-drift-check.sh` no longer fails on shallow clones** — a `git fetch --depth=1 origin <full-sha>` fallback resolves the otherwise-unreachable baseline commit (now referenced by full SHA), and remaining-unreachable cases produce an explicit skip message instead of a silent pass or a false CI failure. (#1741)
- **Locking is hardened against three known gaps** — `issue-claim.sh`'s stale-steal now compare-and-swaps the holder under the lock (closing a TOCTOU window where two sessions could both classify and steal the same stale claim), PID-reuse is detected instead of trusted on sight, and eval-time validation is made symmetric with sibling scripts. (#1742)
- **`reviewer-registry-drift-check.sh` improves diagnostic precision and closes a slug-regex blind spot** — per-source error messages stop swallowing `find` stderr (e.g. `EACCES`) in the `agents/` path, and the identifier regex now accepts digits in slugs (e.g. `web3-reviewer.md`), which previously fell out of all three tracked sets and passed silently. (#1762)
- **A `@tsv` + `IFS` field-shift hazard is fixed across the remaining per-call hooks** — following the `bang-backtick-edit-hook.sh` fix in #1737, `session-start.sh`'s `_reset_active_state()` (and other affected sites) switch to a unit-separator (`\x1f`) join/read so an empty intermediate TSV field no longer left-shifts subsequent fields. (#1767)

### Removed

- **Two config keys that had zero effect on runtime behavior are removed**: `fix.fail_fast_response` (never read by any consumer; the template itself admitted flipping it did nothing) and `review.scope_assignment.enabled` (consumers read `auto_demote_low` directly and never checked `enabled`, so the documented opt-out never worked). `auto_demote_low` itself remains fully wired and is unaffected. (#1727)

## [0.7.2] - 2026-07-01

### Fixed

- `disable-model-invocation: true` is removed from 14 user-invocable skills (`issue-create`, `issue-update`, `issue-close`, `issue-edit`, `wiki-init`, `wiki-query`, `learn`, `skill-suggest`, `template-reset`, `getting-started`, `workflow`, `investigate`, `resume`, `run`) — the Claude Code CLI routes an explicitly typed slash command and the model's own Skill-tool invocation through the same path, so when native slash-command dispatch is not recognized (e.g. with an attached image), the model's Skill-tool fallback was blocked by this flag, causing the user's own direct invocation to fail (see [anthropics/claude-code#43660](https://github.com/anthropics/claude-code/issues/43660)). `workflow` and `investigate` descriptions gain the non-auto-activate wording that the flag used to carry. (#1694)

### Changed

- `reviewers/SKILL.md` frontmatter gains `user-invocable: false`, and the `docs/SPEC.md` frontmatter policy table's third category is corrected to match: `user-invocable: false` guarantees the absence of a `/rite:<name>` command, while `disable-model-invocation` is reserved for suppressing auto-activation on skills with a broad description. (#1696)

## [0.7.1] - 2026-06-30

### Added

- The intro video HyperFrames sources are now tracked in-repo under
  `media/intro-video/` (Japanese) and `media/intro-video-en/` (English), so
  video updates complete inside this repository instead of an external
  out-of-tree directory; each project carries a `PROVENANCE.md` documenting
  build steps and BGM source/license. (#1688)

### Changed

- The intro video content and README video links are updated to the v0.7.0
  spec: command names use the v0.7 flat hyphenated form (`open`, `iterate`,
  `ready`, `merge`, `cleanup`, `issue-create`), `scene-goal` now demos
  `/rite:run --merge` self-driving, a new `scene-docheavy` scene covers
  Doc-Heavy PR Mode, and the README video duration note becomes ~115 seconds. (#1688)

## [0.7.0] - 2026-06-30

### Changed

- **Workflow entry points migrated from `commands/` to native Claude Code skills (`skills/`)** — each former `commands/<group>/<name>.md` is now a `skills/<name>/SKILL.md` that Claude Code auto-detects, and orchestrator skills (`open`, `iterate`, `run`, …) invoke sub-skills (`review`, `fix`, `pr-create`, `issue-implement`, …) through the Skill tool. **Breaking change — the invocation namespace is flattened:** the grouped colon form is gone; invoke skills by their flat names instead. Migration: `/rite:pr:open` → `/rite:open`, `/rite:pr:review` → `/rite:review`, `/rite:pr:create` → `/rite:pr-create`, `/rite:issue:create` → `/rite:issue-create`, `/rite:wiki:ingest` → `/rite:wiki-ingest`, and likewise for the remaining `pr:` / `issue:` / `wiki:` commands. (#1682)
- **The SessionStart hook's CRITICAL banner is downgraded to a `/rite:resume` pointer** — with the preflight mechanism removed, post-compact recovery is consolidated onto `/rite:resume` instead of an unconditional CRITICAL session-start block. (#1682)

### Removed

- **The `commands/` directory is removed in full (42 files)** along with the old grouped command naming; `skills/` is now the single source for both entry points and execution procedures, and the `lint` scanners were repointed from `commands/` to `skills/`. (#1682)
- **The `preflight-check.sh` mechanism is removed** — its responsibilities are folded into `/rite:resume`, and the architecture diagram and README no longer reference Preflight Check. (#1682)

## [0.6.12] - 2026-06-29

### Fixed

- **Flow entry paths now detect and rebuild a missing session worktree for an existing work branch under `multi_session.enabled: true`** — when a work branch existed locally but its session worktree (`.rite/worktrees/issue-{N}`) was absent, `/rite:resume`, `/rite:pr:review`, `/rite:pr:iterate`, and `/rite:pr:fix` treated the branch as nonexistent and silently fell back to `develop`, leaving PR changes unreadable from the work tree (degraded operation). A new `ensure_session_worktree` helper in `lib/worktree-git.sh` detects the "branch exists ∧ session worktree absent" case and rebuilds the worktree (local: `git worktree add`; remote: fetch + `--track`). (#1676, #1677)

## [0.6.11] - 2026-06-28

### Fixed

- **`/rite:pr:cleanup` no longer self-blocks worktree and branch deletion for the Issue it is cleaning up** — the cleanup live-cwd guard (`worktree-live-cwd.sh`) could not distinguish the cleanup session's own working directory from another session's, so it detected itself as "live" and deferred deletion. A new `worktree-foreign-cwd.sh` probe excludes the self process tree (`--self-root`) so deletion is deferred only when another live session is actually present. Branches that are genuinely deferred — previously left permanently with no recovery path — are now recorded in the reap manifest and reclaimed by the next session, while unmerged/dirty branches stay protected. (#1670, #1671)

## [0.6.10] - 2026-06-26

### Fixed

- **The `/rite:wiki:ingest` raw-source write path now matches the commit scan path in multi-session worktree mode** — under `multi_session.enabled: true`, `wiki-ingest-trigger.sh` wrote raw sources to a `$PWD`-relative `.rite/wiki/raw/` (the session worktree) while `wiki-ingest-commit.sh` scanned the main checkout's `.rite/wiki/raw/`, so raw sources collected from a session worktree were silently dropped instead of committed to the wiki branch. Both sites now resolve the same scan root. (#1664, #1665)
- **Raw-source accumulation now self-heals from a corrupt/orphaned `.rite/wiki-worktree`** — a stale gitdir pointer (e.g. after a repository move) left an orphaned `.rite/wiki-worktree` that passed the `[ -d ]` fast-path but failed `git rev-parse`, silently halting raw-source accumulation; the path now recovers instead of stopping silently. (#1662, #1663)
- **Box-drawing frames no longer misalign their right border when the header contains full-width characters** — right-border padding was counted by code points, so full-width (East Asian Width `W`/`F`) characters widened the inner width; padding now treats full-width characters as 2 columns to match the top border's `─` count, with the rule captured in `references/box-display-width.md`. (#1660, #1661)

## [0.6.9] - 2026-06-25

### Fixed

- **The `.claude/scheduled_tasks.lock` file is now gitignored and untracked** — this session-specific lock file, which the Claude Code harness overwrites every session, kept the working tree permanently dirty and aborted `git pull` under `pull.rebase=true`. It is now ignored per-file (not via a blanket `.claude/` ignore, since `.claude/skills/release/SKILL.md` is intentionally committed). (#1654, #1655)

## [0.6.8] - 2026-06-24

### Fixed

- **The release skill's Phase 1 latest-tag detection is now reachability-independent and limited to the `vX.Y.Z` release-tag format** — detection uses `git tag --sort=-v:refname` filtered by `grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'` (preceded by `git fetch --tags --force`) instead of `git describe --tags --abbrev=0`, so the latest release tag is found correctly even when it sits on a `main` merge commit unreachable from `develop`, and non-release tags are excluded from the version sort. (#1643, #1647)
- **The release skill's Phase 1 tag-sync no longer fails silently** — a failed `git fetch --tags --force` now emits a log line and continues with local tags instead of swallowing the error. (#1648)

### Docs

- **Documented that the `git tag … | head -1` SIGPIPE is benign in the release skill** — the trailing `head -1` can close the pipe early, but `latest_tag` is guarded by a `[ -n "$latest_tag" ]` check so the pipeline exit status is never consulted; a note clarifies this and flags the `set -o pipefail` caveat for the future. (#1649)

## [0.6.7] - 2026-06-24

### Fixed

- **Parent-Issue detection in `cleanup.md` no longer misidentifies the closing Issue itself or an unrelated Issue as the parent** — the Tasklist fallback now fetches multiple candidates, excludes self-matches, and re-validates each candidate's body for an actual `- [ ] #N` / `- [x] #N` tasklist line instead of adopting the first GitHub code-search hit. (#1637)
- **Parent-Issue detection via tasklist search in `projects-integration.md` and `close.md` no longer misidentifies self or unrelated Issues as the parent** — the search retrieves multiple candidates, excludes self-matches, and validates candidate bodies before adopting a parent. (#1634)
- **`/rite:pr:open` now surfaces the parent-Issue GitHub Projects status update in `open.md`**, so starting work on a Sub-Issue transitions the parent Issue's status from Todo to In Progress instead of leaving it at Todo. (#1630)
- **Resolved the contradictory standalone parent-not-detected handling in `projects-integration.md`** — the spec now consistently emits the `[DEBUG] parent not detected` log before skipping, matching the rule that silent skips are prohibited. (#1636)
- **Unified the standalone parent-not-detected DEBUG wording to `methods tried:` across `close.md`, `projects-integration.md`, and `open.md`**, so all three sites emit verbatim-identical diagnostics. (#1635)

## [0.6.6] - 2026-06-24

### Fixed

- **GitHub Projects registration no longer performs owner-type detection, so Organization-owned Projects are supported** — the previous owner-type probe failed for Projects owned by an Organization; removing it lets both user-owned and organization-owned Projects register. (#1612)
- **GitHub Projects field names resolve via built-in English/Japanese aliases plus optional config overrides, supporting Japanese-named Projects** — field lookups (`Status`/`ステータス`, etc.) now succeed on Projects whose fields use Japanese names without extra configuration. (#1614)
- **PR cleanup worktree detection is anchored to the physical cwd**, eliminating leftover worktrees when a worktree was not recorded in flow state. (#1623)
- **Fixed the `cleanup.md` anchor link to point to `main-checkout`.** (#1611)

### Changed

- **Updated the graphql-helpers owner-type documentation to a `repository()`-independent path**, aligning the docs with the registration logic that no longer depends on `repository()`. (#1615)

## [0.6.5] - 2026-06-22

### Fixed

- **`/rite:pr:cleanup` and `/rite:pr:open` base-branch updates now use `git fetch` + `git merge --ff-only` instead of `git pull --ff-only`** — under a consumer environment with `pull.rebase=true` and a dirty working tree, `git pull --ff-only` aborted early with `cannot pull with rebase: You have unstaged changes` because `git pull` enters its rebase pre-check (which requires a clean working tree) even when `--ff-only` is set. Splitting the update into `git fetch origin {base}` + `git merge --ff-only origin/{base}` bypasses the rebase path entirely, so a fast-forwardable base branch updates reliably regardless of the `pull.rebase` setting or working-tree state. Applies to the `multi_session` and legacy paths of `cleanup.md`, the branch-creation chain of `open.md` (with the `git switch -c` `&&` chain preserved), and the matching descriptions in `getting-started.md` / `docs/SPEC.md`. (#1602)

## [0.6.4] - 2026-06-20

### Fixed

- **`/rite:pr:open` branch creation is now worktree-isolated as a hard invariant under `multi_session.enabled: true`** — branch creation re-resolves `multi_session` from `rite-config.yml` immediately before the branch is created (instead of relying on a `[CONTEXT]` marker that can be lost across resume / context compaction / mid-flow entry), so the `git switch -c` legacy path is reachable only when `multi_session.enabled: false`. After `EnterWorktree`, an invariant check verifies the repository top-level matches the worktree path and halts on mismatch instead of silently continuing on the main tree; `flow-state.sh set --require-worktree` emits a loud warning when a branch/PR phase would be recorded without a worktree. (#1596)

## [0.6.3] - 2026-06-19

### Docs

- Restructured the README into a bilingual layout: `README.md` (English, with the English intro video) and a new `README.ja.md` (Japanese, with the Japanese intro video), cross-linked by a language switcher at the top of each (#1585, #1587)

## [0.6.2] - 2026-06-19

### Docs

- Added a Demo section with an introductory video (Japanese subtitles) near the top of the README (#1580)

## [0.6.1] - 2026-06-18

### Fixed

- **`EnterWorktree` failure under harness git misdetection now points to a restart remedy** — when `multi_session.enabled: true` (default), `/rite:pr:open` Step 2.3-W and `/rite:resume` re-entry detect the harness git repository misdetection (`.git` present and `git` CLI healthy, but the startup check reports false) and recommend restarting Claude Code from the repository root so the already-created worktree is reused (`WT_CASE=reuse`), instead of offering only the prior "abort / `git switch -c`" fallback. Documented in `getting-started.md` and `git-worktree-patterns.md`. (#1574)

## [0.6.0] - 2026-06-18

### Added

- **Canon TDD cycle for the implementation phase** — when `tdd.enabled: true` (default on), `/rite:issue:implement` drives implementation through a Canon TDD loop: pick one behavior from the test list → confirm Red → minimal Green → Refactor → repeat until the list is empty. Falls back gracefully: `commands.test: null` runs in "Degraded TDD" mode (test-list discipline kept, auto-run skipped with a warning), and `tdd.enabled: false` restores the prior non-TDD flow. (#1567)
- **`tdd:` configuration section, default-on (opt-out)** — distributed `rite-config.yml` ships a `tdd:` section with `enabled: true`; `/rite:init --upgrade` back-adds it to existing projects via the same active-section mechanism as `wiki` / `multi_session`. (#1566)
- **Canon TDD documentation and test-list framing** — the Issue template Section 6 "Test Specification" is now framed as the Canon TDD test list (one T-xx row = one Red→Green→Refactor cycle), reflected across `skills/rite-workflow`, `docs/SPEC.md`, getting-started, and `pr/open.md`. (#1568)

## [0.5.5] - 2026-06-17

### Fixed

- **`bang-backtick-check.sh` no longer hard-blocks consumer repos** — a new `--skip-if-no-target` flag makes `--all` return a clean skip (rc=0) instead of an `rc=2` invocation error when there is no `plugins/rite/` markdown to scan (marketplace-only consumer repos), removing the forced manual gate bypass in `/rite:pr:ready` and `/rite:pr:create`. Self-host repos keep the original `rc=2` misconfiguration diagnostic. (#1551)
- **Active-but-idle session worktrees protected from lazy reap** — `pr-cycle-cleanup.sh` keeps a worktree whose issue claim holder is `active=true` even when the claim heartbeat has gone stale (idle past `CLAIM_STALE_SECONDS`), preventing the `/clear` "Path does not exist" error from recurring on resume. (#1553)
- **Read-only commands relay their real output again** — removed `context: fork` from `/rite:issue:list`, `/rite:investigate`, `/rite:workflow`, and `/rite:skill:suggest` so their output is shown inline instead of being replaced by the harness control wrapper. (#1556)
- **`orphan-reference-check.sh --all` works inside session worktrees** — the `--all` scan now walks paths relative to `REPO_ROOT`, so running from a `.rite/worktrees/issue-N` worktree no longer excludes every file and exits `2`; orphan detection is restored under the default `multi_session.enabled: true`. (#1557)

## [0.5.4] - 2026-06-16

### Added

- **OKF v0.1 minimal conformance for Wiki concept pages** — concept page frontmatter now carries `type` and `okf_version` fields, aligning Wiki pages with Open Knowledge Format v0.1.
- **OKF v0.1 sync and upstream visualizer integration guide** — documentation now covers OKF v0.1-conformant synchronization and connecting the upstream visualizer.

### Changed

- **`/rite:pr:run` defaults to draft-only** — the command runs `open → iterate` (stopping at draft) by default, and `ready → merge → cleanup` is opt-in via the `--merge` flag.
- **Wiki `index.md` reshaped to OKF bullet form with two-pass query** — `index.md` adopts an OKF bullet structure and `wiki:query` resolves in two passes.
- **Wiki `log.md` reshaped to OKF form** — `log.md` adopts an OKF structure and the `ingest:skip` state moves into raw frontmatter.

### Fixed

- **`wiki:close` heredoc write-failure guard** — `close.md` Phase 4.4.W guards against heredoc write failure, mirroring the review/fix path.
- **`/rite:pr` review/fix `$trigger_exit` defensive default** — Step 3 assigns a defensive default to `$trigger_exit`.
- **Live-process worktrees protected from `/clear` "Path does not exist"** — worktrees with a live process are protected so the `/clear` "Path does not exist" error does not recur.

## [0.5.3] - 2026-06-14

### Added

- **`/rite:pr:run`** — a batch PR lifecycle command that runs `open → iterate → ready → merge → cleanup` sequentially and autonomously across multiple Issues.
- **`/rite:lint` number-reference guard** — a `number-reference-check.sh` lint (non-blocking warning) that detects Issue/PR number references (`#NNN`, `Issue #NNN`, `PR #NNN`) re-introduced into the number-free surface (`CHANGELOG.md`, `CHANGELOG.ja.md`, `lint.md`), guarding the cleaned surface against recurrence.

### Fixed

- **Parallel sessions no longer contaminate each other's flow state** — `session_id` resolution is now env-first, so concurrent sessions resolve distinct identifiers instead of clobbering a shared `flow_state`.
- **`/rite:pr:cleanup` reclaims temporary branches and worktrees name-independently** — cleanup no longer relies on branch or worktree naming to find and remove the artifacts it created.
- **In-use session worktrees are protected from reap** — lazy reap skips worktrees owned by active sessions, and `/clear` self-repairs dangling session state.
- **`drift-check` over-detection removed** — eliminated false-positive drift findings and aligned the document-missing reason emitted by the check.
- **`decompose-issues.sh` no longer crashes on an empty `labels_csv`** — Sub-Issue creation handles an empty label set instead of failing.
- **`/rite:pr:merge` success path terminates with a fixed `exit 0`** — a trailing no-op prevents the merge success path from inheriting a non-zero exit status.

### Changed

- **`wiki:ingest` write-failure handling** — the write-failure path now emits a dedicated `content_write_failed` reason instead of a generic failure reason.
- **Documentation surface made number-free and present-tense** — removed implicit history-dependent phrasing (e.g. "the previous behavior", "the old way") and Issue/PR number references across user-facing config and docs, spec and design docs, command/skill/hook/script comments, and tests, stating the rationale directly in prose. The CHANGELOG history-dependent-phrasing policy is now documented in the file header.
- **Account migration** — updated `B16B1RD` references to `asakaguchi` following the repository account transfer.

### Removed

- **README v0.4.0 Breaking Changes section** — dropped the now-historical upgrade notice from the README.

## [0.5.2] - 2026-06-12

### Fixed

- **`/rite:init --upgrade` short-circuit path no longer drops drift back-adds** — when no pending drift was detected, the `--upgrade` short-circuit path skipped the back-add step that the full path performs, so projects taking the short-circuit could miss newly added config sections and sub-keys. The short-circuit now applies the same drift back-add logic, covered by an added drift-detection test.
- **Fixed broken references to the non-existent `_resolve-flow-state-path.sh`** — updated stale script references in the hooks documentation to the actual `flow-state.sh` path.

### Changed

- **Unified flow state on the per-session model** — removed the legacy `flow_state.schema_version=1` (single-file) path from the hooks (`session-start`, `session-end`, `post-compact`, `pre-compact`, `post-tool-wm-sync`), `init.md`, and the config template, consolidating on per-session flow state. Stale `schema_version` test fixtures/labels were neutralized, `commit.contextual` was added to the SPEC Deprecated key list, and `SPEC.md` / `getting-started.md` were updated to follow the `--upgrade` drift back-add behavior change.

## [0.5.1] - 2026-06-12

### Fixed

- **`/rite:init --upgrade` now converges to the latest config defaults** — the `--upgrade` path previously dropped newly added top-level sections, new sub-keys inside existing sections, and the `multi_session` block, producing a two-tier behavior where upgraded projects drifted from what a fresh `/rite:init` produces. `--upgrade` now back-adds `multi_session` with `enabled: true` (an explicit `false` is preserved; idempotent), fills only the missing sub-keys from the template default while preserving existing sibling values, and tracks newly added top-level sections via a drift anchor. Covered by a new sub-key-merge drift-detection test (T-12), which was unified onto the shared `_test-helpers.sh` harness. `commands/getting-started.md` documents the `--upgrade` `multi_session` back-add behavior.

## [0.5.0] - 2026-06-12

### Added

- **Session worktrees for work isolation** — `multi_session` configuration with session-scoped worktree creation via `EnterWorktree`, resume re-entry, and lazy reap on cleanup. Default ON (opt-in → default).
- **Issue claim mechanism** (`issue-claim.sh`) — fail-fast guard preventing two sessions from working the same Issue concurrently.
- **`/rite:learn`** — Socratic understanding-check command for completed Issue/PR sessions.
- **Assumption Surfacing step** in `/rite:issue:create` — surfaces implicit model assumptions and classifies them (derive / ask / defer).
- **Knowledge routing (4-channel)** added to coding principles, with comment why-over-what and rejected-alternative routing.
- **Review scope classification** — `scope` / `pre_existing` / `acknowledged` fields (review-result-schema 1.1.0), 3-way recommendation disposition, and a Phase 7 post-condition gate.
- **Wiki lint helper scripts** for the three machine-decidable categories, plus concurrent-ingest exclusion (session lock + push retry).
- **New `/rite:lint` guards** — hardcoded line-number drift, CLOSED+COMPLETED board-not-Done drift, and operational bash-block heaviness.
- Artifacts schema 1.1.0 migration script + version-drift hook.

### Changed

- `multi_session.enabled` now defaults to `true` for new projects.
- Numerous Source-of-Truth consolidations across commands, references, and templates (Type crosswalk, contract section mapping, etc.).
- Reviewer base / severity-levels gained Scope Assignment responsibility.

### Fixed

- Extensive stabilization across the review-fix loop, hooks (flow-state multi-state API, legacy `.rite-flow-state` migration, bang-backtick guard, drift-check), Issue/PR orchestration, and Wiki ingest/query (300+ fixes consolidated since v0.4.0).

> This is a large consolidation release (644 commits since v0.4.0). Entries are summarized at the feature level per the project's CHANGELOG policy.

## [0.4.0] - 2026-04-22

### BREAKING CHANGE

- **Cycle-count-based review-fix degradation fully abolished; replaced by 4 quality signals** — **BREAKING CHANGE**
  - **Removed configuration keys** (three keys from `rite-config.yml`; these keys were never present in `plugins/rite/templates/config/rite-config.yml`):
    - `review.loop.severity_gating_cycle_threshold`
    - `review.loop.scope_lock_cycle_threshold`
    - `safety.max_review_fix_loops`
  - **Removed logic**:
    - `plugins/rite/commands/pr/references/fix-relaxation-rules.md` convergence strategy override table (`severity_gating` / `scope_lock` / `batched` as strategies) and Loop Termination hard-limit row.
    - `plugins/rite/commands/pr/fix.md` Phase 0.4 Convergence Strategy Load (the full block loading `convergence_strategy` from `.rite-flow-state`).
    - `plugins/rite/commands/issue/start.md` Phase 5.4.6 Step 3.5 Review-Fix Loop Hard Limit Check (the `extend (+5) / retry / escalate` 3-choice dialog).
    - `plugins/rite/commands/issue/start.md` Phase 5.4.1.0 cycle-trajectory pattern analysis (Converging / Stalled / Diverging / Oscillating) and the `convergence_strategy` write to `.rite-flow-state`.
  - **New behavior**: the review-fix loop now has exactly two exit paths — (a) 0 findings → `[review:mergeable]`, or (b) any of the **four quality signals** fires → `AskUserQuestion` escalation (`本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション`).
  - **Four quality signals**:
    1. Same-finding cycling — detected in `start.md` Phase 5.4.1.0 via SHA-1 fingerprints of `file + category + normalized message`. One re-occurrence escalates.
    2. Root-cause-missing fix — detected in `fix.md` Phase 3.2.1 by an LLM-semantic check of the commit body for a `root-cause(scope):` action line (new Contextual Commits action type), a `decision(scope):` line that explicitly names the root cause, or a free-form `Root cause:` / `根本原因:` paragraph. Missing → `AskUserQuestion` 3-option prompt.
    3. Cross-validation disagreement — detected in `review.md` Phase 5.2 when two reviewers report the same `file:line` with severity gap ≥ 2 and debate fails to resolve.
    4. Finding quality gate failure — new `Finding Quality Guardrail` in `_reviewer-base.md` filters bikeshedding / defensive / hypothetical / style-only findings before output; if nothing remains, reviewer self-reports as "degraded" via a `### Reviewer self-assessment` section and escalates.
  - **Finding fingerprint specification**: `sha1(normalize(file_path) + ":" + category + ":" + normalize(message))` with identifier masking and Jaccard token similarity > 0.7 for near-match detection. See `start.md` Phase 5.4.1.0 for the full spec.
  - **Minor version bump**: 0.3.10 → 0.4.0 (6 version files synchronized).
  - **Removed-key handling**: The three removed keys are silently ignored at runtime. There is no `/rite:lint` deprecation scan or warning for them.
  - **No cycle-count safety limit (by design)**: There is intentionally no hidden iteration guard. The 4 quality signals are the sole termination mechanism. Reintroducing an iteration counter would contradict the core goal of this release (removing cycle-count-based degradation).

### Migration guide

Existing users with any of the following in `rite-config.yml` should remove those lines:

```yaml
# Remove all three:
review:
  loop:
    severity_gating_cycle_threshold: 5
    scope_lock_cycle_threshold: 7
safety:
  max_review_fix_loops: 7
```

The keys are silently ignored at runtime in v0.4.0. There is no functional replacement — non-convergence is now detected automatically by the four quality signals and no cycle-count threshold needs to be configured.

If you previously relied on `max_review_fix_loops` hitting a hard limit to escape runaway loops, the same safety is now provided by Quality Signal 1 (fingerprint cycling) which fires on the **second** occurrence of any finding — typically faster than any cycle-count threshold would have tripped.

### Changed

- **Review-Fix Cycle Overhaul (Fail-Fast Response + Separate Issue user confirmation + configuration layer)** — **BREAKING CHANGE** (finalizes the rollout, which began with the principles doc layer, the reviewer exit layer, and the Fact-Check layer). Wires the `fix` response layer and configuration layer to the previously-merged principle/exit/fact-check layers.
  - `plugins/rite/commands/pr/fix.md` Phase 2 now begins with a **Fail-Fast Response Principle** section enforcing a 4-item checklist (`throw/raise` propagation / existing error boundaries / not hiding via null-checks / fix the test instead) before deciding a fix approach. Adopting a fallback requires an explicit justification in the commit message; unthinking defensive code is re-flagged at Phase 5 re-review.
  - `plugins/rite/commands/pr/fix.md` Phase 4.3.3 **removes the E2E `AskUserQuestion` skip** — separate-issue creation is now gated by user confirmation **regardless** of caller (E2E `/rite:issue:start` loop or standalone). Options are unified to `retry in current PR / create separate issue / withdraw`, all of which converge to `findings == 0` so the review-fix loop still terminates.
  - `plugins/rite/commands/pr/fix.md` and `plugins/rite/commands/issue/start.md`: the `"severity_gating"` convergence strategy has been **removed**. All PR-originating findings must be addressed within the current PR regardless of severity (本 PR 完結原則). `rite-config.yml` `fix.severity_gating.enabled` is retained as a deprecated compatibility key pinned to `false`. Non-convergence is now handled via the unified `AskUserQuestion` route in fix.md Phase 4.3.3. Use `"batched"` or `"scope_lock"` strategy for non-convergence mitigation instead.
  - `plugins/rite/templates/config/rite-config.yml` adds **config scaffolding keys** (declaration only, runtime wiring tracked as a follow-up): `review.observed_likelihood_gate.*`, `review.fail_fast_first.*`, `review.separate_issue_creation.*`, `fix.fail_fast_response`. The `fix.severity_gating.enabled: false` key is retained as a deprecated compatibility shim and is actively honored (pinned to `false`). **Known limitation**: The non-deprecation scaffolding keys (`observed_likelihood_gate`, `fail_fast_first`, `separate_issue_creation`, `fail_fast_response`) are **not yet referenced by conditional runtime logic** in `commands/` / `agents/` / `skills/` / `hooks/`. The new behavior (Fail-Fast Response Principle, always-confirm separate-issue creation) is hardcoded in `fix.md` Phase 2 / Phase 4.3.3 prose and cannot currently be disabled via config. These keys are provided so users can see the intended configuration surface; wiring them to conditional branches is tracked as a follow-up Issue.
  - `plugins/rite/i18n/{ja,en}/pr.yml` adds four i18n message keys (`review_fail_fast_first_warning`, `review_observed_likelihood_demotion_notice`, `review_separate_issue_user_confirmation_question`, `fix_fail_fast_response_checklist_prompt`) with ja/en parity. **Known limitation**: these keys are **not yet referenced** via the `{i18n:key_name}` lookup in `commands/` / `skills/` / `agents/`. The corresponding prompts in `fix.md` / `review.md` currently embed their text directly. Call-site wiring is tracked as a follow-up.
  - **Migration guide**: Existing users with `fix.severity_gating.enabled: true` in `rite-config.yml` will find the key silently pinned to `false`. Non-convergence is now resolved via the `retry in current PR / create separate issue / withdraw` `AskUserQuestion` at fix.md Phase 4.3.3. Users who relied on automatic severity-based deferral should adopt `"batched"` or `"scope_lock"` strategy. **Opt-out limitation**: the other new config keys (`observed_likelihood_gate`, `fail_fast_first`, `separate_issue_creation`) are **not yet actionable as opt-outs** — the new behavior is currently enforced unconditionally in the prose. To disable any of these, the corresponding prompt sections in `fix.md` / `review.md` must be edited directly until the wiring PR lands.

- **Named subagent invocation for `/rite:pr:review` reviewers** — **BREAKING CHANGE**. `plugins/rite/commands/pr/review.md` now invokes reviewer agents via `subagent_type: "rite:{reviewer_type}-reviewer"` (scoped named subagent) instead of `subagent_type: general-purpose`. Under named subagent invocation, each reviewer's agent file body (`plugins/rite/agents/{reviewer_type}-reviewer.md`) becomes the sub-agent's **system prompt** automatically, and YAML frontmatter (`model`, `tools`) is honored by the runtime. This gives reviewer discipline stronger system-prompt-level enforcement (rather than user-prompt injection which can be diluted) and activates per-reviewer model pins (9 reviewers pinned to `model: opus`). A reviewer_type → subagent_type mapping table was added for the 13 reviewers. Empirical verification confirmed that the `rite:` prefix is mandatory in plugin distribution — bare `{reviewer_type}-reviewer` fails agent resolution with `Agent type not found` error. **User impact**: users previously running reviews on sonnet will see forced opus upgrade for 9 reviewers and a corresponding cost increase (opt-out by removing `model: opus` from individual agent frontmatters). See `docs/migration-guides/review-named-subagent.md` for the full migration guide, opus recommendation rationale, and 3 rollback scenarios (all-reviewer resolution failure / tech-writer Bash permission / verification mode output format broken)
- **`{agent_identity}` placeholder renamed to `{shared_reviewer_principles}` in `review.md`** — **BREAKING CHANGE** (for rite plugin developers editing `review.md` templates). `review.md` now extracts only the shared reviewer principles from `_reviewer-base.md` (Reviewer Mindset / Cross-File Impact Check / Confidence Scoring). Part B (agent-specific identity) extraction was removed entirely — it is no longer needed because the named subagent system prompt delivers agent-specific discipline directly. This is a **hybrid approach**: agent body → system prompt (via named subagent), shared principles → user prompt (via `{shared_reviewer_principles}`). The alternative (inlining shared principles into 13 agent files) was rejected to preserve `_reviewer-base.md` as the single source of truth. The review template sections `## あなたのアイデンティティと検出プロセス` were renamed to `## 共通レビュー原則` to reflect the narrower scope. Preserves the Part A bug fix that ensures Cross-File Impact Check reaches reviewers
- **Retry classification extended with `subagent resolution failure` in `review.md`** — Added a new retry classification entry for the case where the Task tool cannot resolve a scoped subagent name (e.g., `Agent type 'rite:code-quality-reviewer' not found. Available agents: ...`). Retry: **No**. Action: fail immediately with the scoped name used and the error message. Do NOT silently fall back to `general-purpose` — that would defeat the named subagent quality improvement. If all reviewers fail this way, the orchestrator prompts the user via `AskUserQuestion` (retry / rollback to `general-purpose` temporarily / abort review). Classification detection pattern: Task tool response contains `Agent type '{scoped_name}' not found`

- **docs: reflect v0.4.0+ implementation across SPEC / README / CLAUDE.md / CHANGELOG** — Multi-PR documentation alignment sweep after v0.4.0:
  - Commands table + Agent File Format Note — added `/rite:issue:recall` to README / README.ja / SPEC / SPEC.ja Commands tables, added `/rite:init --upgrade` to README.ja, replaced the `subagent_type: general-purpose` note with the named-subagent description
  - SPEC Plugin Structure tree refreshed to match v0.4.0+ file layout (commands/issue sub-skills, commands/pr/references, commands/wiki, agents/_reviewer-base, skills/{investigate,wiki}, hooks/{scripts,tests}, templates/{config,review,wiki}, scripts expansion, references expansion); Configuration section compressed to a pointer to `docs/CONFIGURATION.md`; Hook Specification extended with post-compact / phase-transition-whitelist / verify-terminal-output (removed) / session-ownership / issue-comment-wm-sync / wiki-ingest-trigger + wiki-query-inject / workflow-incident-emit / hook-preamble / helper-scripts sub-sections
  - CLAUDE.md architecture diagram refreshed; `docs/BEST_PRACTICES_ALIGNMENT.md` archived under `docs/archive/` as historical v0.1–v0.3 reference
  - CHANGELOG Unreleased populated with post-v0.4.0 develop activity
  - Repo-wide version rename 1.0.0 → 0.4.0 (next release planned as v0.4.0 not v1.0.0); version files, README badges, CHANGELOG [1.0.0] entry → [0.4.0], and internal `v1.0.0` references updated
- **Bidirectional backlink format unified to colon notation** across `commands/` — `refactor(commands)` aligning Wiki cross-reference style project-wide, and extending existing DRIFT-CHECK ANCHOR blocks in `wiki/ingest.md` / `wiki/lint.md` with bidirectional backlink entries.
- **Semantic anchor migration** — replaced residual hard-coded line-number literals in `commands/init.md:145` and `hooks/scripts/gitignore-health-check.sh:298` with semantic anchors resilient to future edits.
- **`/rite:wiki:lint` `--auto` early-return alignment** — Phase 1.1 / 1.3 early-return paths aligned with the Phase 9.2 three-piece convention so sentinel / status-line / continuation-hint emission is uniform.
- **Wiki skill polish** — `skills/wiki/SKILL.md` EN description aligned with its canonical form; `wiki/lint.md` completion-report UX output order aligned with the canonical frontmatter order.

### Added

- **Workflow incident auto-registration mechanism** — `/rite:issue:start` now auto-detects workflow blockers (Skill load failure, hook abnormal exit, manual fallback adoption) and registers them as Issues to prevent silent loss. New `plugins/rite/hooks/workflow-incident-emit.sh` emits sentinel patterns (`[CONTEXT] WORKFLOW_INCIDENT=1; type=...; details=...; iteration_id=...`) from skill internal failure paths and orchestrator fallback prompts. New workflow incident detection logic in `start.md` detects sentinels via context grep, presents `AskUserQuestion` for confirmation, and calls the existing `create-issue-with-projects.sh` with `Status: Todo / Priority: High / Complexity: S / source: workflow_incident`. Same-type incidents are deduplicated within a session. Failure to register is non-blocking. Default-on via new `workflow_incident:` config section (set `enabled: false` to opt out). 11 unit tests added under `plugins/rite/hooks/tests/workflow-incident-emit.test.sh`. Implements all 10 ACs (Skill load failure / hook abnormal exit / manual fallback adoption detection, dedupe, default-on, opt-out, recommendation-flow non-interference, non-blocking error handling). Driven by the meta-incident demonstrated in an earlier PR cycle, where a Skill loader bug was silently bypassed via Edit-tool fallback
- **tech-writer Critical Checklist concretized** — Added 5 doc-implementation consistency items: `Implementation Coverage`, `Enumeration Completeness`, `UX Flow Accuracy`, `Order-Emphasis Consistency`, and `Screenshot Presence`. Each item carries a verification method (Grep/Read/Glob), and 3 new sample rows have been added to the Prohibited vs Required Findings table sourced from an internal documentation-centric PR case study (private repository, organization name redacted)
- **internal-consistency.md reference** — New reference file that complements `fact-check.md` (external specs) with an internal-facts verification protocol. Defines 5 Verification Protocol categories, Confidence 80+ gate, severity mapping, and a Cross-Reference section linking it to `tech-writer.md`, `review.md`, and related agent files
- **Doc-Heavy PR Detection** — Automatic detection of documentation-centric PRs in `review.md` (formula: `(doc_lines / total_diff_lines >= 0.6)` OR `(doc_files_count / total_files_count >= 0.7 AND total_diff_lines < 2000)`). Excludes rite plugin's own `commands/`, `skills/`, `agents/` `.md` files **and `.md` / `.mdx` translation documentation under `plugins/rite/i18n/**`** (prompt-engineer territory / dogfooding artifacts; non-Markdown translation resources such as `.yml` / `.json` / `.po` under `plugins/rite/i18n/` are not part of the `doc_file_patterns` numerator in the first place, so the exclusion is a no-op for them). Added optional schema `review.doc_heavy.*` (keys: `enabled`, `lines_ratio_threshold`, `count_ratio_threshold`, `max_diff_lines_for_count`) to `rite-config.yml`
- **Doc-Heavy Reviewer Override** — When `{doc_heavy_pr == true}`, promote tech-writer from recommended to mandatory and add code-quality as co-reviewer through one of three independent paths so the final state always has ≥2 reviewers:
  - **Normal path**: Add code-quality when fenced code blocks (` ```bash ` / ` ```yaml ` / ` ```python ` etc.) are detected in the diff. Pure-prose PRs do **not** trigger this path.
  - **Fail-safe path**: When the diff scan itself fails (`git diff` IO error, grep IO error, etc.), code-quality is added regardless of whether fenced blocks were detected, to preserve verification strength when the detection signal is unavailable.
  - **Fallback path**: When no fenced blocks are detected and the Doc-Heavy override produced no addition, the sole-reviewer guard adds code-quality as a fallback in the next phase.

  Passes `{doc_heavy_pr=true}` flag to tech-writer to activate the 5-category verification protocol defined in `internal-consistency.md` (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence), makes the `Evidence:` line mandatory on each finding, and triggers the Doc-Heavy post-condition check in `review.md`
- **`/rite:pr:fix` accepts PR URL / comment URL directly** — `/rite:pr:fix` now accepts PR URL or comment URL arguments in addition to PR number, allowing findings from external review tools (e.g. `/verified-review`) to be parsed directly into the fix loop. Accepted URL formats include trailing paths (`/files`), query strings (`?tab=files`), and fragment identifiers (`#diff-...`) — all are normalized on argument ingest. Comments must contain a markdown table with at least 4 columns (with optional 5th `confidence` column). See `plugins/rite/commands/pr/fix.md` argument-parsing sections for the full argument spec, header detection keywords, and severity alias mapping
- **`[fix:pushed-wm-stale]` output pattern** — `/rite:pr:fix` now emits `[fix:pushed-wm-stale]` when the work memory update soft-failed. Firing conditions map 1:1 to the reason table in `commands/pr/fix.md` — each natural-language phrase below annotates its corresponding `reason` label. See the reason table for the complete list of `reason` values:
  - `current_body` empty → `current_body_empty`
  - `issue_number` not found → `issue_number_not_found`
  - PATCH 4xx/5xx → `patch_failed`
  - `pr_body` grep IO error → `pr_body_grep_io_error` (+ `mktemp_failed_pr_body_grep_err` for its stderr tempfile)
  - branch grep IO error → `branch_grep_io_error` (+ `mktemp_failed_branch_grep_err`)
  - `gh api comments` fetch failure → `gh_api_comments_fetch_failed` (+ `mktemp_failed_gh_api_err`)
  - Python script unexpected exit (generic) → `python_unexpected_exit_$py_exit`
  - `git diff` failure (Python sentinel detection) → `python_sentinel_detected` (reserved exclusively for `GIT_DIFF_FAILED_SENTINEL` match via `sys.exit(2)`)
  - work memory body corruption detected → `wm_body_empty_or_too_short` / `wm_header_missing` / `wm_body_too_small`
  - mktemp failure → `mktemp_failed_*` family (`mktemp_failed_pr_body_tmp`, `mktemp_failed_body_tmp`, `mktemp_failed_tmpfile`, `mktemp_failed_files_tmp`, `mktemp_failed_history_tmp`, `mktemp_failed_diff_stderr_tmp`, etc.)

  The `git diff` failure path also routes through `WM_UPDATE_FAILED=1; reason=python_sentinel_detected` (via Python `sys.exit(2)` and bash `exit 1`). The bash `exit 1` only kills the current bash invocation, but the retained `WM_UPDATE_FAILED=1` flag survives in the conversation context — the soft-failure evaluation still runs, detects the flag via row 2 of the evaluation-order table, and emits `[fix:pushed-wm-stale]` (NOT `[fix:error]`). The hard fail-fast design ensures the PATCH is silently rejected, but the `[fix:pushed-wm-stale]` output pattern is the correct caller-facing signal (see `commands/pr/fix.md` evaluation order and `reason` table for the authoritative flow). Callers (`/rite:issue:start` review-fix loop) **must not** silently treat `[fix:pushed-wm-stale]` as `[fix:pushed]`; instead, they must surface a warning via `AskUserQuestion` and let the user decide whether to continue with stale work memory or pause for manual recovery. See `commands/pr/fix.md` caller semantics for the full contract
- **Bidirectional backlink format verification in `/rite:lint`** — `/rite:lint` now mechanically verifies that Wiki pages maintain bidirectional backlink references in the canonical colon-delimited form. Runs as a non-blocking structural drift check in Phase 3.x and surfaces mismatches in the final report.

### Fixed

- **`wiki-query-inject.sh` origin/wiki fallback** — `/rite:wiki:query` now reads Wiki content via `origin/{wiki_branch}` when the local `wiki` branch does not exist (fresh clone / separate worktree). Previously `git show "${wiki_branch}:.rite/wiki/index.md"` used the bare branch name and failed with `fatal: invalid object name 'wiki'` when only `origin/wiki` was available locally, causing `/rite:wiki:query` to silently return empty context after `/rite:pr:cleanup` on another worktree. Uses the same ref-selection pattern as `cleanup.md` Phase 4.W.1 Step 2 and `wiki-growth-check.sh`. Negative case (neither local nor origin) continues to emit the existing `WARNING: wiki branch not found` and exit 0 (non-blocking). Also adds `wiki_ingest_push_failed` sentinel emission to `cleanup.md` Phase 4.W.3 when `wiki-worktree-commit.sh` reports `push=failed` (rc=4 path inside ingest), so `origin/wiki` divergence becomes observable in the incident layer while preserving loss-safe cleanup continuation. Additionally restores the `wiki_ingest_push_failed` incident type that `plugins/rite/hooks/workflow-incident-emit.sh` was missing from its `--type` whitelist — all existing callers in `pr/review.md`, `pr/fix.md`, and `issue/close.md` that emit this type were silently falling through to the `hook_abnormal_exit` fallback branch, so the dedicated `wiki_ingest_push_failed` sentinel defined in `issue/start.md` ステップ 8.5 (旧 Phase 5.4.4.1 を統合) had never actually been emitted in practice
- **Part A extraction bug in `review.md`** — Fixed Part A section extraction from `_reviewer-base.md` that was dropping `## Cross-File Impact Check` (everything between `## Reviewer Mindset` and `## Confidence Scoring`). Extraction now covers all sections from document start to `## Input` heading (exclusive), enabling the 5 mandatory cross-file consistency checks (deleted/renamed exports, changed config keys, changed interface contracts, i18n key consistency, keyword list consistency) to actually reach reviewer agents for the first time
- **tools/model frontmatter drift in reviewer agents** — Removed `tools:` frontmatter from all 13 reviewer agents (`api`, `code-quality`, `database`, `dependencies`, `devops`, `error-handling`, `frontend`, `performance`, `prompt-engineer`, `security`, `tech-writer`, `test`, `type-design`) and `model: sonnet` from 4 reviewers (`code-quality`, `error-handling`, `performance`, `type-design`). Previously these fields were ignored at runtime (reviewers are invoked via `subagent_type: general-purpose`), but would have silently broken when the named subagent migration completes (tech-writer would lose Bash and break Doc-Heavy PR Mode; 4 reviewers would regress to sonnet for opus users). The 9 remaining reviewers retain `model: opus` as an explicit high-quality review pin (intentionally kept; opus was already the runtime-effective model and removing the pin would have regressed them to session default which may be sonnet). Related `docs/SPEC.md` / `docs/SPEC.ja.md` Agent File Format section updated to mark `tools` as optional (inherit) and the Current Agents table updated to reflect the 4 reviewers as `inherit`
- **Verification-mode post-condition check added** — `review.md` now adds a post-condition check (child of the Verification Mode Findings Collection logic) that validates each reviewer in `verification` mode emits the `### 修正検証結果` table. On initial detection, a per-reviewer retry (via the reviewer invocation Task tool) is attempted with strict verification template instructions; on persistent absence, `verification_post_condition: error` is set, the overall assessment is promoted to `修正必要` (unified with the escalation chain labels — `要修正` is a reviewer-level label and is not used for overall assessment promotion), and all findings from the non-compliant reviewer are treated as blocking. Classification vocabulary is `passed` / `warning` / `error` (unified with `doc_heavy_post_condition`). Retained flags `verification_post_condition` and `verification_post_condition_retry_count` (per-reviewer dict) are registered in the retained flags list and displayed in the verification mode template. Prevents silent pass when a reviewer skips verification output
- **`commands/pr/fix.md` reason-table drift** — Expanded the `reason` table to cover all 28 `WM_UPDATE_FAILED` reasons actually emitted in the work memory update paths (previously only 12 were listed, 16 were missing). The eval-order table row 2 now defers to "reason 表のいずれか" instead of enumerating a subset, eliminating the double-drift problem. DoD verification (manually executed): `comm -3 <(grep -oE 'WM_UPDATE_FAILED=1; reason=[a-z_][a-z_0-9]*' plugins/rite/commands/pr/fix.md | sed 's/.*reason=//' | sort -u) <(awk '/^\*\*`reason` フィールド/{in_table=1;next} in_table && /^\*\*/{in_table=0} in_table && /^\| `[a-z_]/{match($0, /`[a-z_][a-z_0-9]*[^`]*`/); print substr($0, RSTART+1, RLENGTH-2)}' plugins/rite/commands/pr/fix.md | sed 's/\$.*//' | sort -u)` returns empty (28 WM_UPDATE_FAILED reasons in emits exactly match the 28 entries in the reason table). The awk pattern is scoped to the `**\`reason\` フィールド` section to avoid false positives from other tables in `fix.md` (absorbed from C2)
- **Sub-skill return implicit-stop multi-layer defense** — Accumulated fixes hardening the sub-skill return → orchestrator continuation path against Bash heuristic-induced implicit stops. Covers `create-interview`, `wiki/ingest.md` Phase 8 auto-lint, `pr/cleanup` wiki-ingest return, and `pr/cleanup` wiki-auto-ingest Phase 5 boundaries. Includes `INTERVIEW_DONE=1` plain-text marker and `stop-guard.sh` case-arm `WORKFLOW_HINT` expansion with Step 0 Immediate Bash Action.
- **`wiki/lint.md` Phase 9.2 `--auto` continuation sentinel** — `--auto` output now emits an explicit continuation sentinel so callers can distinguish completed-with-warnings from silent-skip.
- **`pr/cleanup` completion message trailing blank line** — Removed the spurious trailing blank line after the "次のステップ" heading for cleaner terminal rendering.
- **Preprocessor-safe syntax migration in `wiki/` and `pr/cleanup`** — Residual `!`+backtick expressions that the slash-command preprocessor evaluated via bash (causing `slash command not found` failures) were migrated to the `if ! cmd; then` form per the documented convention.

## [0.3.10] - 2026-04-04

### Changed

- Review-fix loop overhaul — bash error-handling detection, existing CRITICAL visibility, first-pass rule improvements
- Sole reviewer guard + Step 6 sub-checks extension to eliminate blind spots in single-reviewer scenarios
- Reviewer co-selection expanded — code-quality reviewer now co-selected for code blocks in .md files
- prompt-engineer-reviewer detection scope expanded — Content Accuracy, List Consistency, Design Logic Review
- Stale Cross-References detection step coverage added to Step 7
- Verification mode disabled by default + context-pressure phase condition branching
- i18n Sprint key sections merged + en/ja other.yml duplicate sections normalized
- Hook scripts unified to `echo | jq` syntax

### Fixed

- Hook script jq extraction robustness — CWD fallback, pre-tool-bash-guard fallback, context-pressure.sh silent abort prevention
- Review quality improvements — Confidence Calibration sort order, E2E auto-create flow, recommendation-flow Source C consistency, multiple comment precision fixes

## [0.3.9] - 2026-04-03

### Added

- Reviewer foundation — `{agent_identity}` extraction, `_reviewer-base.md` shared principles, 4 core agents (security, code-quality, prompt-engineer, tech-writer) + confidence_threshold config
- Reviewer expansion — 7 remaining agents rebuilt + 2 new reviewers (error-handling, type-design)
- `schema_version` introduction + automatic upgrade mechanism for `rite-config.yml`

### Fixed

- Removed deprecated `commit.style` code examples from all documentation and project-type templates
- Updated config examples in documentation to `schema_version: 2` format
- Enforced sub-agent invocation in verification mode re-review
- Auto-create Issues from recommendation items marked as "separate Issue"
- Reset `error_count` to 0 on `flow-state-update.sh` patch mode to prevent stale circuit breaker

## [0.3.8] - 2026-04-01

### Added

- Fact-Checking Phase for PR review — verifies external specification claims against official documentation via WebSearch/WebFetch
- context7 MCP tool integration as optional verification method for fact-checking (`review.fact_check.use_context7`, default: off)

### Fixed

- Added `.rite-initialized-version` and `.rite-settings-hooks-cleaned` to `.gitignore`

## [0.3.7] - 2026-04-01

### Changed

- Reviewer findings now include WHY + EXAMPLE structure for more actionable fix guidance

## [0.3.6] - 2026-03-27

### Added

- Sprint Contract — per-step verification criteria for implementation phases
- Evaluator calibration — few-shot examples and skeptical tone for reviewers
- Post-Step Quality Gate — self-check after each implementation step
- Context reset strategy enhancement — stronger context management across phases

## [0.3.5] - 2026-03-27

### Added

- `/rite:investigate` skill — structured code investigation with Grep→Read→Cross-check 3-phase process
- `investigation-protocol.md` reference for lightweight code investigation across all workflow phases
- `investigate.codex_review.enabled` option in `rite-config.yml` to make Codex cross-check optional

### Fixed

- Migrated legacy hooks from `settings.local.json` to native `hooks.json` management

## [0.3.4] - 2026-03-20

### Changed

- Unified plugin path resolution to a version-independent method — `session-start.sh` now writes resolved path to `.rite-plugin-root`, command files read it via `cat`

## [0.3.3] - 2026-03-19

### Fixed

- Fixed SessionStart hook error when executing `/clear` in marketplace-installed environments

## [0.3.2] - 2026-03-17

### Fixed

- `/rite:init` now detects existing hooks in `settings.json` to prevent conflicts

### Changed

- Removed unused settings and added missing settings in `rite-config.yml`

### Docs

- Added AskUserQuestion enforcement and branch deletion steps to release skill

## [0.3.1] - 2026-03-17

### Fixed

- Verification mode now triggers full review instead of partial review
- Removed `{session_id}` placeholder and unified to auto-read pattern
- Strengthened sub-skill return interruption prevention in `create.md`
- Fixed Issue comment work memory backup sync
- Fixed bash redirection error when `.rite-session-id` is absent
- Fixed `session-start.sh` not resetting other sessions' active state on startup/clear
- Removed graduated relaxation logic from review-fix loop — all findings now require fix
- Made reviewer confirmation and Ready confirmation unskippable in e2e flow
- Used patch method for flow-state deactivation
- Fixed blocking/non-blocking remnants in review template output examples
- Fixed path resolution inconsistency with `--if-exists` pattern
- Added Defense-in-Depth flow-state updates to early-phase sub-skills

### Changed

- Abolished `loop_count`/`max_iterations`/`loop-limit` parameters
- Completely removed `--loop` parameter from `flow-state-update.sh`
- Added `hooks/hooks.json` native method with double-execution guard
- Added 3 quality rules to the review template
- Abolished trap in `session-start.sh` and improved debug logging

### Docs

- Updated review-fix loop documentation

## [0.3.0] - 2026-03-16

### Added

- Session ownership system for multi-session conflict prevention
  - Session ownership helper functions and flow-state overwrite protection
  - Session ownership support in `session-start.sh`
  - Session ownership support in `session-end.sh` and `stop-guard.sh`
  - Session ownership support in `wm-sync`, `pre-compact`, `context-pressure` hooks
  - `--session {session_id}` parameter added to all command files + `resume.md` ownership transfer

### Fixed

- Checklist auto-check processing added to `start.md`
- Branch existence check now uses output string instead of exit code
- Issue create output order improved — next steps moved to end
- PostToolUse hook auto-syncs Issue comment work memory on phase change
- `review.md` READ-ONLY constraint added to normalize review-fix loop
- Review → fix loop branch instructions rewritten to imperative conditional
- `session-end.sh` diagnostic log added for other session exit path
- Debug output remnants removed from hooks

### Changed

- Issue comment work memory update logic refactored to script for deterministic execution

### Docs

- Added `git branch --list` DO NOT warning to `gh-cli-commands.md`

## [0.2.5] - 2026-03-16

### Added

- Contextual Commits integration: structured action lines in commit body for decision persistence
  - Configuration and reference documentation (`commit.contextual` setting)
  - Action line generation in `implement.md` commit flow
  - Action line generation in `pr/fix.md` review-fix commit flow
  - `/rite:issue:recall` command for searching contextual commit history
  - Action line generation in `team-execute.md` parallel commit flow

### Fixed

- Edge case handling in `recall.md`: base branch fallback, grep metacharacter escaping, max-count consistency
- Added GitHub Projects integration and status transitions to release skill

## [0.2.4] - 2026-03-14

### Fixed

- Work memory implementation plan step states now batch-updated on commit
- Applied Defense-in-Depth pattern to create-decompose.md
- Unified legacy state name `blocked` to `recovering` in tests
- Added develop branch recovery procedure for auto-deletion after merge

### Changed

- Clarified Defense-in-Depth pattern ordering and removed redundancy
- Introduced PostCompact hook for automated auto-compact recovery

### Improved

- Enhanced prompt quality for create sub-skill

## [0.2.3] - 2026-03-13

### Fixed

- Reinforced auto-continuation after sub-skill return in create workflow

## [0.2.2] - 2026-03-12

### Added

- Marketplace hook path auto-update on version upgrade

### Fixed

- Parent Issue Projects status auto-update not executing

## [0.2.1] - 2026-03-12

### Added

- E2E flow context window overflow prevention mechanism
- Agent delegation Skill tool format in prompts
- Agent delegation AGENT_RESULT fallback handling

### Fixed

- Reinforced prompt to prevent Claude from stopping during sub-skill transitions
- Clarified work memory progress summary and changed files update logic
- Sub-skill transition instructions strengthened in create workflow
- Hardcoded bash hook paths replaced with `{plugin_root}` for marketplace compatibility
- Clarified resume counter restoration execution timing and ownership
- `context-pressure.sh` python3 startup optimization and COUNTER_VAL validation
- Ensured GitHub Projects registration when creating Issues via PR command
- Separated work memory progress summary and changed files update from checklist update
- `flow-state-update.sh` `--active` flag support in patch mode
- `flow-state-update.sh` `--` separator before jq filter in patch mode
- `fix.md` work memory trap integration for `$pr_body_tmp`
- Fixed work memory progress summary and changed files not updating during review/fix loop

### Changed

- Progress summary regex hardened for robustness
- Updated `lint.md` references and added concrete examples to `start.md`
- `resume.md` counter restoration snippet structured as formal subsection
- `review.md` session info update defense-in-depth intent documented

## [0.2.0] - 2026-03-05

### Added

- Plugin version check on session startup

### Changed

- Replaced Zen/禅 references with rite in SPEC and command docs

## [0.1.3] - 2026-03-05

### Changed

- Offloaded deterministic processing to shell scripts (`flow-state-update.sh`, `issue-body-safe-update.sh`), replacing 24 inline jq + atomic write patterns across 8 files
- Extracted completion report section from `start.md` into `completion-report.md`
- Extracted assessment rules from `review.md` into `references/assessment-rules.md`
- Extracted archive procedures from `cleanup.md` into `references/archive-procedures.md`
- Optimized SKILL.md description to active style and compressed table to pointer + summary format
- Added Why-driven rationale to MUST/CRITICAL directives across 7 major commands
- Added Input/Output Contract sections to 7 major commands

## [0.1.2] - 2026-03-04

### Fixed

- Fixed `work-memory-init` validation script missing else branch for success case
- Fixed work memory comment being overwritten by API error response
- Fixed unnecessary hooks unregistered message during rite workflow execution
- Fixed `stop-guard.sh` trap missing EXIT signal
- Fixed `stop-guard.sh` compact_state stop block failure
- Fixed `session-start.sh` jq error handling issues
- Fixed `/rite:issue:start` completion report not executing
- Fixed parent Issue Projects status not updating from Todo to In Progress
- Fixed `/rite:issue:start` Bash command errors
- Fixed find cleanup pattern to be mktemp suffix-length independent
- Fixed `ready.md` output pattern and defense-in-depth for Mandatory After
- Applied work memory update safety patterns consistently across all commands
- Fixed stop-guard and post-compact-guard deadlock race condition
- Fixed `/clear → /rite:resume` duplicate guidance message

### Changed

- Refactored `stop-guard.sh` grep -A20 hard-coded value to awk section extraction
- Refactored `pre-compact.sh` echo|jq pipe to here-string
- Refactored `stop-guard.sh` subshell optimization
- Unified PID-based temp file naming to mktemp with fallback

### Removed

- Removed rebrand mentions from v0.1.0 changelog entries

## [0.1.1] - 2026-03-03

### Fixed

- Fixed Implementation Contract format not applied when creating single Issue for large-scope tasks
- Fixed `/rite:issue:create` interruption after sub-skill return
- Fixed `/rite:issue:start` interruption during end-to-end flow
- Fixed work memory corruption on update with safety patterns and destruction prevention

## [0.1.0] - 2026-03-01

### Added

- Initial release of Rite Workflow
- Issue-driven development workflow for Claude Code
- Multi-reviewer PR review system with debate phase
- Sprint planning and team execution
- GitHub Projects integration
- Hook-based session management (stop-guard, pre-compact, session lifecycle)
- i18n support (Japanese, English)
- TDD Light mode
- Parallel implementation with git worktree support

[0.13.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.13.1...v0.13.2
[0.13.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.12.3...v0.13.0
[0.12.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.12.2...v0.12.3
[0.12.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.12.1...v0.12.2
[0.12.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.9.2...v0.10.0
[0.9.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.8.3...v0.9.0
[0.8.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.12...v0.7.0
[0.6.12]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.11...v0.6.12
[0.6.11]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.10...v0.6.11
[0.6.10]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.9...v0.6.10
[0.6.9]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.8...v0.6.9
[0.6.8]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.7...v0.6.8
[0.6.7]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.6...v0.6.7
[0.6.6]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.5...v0.6.0
[0.5.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.10...v0.4.0
[0.3.10]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.5...v0.3.0
[0.2.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
