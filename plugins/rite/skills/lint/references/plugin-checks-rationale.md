# Plugin-specific Checks — Rationale and Detection Details

Background (incident origin), detection patterns, and exclusion rules for each plugin-specific check executed by `lint/SKILL.md` Phase 3.5 (generic loop). The check table in Phase 3.5 is the SoT for **what runs and how** (script path, invocation args, result variables, count-extraction pattern); this file holds only the **why** and the per-check detection details that do not affect loop execution. Each script's header comment remains the SoT for its exact regex literals and algorithm.

## Bang-backtick check (bang-backtick-check.sh)

Static lint counterpart to the incident where inline-code bang adjacency (an exclamation mark placed immediately next to an inline-code span) broke Skill loading via bash history expansion. Scans `plugins/rite/skills/**/*.md`, `plugins/rite/agents/**/*.md`, and `plugins/rite/references/**/*.md` (plugin-scoped; the script walks the rite plugin tree specifically and does not scan repository-root `skills/` or similar directories that may belong to other plugins).

## Reviewer registry drift check (reviewer-registry-drift-check.sh)

Detects divergence across the 3 places that must stay in sync when a reviewer is added or removed: `plugins/rite/agents/*-reviewer.md` (profile files), and the `Available Reviewers` / `Reviewer Type Identifiers` tables in `plugins/rite/skills/reviewers/SKILL.md`. A half-registered reviewer either never spawns or spawns a nonexistent subagent. See CONTRIBUTING.md "Adding a New Reviewer" for the full edit procedure.

## Wiki growth check (wiki-growth-check.sh)

Detects "Phase X.X.W silently skipped" regressions. Warns (non-blocking) when the wiki branch has gone unchanged for `wiki.growth_check.threshold_prs` consecutive merged PRs on the development base branch — strong evidence that `skills/pr-review/SKILL.md` ステップ 6.5.W / `skills/fix/SKILL.md` ステップ 4.6.W / `skills/issue-close/SKILL.md` Phase 4.4.W are being skipped silently. See the script header for the detection contract and the 3-layer defense rationale.

## Gitignore health check (gitignore-health-check.sh)

Verifies `$state_root/.rite/.gitignore` (main checkout, not a linked worktree's show-toplevel) is the 3-line composition (star plus wiki negations) that setup and hooks generate. Lint never writes that file. `same_branch` additionally checks `git add --dry-run` on a wiki probe so ingest can stage raw sources.

## Backlink format check (backlink-format-check.sh)

Colon notation (file-path-colon-phase-number) is the canonical format for `Downstream reference:` backlink comments. Detects regressions to two legacy dialects (a space-separated dialect and a parenthetical DRIFT-CHECK ANCHOR dialect). See `.rite/wiki/pages/patterns/drift-check-anchor-semantic-name.md` for the canonical format specification.

## Hardcoded line-number check (hardcoded-line-number-check.sh)

Detects prose-level hardcoded line-number references in `plugins/rite/skills/**/*.md`. Complements the distributed fix drift check by catching three drift-prone patterns that the `(line N, M)`-only propagation scan missed:

- **P-A** parenthesized form `(line N)` / `(line N, M)`
- **P-B** Japanese prose form (qualifier `直前` / `直後` / `上記` / `下記` / `上方` / `下方` / `本セクション` near `line N`)
- **P-C** cross-file form `{file}.md:N` (single line, not range)

Exclusions: fenced code blocks, range form `:N-M`, backtick-quoted spans, self. Structural references are preferred over hardcoded line numbers because they self-document and survive content insertions/deletions.

## Comment journal narration (comment-journal-check.sh)

Detects high-confidence narrative comment violations (P1–P4 only) in `plugins/rite/**/*.{sh,md}`, repo-root `docs/**/*.md`, and `.rite/wiki/**/*.md`. Number-reference detection is owned by `number-reference-check.sh`, not this check.

This is the fast-fail mechanical layer below the LLM reviewers — patterns that are 100%-mechanically detectable get killed here so the reviewer queue stays focused on WHY > WHAT semantic judgments.

Detected patterns:

- **P1** `verified-review cycle N` — leftover narration referring to a verified-review iteration
- **P2** `旧実装(は|では)` — comments explaining what the previous version did (belongs in commit/PR history)
- **P3** `PR #N cycle N fix` — comments tagging a fix to a specific PR review cycle
- **P4** `cycle N F-N で(導入|確立|集約)` — comments referencing review-finding identifiers

Whitelist (line-level skip): `<!-- example:` / `# example:` / `// example:` markers, and **`TODO` / `FIXME` lines**.

Self-exclude: the script itself, `comment-best-practices.md` SoT, the parity test, and `comment-journal-check.test.sh`.

## Comment line-ref check (comment-line-ref-check.sh)

Detects hardcoded `<file>.<ext>:<NN>` references inside shell comments under `plugins/rite/**/*.sh`. Complements the hardcoded line-number check (which targets prose in markdown) by closing the same drift gap inside shell-script comments. Detected pattern (in shell comments only): `[A-Za-z][A-Za-z0-9_.-]*\.(sh|md|ts|py|js|tsx):[0-9]+`. Exclusions: shebang 「#!」, fenced code blocks, range form `:N-M`, backtick-quoted spans, whitelist markers (`# example:` / `<!-- example: -->` / `// example:`), self. Structural references (e.g., `lint.md Phase 3.5`) survive content insertions/deletions; raw `lint.md:742` references decay the moment a line is added above.

## Direct gh issue create check (check-no-direct-gh-issue-create.sh)

Detects Issue creation paths in `plugins/rite/skills/**/*.md` that bypass the `create-issue-with-projects.sh` helper. The original incident showed that scope-creep follow-up Issue creation invoked at orchestration time — specifically the canonical Issue creation paths in `skills/pr-review/SKILL.md` and `skills/fix/SKILL.md` — could regress to direct `gh issue create` shortcuts, leaving Issues unregistered in GitHub Projects.

Detected pattern (after stripping fenced code blocks / blockquotes / Markdown comments / inline backticks): `gh issue create [-$"\047]` — literal `gh issue create ` followed by `-` (option flag), `$` (shell variable), `"` (double-quoted argument), or `'` (single-quoted argument).

## Orphan reference check (orphan-reference-check.sh)

Detects reference files (`plugins/rite/{references,skills,agents}/**/*.md`) that exist but have zero inbound references AND no test pin protection. The motivation comes from a real incident where a 146-line callsites reference file was found to be a complete orphan — no other file referenced it, no test pinned its content, and it survived multiple workflow refactorings undetected. Orphan files are not actively harmful (they don't break workflow execution), but their accumulation degrades plugin maintainability over time.

Detection inputs: inbound references searched in `plugins/rite/`, `docs/`, `.github/` (excluding self-references); test pin searched in `plugins/rite/hooks/tests/` and `plugins/rite/scripts/tests/` (any `assert_grep` / `contains` containing the filename); well-known static assets skipped (`.gitkeep`, `__init__.py`, `LICENSE`, `CHANGELOG.md`). A file is flagged as **orphan** only when inbound count == 0 AND test pin count == 0.

## Shell-prose cross-ref check (sh-cross-ref-check.sh)

Detects `<file>.(md|sh) (ステップ|Phase) <number>` references inside echo strings and comments under `plugins/rite/**/*.sh` that are inconsistent with the referenced markdown file's actual headings. Complements the comment line-ref check (raw `<file>:<NN>` references), which covers `.sh` prose; `.md`-side cross-reference accuracy is left to reviewer judgment (see  Decision Log). A past review cycle surfaced `wiki-growth-check.sh` referencing a `close.md` step with the wrong keyword (`close.md` uses the `Phase` convention, but the prose said the in-scope `ステップ` convention) — a drift that escaped cycles 1-3 because they never scanned `.sh` prose.

Two independent checks per reference: **dangling number** (the referenced number is not present as a heading number in the target file) and **keyword mismatch** (the number exists, but the prose keyword `ステップ` / `Phase` conflicts with the target file's own convention, derived from its headings rather than a hardcoded path map). Exclusions: self, `plugins/rite/hooks/tests/` (fixtures), lines containing the `drift-check-ignore` marker, unresolvable file references, and targets with no numbered step/phase headings. Intentional or historical references can be exempted with an inline `drift-check-ignore` marker.

## Operational bash block heaviness check (bash-heaviness-check.sh)

Detects "heavy" bash blocks in skill markdown under `plugins/rite/skills/**/*.md` that violate the operational bash block heaviness convention in `skills/rite-workflow/references/coding-principles.md`. That convention's origin: large operational bash blocks (python inline / nested `$()` / multiple heredocs / long line counts) malformed Claude's tool-call parsing and silently ended the turn with no error. The convention was added as prose, but prose-only enforcement cannot stop new drift — this check surfaces it mechanically.

A block is flagged only when it exhibits **2 or more** of these signals (a single signal — e.g. a lone helper call passing one JSON heredoc, or one block writing a long template — is intentionally not flagged, keeping false positives low): **python-inline** (a line invokes python with inline code), **nested-cmdsub** (a line nests command substitution, e.g. `$(cmd "$(inner)")`), **multi-heredoc** (the block opens 2 or more heredocs), **long-block** (the block body is >= 25 lines). Heredoc bodies are treated as data: the python-inline / nested-cmdsub signals are evaluated only on real shell lines, so a template heredoc containing `$(...)` or `python3 -c` example text does not produce a finding. Exclusions: `plugins/rite/skills/**/tests/` fixtures, and any block containing the `drift-check-ignore` marker (exempts intentional / already-reviewed heavy blocks — refactoring an existing heavy block to a helper call is separate work, out of scope for the block's owning change).

## Projects board drift check (projects-board-drift-check.sh)

Detects the "CLOSED but board is not on a terminal Status" reconciliation gap. A `Done` transition is only wired into `/rite:cleanup` (ステップ8 → `skills/cleanup/references/archive-procedures.md` Phase 3.2) and `/rite:issue-close` (Shared: Projects Status → Done) — `Cancelled` is written by `/rite:issue-cancel` (Phase 5, on a deliberate NOT_PLANNED closure) and by this check's `--reconcile`, which is what picks up rows nobody cancelled through rite. GitHub auto-closes an Issue the moment a PR carrying `Closes #N` merges, and when `/rite:cleanup` is not run afterwards the board freezes at its last value (In Review for a ready Issue, Todo for an untouched one) with no reconciler picking it back up. The check scans recently-updated CLOSED Issues and reports those that are on the project board with a Status outside the terminal Status set defined in `references/projects-integration.md`, section "Terminal Status Set".

The closure reason decides the destination rather than being filtered on: the check reads `stateReason` and reconciles each drifted row to the terminal Status that reason maps to (`NOT_PLANNED` / `DUPLICATE` → `Cancelled` with no WARNING, `COMPLETED` → `Done` with no WARNING). This rules out two failure modes at once. An Issue deliberately parked at `Cancelled` is already terminal and is never reported as drift, so the reconciler cannot overwrite that decision with `Done`. And a reason outside the mapped three still lands on `Done` rather than being skipped, because a CLOSED Issue abandoned in a non-terminal column is the stall this check exists to clear — with a WARNING that names the value when there is one, and reports the absence when the API leaves `stateReason` unset.

The `Cancelled` destination is only reachable on a board that already has that option. `/rite:setup` provisions the five-option union including `Cancelled`; `fields.status.options` in `rite-config.yml` is read by no consumer. On a board that has not been re-run through setup since that provisioning existed, a `NOT_PLANNED` row fails the option-ID lookup in `projects-status-update.sh`, stays non-terminal, and is reported again on the next run — loudly, through that helper's normal failure path, rather than silently reconciled to the wrong terminal value. Issues that are not on the board remain outside the check entirely (there is no board Status to reconcile), which is what keeps `--reconcile` from quietly adding rows to the board.

## Number reference check (number-reference-check.sh)

Detects Issue/PR number tokens (`#NNN`, 3–4 digits) in persistent artifacts. Grammar and exclusion rules live only in the helper; callers must not copy the regex.

`--all` (generic loop, warning): git-tracked files minus helper path exclusions (`.rite/wiki/raw/**`, `plugins/rite/scripts/tests/fixtures/**`, and the 3 detector tests). CHANGELOG is in scope. Historical CHANGELOG hits are accepted as warning noise.

`--diff BASE` (lint Phase 3.5 preamble, blocking): added lines of `git diff BASE` (includes uncommitted). Origin-first base is the caller's job (`origin/{base_branch}` then `{base_branch}`). rc=1 findings and rc=2 (unreadable diff / usage) both increment `error_count` → `[lint:error]`.

Detected: a 3-4 digit `#NNN` at a word boundary (subsumes `Issue #NNN` / `PR #NNN`). Not matched: placeholder `#123`, markdown heading anchors (`#NNN-letter`), `drift-check-ignore` lines, 1-2 digit and 5+ digit tokens. Functional code (`{issue_number}`, `issue-[0-9]+`, `/issues/.../` API paths) has no literal `#NNN`.

## Sentinel contract check (sentinel-contract-check.sh)

Detects drift between the sentinel SoT (`plugins/rite/references/sentinel-contract.md` `## Sentinel 一覧` table) and the actual emitter/consumer skill files. Sentinels (bracketed literal strings such as `[review:mergeable]` / `[lint:success]` / `[fix:error]`) are the implicit string-matching contract sub-skills use to hand off control between each other; a rename in one file without the others causes silent orchestration breakage that only surfaces at runtime. The check reports (a) SoT-declared sentinels whose literal string is missing from their declared emitter or consumer skill file, and (b) sentinel-shaped literals found under `plugins/rite/skills/` (recursive `*.md`) or directly under `plugins/rite/hooks/` (`*.sh`, non-recursive — runtime hook helper scripts such as `review-comment-post.sh`) that are not declared in the SoT. See `plugins/rite/references/sentinel-contract.md` for the full sentinel list. CI runs this same script independently (`.github/workflows/sentinel-contract-check.yml`) as the always-on gate; `/rite:lint` surfaces it in the generic loop for local visibility.

## Tmp hardcode check (tmp-hardcode-check.sh)

Detects sandbox-incompatible patterns that regressed repeatedly across sweeps: `mktemp` with a `/tmp`-prefixed template (P1), fixed `/tmp` path hardcodes in assignments / redirects / `-file` options (P2), and `git push` with upstream tracking `-u` (P3). Under the Claude Code bash sandbox, writes are restricted to `$TMPDIR` while `/tmp` itself is read-only, and `.git/config` writes (which `-u` performs) are always denied by harness built-in protection. Each family caused a real failure: P1 broke stderr capture and wiki ingest paths, P2 killed `issue-comment-wm-sync.sh` update mode before PATCH under `set -euo pipefail`, and P3 left `wiki-branch-init.sh` stranded on an orphan wiki branch after an otherwise-successful push. The first sweep fixed only `.sh` files, leaving 40 identical patterns in skill markdown bash blocks — evidence that prose-only convention cannot stop this drift, hence the mechanical check.

The safe forms are structurally unmatched: `mktemp "${TMPDIR:-/tmp}/rite-...-XXXXXX"` never places the bare `/tmp/` directly after the mktemp token, the parameter-expansion path form contains none of the P2 literals, and `git stash push -u` (include-untracked stash) breaks the P3 token sequence with the interposed `stash` word. Exclusions: test harnesses (`*/tests/*` — they run outside the sandbox and are tracked separately), `references/gh-cli-error-catalog.md` (intentional error-illustration examples), and the check script itself (pattern definitions would self-match).

## Dollar-zero check (dollar-zero-check.sh)

Detects positional-parameter-zero references inside fenced code blocks in `plugins/rite/skills/**/*.md`. The Skill loader expands such references in a skill body to the **invocation argument string** before the body reaches the model, and the expansion does not stop at a fence boundary. A skill invoked as `/rite:cleanup 2044` therefore received an awk line-match condition rewritten to the literal `2044`, which matches nothing — so the YAML reader returned empty for every key, the caller's opt-out default absorbed the empty value, and a run that should have ingested 30 pending raw sources reported a normal skip with `auto_ingest=false`. Nothing else could catch it: the file on disk is correct, so grep and the shell test suite both pass, and the corruption exists only in the delivered body. Four YAML readers and three line-processing programs carried the pattern when the check was added.

The fix direction is structural rather than cosmetic — move the program into a real script under `hooks/scripts/` and call it from the skill body, because files executed by bash never pass through the loader. For `wiki:` section reads the canonical helper already exists (`hooks/scripts/lib/wiki-config.sh`, `parse_wiki_scalar`). The scan deliberately ignores the fence info string: the loader expands regardless of the declared language, so exempting non-`bash` fences would leave a silent hole for the next writer who picks a different tag. Scan scope: `plugins/rite/skills/**/*.md`. Prose outside every fence is not matched (explaining the parameter must stay possible — this paragraph does it), and `hooks/**/*.sh` falls outside the scope entirely rather than being filtered out of it (real scripts are immune, and scanning them would yield nothing but false positives).

A file whose fences do not balance is skipped with a WARNING rather than parsed on a guess, **and the run then exits 2** — an unscannable file is recorded as an error, never as a clean bill. This matters because rc is the only channel the caller reads: a rc=0 paired with a stderr WARNING would be shown as `success` in the row above and its output would not be surfaced at all. When the run also has findings the exit code is 1 (findings win the code) and the unscannable count is still printed.

## Tempfile lifecycle check (tempfile-lifecycle-check.sh)

Three tempfile defects kept returning to `hooks/` and `scripts/` because every new helper writes the surrounding boilerplate from scratch, and each writing is a fresh chance to get it wrong: a silenced `mktemp` failure degrading into an empty path, cleanup registered for EXIT only, and the registration written after the `mktemp` rather than before. Wiki pages and prose rules in `fix/SKILL.md` already existed when they recurred — prose does not reach the author at the moment they type `mktemp`.

The primary fix is not this check. `hooks/scripts/lib/tempfile.sh` takes over the whole tempfile lifecycle, so that sequence is no longer hand-written and cannot be written wrong. This check covers the one residue a lib cannot reach, because it is a way of writing a *path* rather than a way of calling a function.

`mktemp-derived-path`: mktemp's safety is that it creates a random name with `O_CREAT|O_EXCL`. A name derived from that result was never created that way and becomes predictable once the original is observed, so a symlink planted at the derived path is followed and its target truncated — measured end to end by a security reviewer on `dollar-zero-check.sh`. The fix is to take a second handle; the cost is negligible and the handler removes both.

Handles are tracked from `x=$(mktemp ...)`, from the lib form `rite_tempfile_new x` / `rite_tempdir_new x`, and from `x=$(bash .../_mktemp-stderr-guard.sh ...)` — that guard runs mktemp internally, so its output is a real handle. Tracking only the raw spelling would put the form that `coding-principles.md` mandates into the checker's blind spot, and omitting the guard would leave its eleven in-tree call sites there. One shape is deliberately *not* a derivation: unbraced `$tmp_suffix` is the variable `tmp_suffix`, because bash reads the whole `[A-Za-z0-9_]` run as one name, so treating it as a derivation fires on every sibling variable sharing a prefix. A carve-out for the dirname and basename expansions (`${tmp%/*}`, `${tmp##*/}`) was tried and removed: measured against this tree it suppressed no false positive at all, while it hid `"${tmp##*/}.log"` and `"${tmp%/*}/planted"` — component extraction with a suffix bolted on, which is a sibling path by any reading. A child path *inside* a `rite_tempdir_new` handle (`"$WORKDIR/scan.awk"`, the shape this checker itself uses) is likewise not a finding: the parent directory carries mktemp's 0700, so the child inherits the guarantee instead of losing it.

Out of contract by design: `x=$(mktemp 2>/dev/null) || x=""`. It resembles the silencing defect but is the sanctioned idiom for a non-blocking stderr-capture slot, at scale (100+ sites; the exact count moves with the tree, so measure rather than trust a number here). A warning there would be noise at a volume that gets the whole check ignored.

A file that could not be scanned is an error, not a clean bill — an unreadable target, a failed enumeration, or a failed awk run is counted and the run exits 2 (findings still win the exit code). Folding "did not look" into "found nothing" inside a checker reproduces, within the guard, the defect class the guard exists to catch; same contract as `dollar-zero-check.sh`.

Scan scope: `plugins/rite/hooks/**/*.sh` and `plugins/rite/scripts/**/*.sh`, excluding `tests/` (fixtures embed the pattern deliberately). Exclusion marker: `drift-check-ignore` on the finding line or the line directly above. The same marker name is used by `sh-cross-ref-check.sh` and `number-reference-check.sh` (same line only) and `bash-heaviness-check.sh` (anywhere in the block); the line-above form is specific to this checker. Backslash-continued lines are joined before scanning. Comments are skipped before a handle is registered, so a usage example in a docstring does not seed the registry.

## Pipefail grep-q check (pipefail-grep-q-check.sh)

Detects `grep -q` consuming a pipeline under `set -o pipefail`: once grep finds a match it exits early, and an upstream process still writing can receive SIGPIPE, turning a successful probe into a pipeline failure. This is a measured failure class—it dropped roughly one file per 200 runs from a parity sweep—so the check is non-blocking but visible in the generic lint loop.

The checker lexes shell quotes and comments before splitting raw pipe operators, joins backslash-continued and pipe-continued logical lines, tracks standalone and same-command-list `set -o pipefail` / combined-option activation and `set +o pipefail` deactivation, and reports the stage immediately before grep only while pipefail is active. Same-line subshell and command-substitution toggles affect that command list without leaking into later lines. Thus `printf ... | jq ... | grep -q` reports `jq`, while a pipe character inside a quoted printf format is not treated as syntax. Brace groups are kept intact rather than losing the producer at a control-operator boundary.

The exclusions are deliberately bounded proxies, not proofs of payload size: a literal-pipe printf fixture, direct `printf '%s'` status probes, `echo`, brace groups, `docker ps`, and `enable -p`. Repository-derived `printf '%s\n'` lists and intermediate `jq` or `head` stages remain findings. Do not extend these command-name proxies casually: an apparently small producer can become unbounded as its input changes. For a reviewed intentional case, use `drift-check-ignore` on the logical line or the line immediately above.

Scan scope is the full non-test shell surface under `plugins/rite/hooks/` and `plugins/rite/scripts/`. The known-site regression test pins both the total and the owning files without pinning volatile line numbers, so a parser or scope change cannot silently produce a clean bill.
