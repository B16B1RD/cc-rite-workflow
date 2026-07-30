# Plugin-specific Checks — Rationale and Detection Details

Background (incident origin), detection patterns, and exclusion rules for each plugin-specific check executed by `lint/SKILL.md` Phase 3.5 (generic loop). The check table in Phase 3.5 is the SoT for **what runs and how** (script path, invocation args, result variables, count-extraction pattern); this file holds only the **why** and the per-check detection details that do not affect loop execution. Each script's header comment remains the SoT for its exact regex literals and algorithm.

## Bang-backtick check (bang-backtick-check.sh)

Static lint counterpart to the incident where inline-code bang adjacency (an exclamation mark placed immediately next to an inline-code span) broke Skill loading via bash history expansion. Scans `plugins/rite/skills/**/*.md`, `plugins/rite/agents/**/*.md`, and `plugins/rite/references/**/*.md` (plugin-scoped; the script walks the rite plugin tree specifically and does not scan repository-root `skills/` or similar directories that may belong to other plugins).

## Reviewer registry drift check (reviewer-registry-drift-check.sh)

Detects divergence across the 3 places that must stay in sync when a reviewer is added or removed: `plugins/rite/agents/*-reviewer.md` (profile files), and the `Available Reviewers` / `Reviewer Type Identifiers` tables in `plugins/rite/skills/reviewers/SKILL.md`. A half-registered reviewer either never spawns or spawns a nonexistent subagent. See CONTRIBUTING.md "Adding a New Reviewer" for the full edit procedure.

## Wiki growth check (wiki-growth-check.sh)

Detects "Phase X.X.W silently skipped" regressions. Warns (non-blocking) when the wiki branch has gone unchanged for `wiki.growth_check.threshold_prs` consecutive merged PRs on the development base branch — strong evidence that `skills/pr-review/SKILL.md` ステップ 6.5.W / `skills/fix/SKILL.md` ステップ 4.6.W / `skills/issue-close/SKILL.md` Phase 4.4.W are being skipped silently. See the script header for the detection contract and the 3-layer defense rationale.

## Gitignore health check (gitignore-health-check.sh)

Detects regressions of the `.rite/wiki/` exclusion rule added as the last line of defense against wiki-ingest-trigger.sh silent leaks on the develop branch. If a future `.gitignore` cleanup PR removes the rule, this check surfaces the drift before the leak reaches production. Strategy-aware detection: `separate_branch` uses `git check-ignore`; `same_branch` uses `git add --dry-run` because negation rules make `git check-ignore` non-deterministic per `.gitignore` spec.

## Backlink format check (backlink-format-check.sh)

Colon notation (file-path-colon-phase-number) is the canonical format for `Downstream reference:` backlink comments. Detects regressions to two legacy dialects (a space-separated dialect and a parenthetical DRIFT-CHECK ANCHOR dialect). See `.rite/wiki/pages/patterns/drift-check-anchor-semantic-name.md` for the canonical format specification.

## Hardcoded line-number check (hardcoded-line-number-check.sh)

Detects prose-level hardcoded line-number references in `plugins/rite/skills/**/*.md`. Complements the distributed fix drift check by catching three drift-prone patterns that the `(line N, M)`-only propagation scan missed:

- **P-A** parenthesized form `(line N)` / `(line N, M)`
- **P-B** Japanese prose form (qualifier `直前` / `直後` / `上記` / `下記` / `上方` / `下方` / `本セクション` near `line N`)
- **P-C** cross-file form `{file}.md:N` (single line, not range)

Exclusions: fenced code blocks, range form `:N-M`, backtick-quoted spans, self. Structural references are preferred over hardcoded line numbers because they self-document and survive content insertions/deletions.

## Comment journal narration (comment-journal-check.sh)

Detects high-confidence narrative comment violations **and descriptive Issue/PR number references** in `plugins/rite/**/*.{sh,md}`, repo-root `docs/**/*.md`, and `.rite/wiki/**/*.md` (ドキュメント散文・Wiki ページまでスコープ拡張 — SoT [適用スコープ](../../rite-workflow/references/comment-best-practices.md#適用スコープ) の永続成果物全般). This is the fast-fail mechanical layer below the LLM reviewers — patterns that are 100%-mechanically detectable get killed here so the reviewer queue stays focused on WHY > WHAT semantic judgments.

Detected patterns:

- **P1** `verified-review cycle N` — leftover narration referring to a verified-review iteration
- **P2** `旧実装(は|では)` — comments explaining what the previous version did (belongs in commit/PR history)
- **P3** `PR #N cycle N fix` — comments tagging a fix to a specific PR review cycle
- **P4** `cycle N F-N で(導入|確立|集約)` — comments referencing review-finding identifiers
- **P5** descriptive Issue/PR ref — 参照キーワード (`Issue` / `PR` / `Refs` / `See` / `Related to` / `Closes` / `Fixes` / `Resolves`) が番号の直前に来る形。裸の `PR #N は…` / `Issue #N` も含む。キーワード列は語彙であって表層形の列挙ではなく、括弧付き `(refs #N)` も `see PR #N` も同じ 1 規則に畳まれる
- **P6** descriptive Issue/PR ref (ja) `#N で(別途)対応` / `詳細は #N` — 参照キーワードを持たないため P5 へ畳めない日本語 2 構文

キーワードを伴わない裸の `#N` は意図的に検出しない (正当な文脈が多すぎて機械的に切り分けられず、対応するには除外を過大に広げる必要が生じるため)。番号一致は `([^0-9]|$)` で語境界を取る — gawk は `\b` をバックスペースとして読むため、`\b` を使うと検出器が無言で沈黙する。

Whitelist (line-level skip): `<!-- example:` / `# example:` / `// example:` markers, and **`TODO` / `FIXME` lines** (追跡番号は前方ポインタ=維持). ファイル名アンカー (`xxx.test.sh` 等) は `#N` を含まないため P5/P6 に該当せず自然に除外される.

P5/P6 のみに効く追加除外 (P1-P4 の検出結果は不変): コードフェンス / インラインコードスパン (逐語引用の中の番号は主張ではなく literal。スパンは削除ではなく `_` へ置換する — 削除するとキーワードと後続番号が隣接して偽の一致を作るため) / `## ソース` 節 (Wiki ページの provenance リンクラベルは出所の監査証跡として維持対象)。いずれの除外もその範囲内では再発が見えなくなるため、P1-P4 には広げず説明的参照の検出に限定している。

Self-exclude: the script itself, `comment-best-practices.md` SoT, the parity test, and 検出器自身の test 2 本 (`comment-journal-check.test.sh` / `wiki-lint-descriptive-refs.test.sh`) — いずれも禁止句を例示 (test では fixture) として保持するため。

## Comment line-ref check (comment-line-ref-check.sh)

Detects hardcoded `<file>.<ext>:<NN>` references inside shell comments under `plugins/rite/**/*.sh`. Complements the hardcoded line-number check (which targets prose in markdown) by closing the same drift gap inside shell-script comments. Detected pattern (in shell comments only): `[A-Za-z][A-Za-z0-9_.-]*\.(sh|md|ts|py|js|tsx):[0-9]+`. Exclusions: shebang 「#!」, fenced code blocks, range form `:N-M`, backtick-quoted spans, whitelist markers (`# example:` / `<!-- example: -->` / `// example:`), self. Structural references (e.g., `lint.md Phase 3.5`) survive content insertions/deletions; raw `lint.md:742` references decay the moment a line is added above.

## Direct gh issue create check (check-no-direct-gh-issue-create.sh)

Detects Issue creation paths in `plugins/rite/skills/**/*.md` that bypass the `create-issue-with-projects.sh` helper. The original incident showed that scope-creep follow-up Issue creation invoked at orchestration time — specifically the canonical Issue creation paths in `skills/pr-review/SKILL.md` and `skills/fix/SKILL.md` — could regress to direct `gh issue create` shortcuts, leaving Issues unregistered in GitHub Projects.

Detected pattern (after stripping fenced code blocks / blockquotes / Markdown comments / inline backticks): `gh issue create [-$"\047]` — literal `gh issue create ` followed by `-` (option flag), `$` (shell variable), `"` (double-quoted argument), or `'` (single-quoted argument).

## Orphan reference check (orphan-reference-check.sh)

Detects reference files (`plugins/rite/{references,skills,agents}/**/*.md`) that exist but have zero inbound references AND no test pin protection. The motivation comes from a real incident where a 146-line callsites reference file was found to be a complete orphan — no other file referenced it, no test pinned its content, and it survived multiple workflow refactorings undetected. Orphan files are not actively harmful (they don't break workflow execution), but their accumulation degrades plugin maintainability over time.

Detection inputs: inbound references searched in `plugins/rite/`, `docs/`, `.github/` (excluding self-references); test pin searched in `plugins/rite/hooks/tests/` and `plugins/rite/scripts/tests/` (any `assert_grep` / `contains` containing the filename); well-known static assets skipped (`.gitkeep`, `__init__.py`, `LICENSE`, `CHANGELOG.md`). A file is flagged as **orphan** only when inbound count == 0 AND test pin count == 0.

## Shell-prose cross-ref check (sh-cross-ref-check.sh)

Detects `<file>.(md|sh) (ステップ|Phase) <number>` references inside echo strings and comments under `plugins/rite/**/*.sh` that are inconsistent with the referenced markdown file's actual headings. Complements the comment line-ref check (raw `<file>:<NN>` references), which covers `.sh` prose; `.md`-side cross-reference accuracy is left to reviewer judgment (see Issue #1881 Decision Log). A past review cycle surfaced `wiki-growth-check.sh` referencing a `close.md` step with the wrong keyword (`close.md` uses the `Phase` convention, but the prose said the in-scope `ステップ` convention) — a drift that escaped cycles 1-3 because they never scanned `.sh` prose.

Two independent checks per reference: **dangling number** (the referenced number is not present as a heading number in the target file) and **keyword mismatch** (the number exists, but the prose keyword `ステップ` / `Phase` conflicts with the target file's own convention, derived from its headings rather than a hardcoded path map). Exclusions: self, `plugins/rite/hooks/tests/` (fixtures), lines containing the `drift-check-ignore` marker, unresolvable file references, and targets with no numbered step/phase headings. Intentional or historical references can be exempted with an inline `drift-check-ignore` marker.

## Operational bash block heaviness check (bash-heaviness-check.sh)

Detects "heavy" bash blocks in skill markdown under `plugins/rite/skills/**/*.md` that violate the operational bash block heaviness convention in `skills/rite-workflow/references/coding-principles.md`. That convention's origin: large operational bash blocks (python inline / nested `$()` / multiple heredocs / long line counts) malformed Claude's tool-call parsing and silently ended the turn with no error. The convention was added as prose, but prose-only enforcement cannot stop new drift — this check surfaces it mechanically.

A block is flagged only when it exhibits **2 or more** of these signals (a single signal — e.g. a lone helper call passing one JSON heredoc, or one block writing a long template — is intentionally not flagged, keeping false positives low): **python-inline** (a line invokes python with inline code), **nested-cmdsub** (a line nests command substitution, e.g. `$(cmd "$(inner)")`), **multi-heredoc** (the block opens 2 or more heredocs), **long-block** (the block body is >= 25 lines). Heredoc bodies are treated as data: the python-inline / nested-cmdsub signals are evaluated only on real shell lines, so a template heredoc containing `$(...)` or `python3 -c` example text does not produce a finding. Exclusions: `plugins/rite/skills/**/tests/` fixtures, and any block containing the `drift-check-ignore` marker (exempts intentional / already-reviewed heavy blocks — refactoring an existing heavy block to a helper call is separate work, out of scope for the block's owning change).

## Projects board drift check (projects-board-drift-check.sh)

Detects the "CLOSED+COMPLETED but board != Done" reconciliation gap. A `Done` transition is only wired into `/rite:cleanup` (ステップ8 → `skills/cleanup/references/archive-procedures.md` Phase 3.2) and `/rite:issue-close` (Shared: Projects Status → Done), but GitHub auto-closes an Issue the moment a PR carrying `Closes #N` merges. When `/rite:cleanup` is not run afterwards, the board freezes at its last value (In Review for a ready Issue, Todo for an untouched one) and no reconciler picks it back up. The check scans recently-updated CLOSED Issues whose `stateReason` is `COMPLETED` and reports those that are on the project board with Status != "Done". Closure reason `NOT_PLANNED` (wontfix / duplicate) is intentionally excluded, and Issues that are not on the board are not drift (no board Status to reconcile).

## Number reference check (number-reference-check.sh)

Detects Issue/PR number references (`#NNN`, `Issue #NNN`, `PR #NNN`) that have crept back into the number-free documentation surface — `CHANGELOG.md`, `CHANGELOG.ja.md`, and `plugins/rite/skills/lint/SKILL.md`. Project policy is to drop descriptive Issue/PR numbers and state the rationale directly as prose; release notes habitually re-add the merging PR (`(#NNNN)`) and command docs accrete `Issue #NNN` provenance over time, so a static check surfaces recurrence at lint time rather than at the next manual audit.

The detected token is a 3-4 digit `#NNN` at a word boundary, which subsumes the `Issue #NNN` / `PR #NNN` prose forms. Not matched (structural — no allowlist needed): functional code (`{issue_number}` placeholder, `issue-[0-9]+` branch-name extraction, `/issues/.../` API paths — none contain a literal `#NNN`) and markdown step/phase headings (`## 3.19`, where `#` is followed by `#` or a space, never a digit). 1-2 digit refs and 5+ digit tokens are outside the matched band. Exclusions: self, `plugins/rite/hooks/tests/` (fixtures intentionally embed bad refs), and lines containing the `drift-check-ignore` marker.

**Staged rollout**: the `--all` surface is the number-free guarantee of this work — CHANGELOG (en/ja) and `lint.md`. The wider comment/doc cleanup is owned by sibling work; as those paths are cleaned, append them to `DEFAULT_TARGETS` in the script. CHANGELOG entries describe each change at the feature level and stand without the merging PR number.

## Sentinel contract check (sentinel-contract-check.sh)

Detects drift between the sentinel SoT (`plugins/rite/references/sentinel-contract.md` `## Sentinel 一覧` table) and the actual emitter/consumer skill files. Sentinels (bracketed literal strings such as `[review:mergeable]` / `[lint:success]` / `[fix:error]`) are the implicit string-matching contract sub-skills use to hand off control between each other; a rename in one file without the others causes silent orchestration breakage that only surfaces at runtime. The check reports (a) SoT-declared sentinels whose literal string is missing from their declared emitter or consumer skill file, and (b) sentinel-shaped literals found under `plugins/rite/skills/` (recursive `*.md`) or directly under `plugins/rite/hooks/` (`*.sh`, non-recursive — runtime hook helper scripts such as `review-comment-post.sh`) that are not declared in the SoT. See `plugins/rite/references/sentinel-contract.md` for the full sentinel list. CI runs this same script independently (`.github/workflows/sentinel-contract-check.yml`) as the always-on gate; `/rite:lint` surfaces it in the generic loop for local visibility.

## Tmp hardcode check (tmp-hardcode-check.sh)

Detects sandbox-incompatible patterns that regressed repeatedly across sweeps: `mktemp` with a `/tmp`-prefixed template (P1), fixed `/tmp` path hardcodes in assignments / redirects / `-file` options (P2), and `git push` with upstream tracking `-u` (P3). Under the Claude Code bash sandbox, writes are restricted to `$TMPDIR` while `/tmp` itself is read-only, and `.git/config` writes (which `-u` performs) are always denied by harness built-in protection. Each family caused a real failure: P1 broke stderr capture and wiki ingest paths, P2 killed `issue-comment-wm-sync.sh` update mode before PATCH under `set -euo pipefail`, and P3 left `wiki-branch-init.sh` stranded on an orphan wiki branch after an otherwise-successful push. The first sweep fixed only `.sh` files, leaving 40 identical patterns in skill markdown bash blocks — evidence that prose-only convention cannot stop this drift, hence the mechanical check.

The safe forms are structurally unmatched: `mktemp "${TMPDIR:-/tmp}/rite-...-XXXXXX"` never places the bare `/tmp/` directly after the mktemp token, the parameter-expansion path form contains none of the P2 literals, and `git stash push -u` (include-untracked stash) breaks the P3 token sequence with the interposed `stash` word. Exclusions: test harnesses (`*/tests/*` — they run outside the sandbox and are tracked separately), `references/gh-cli-error-catalog.md` (intentional error-illustration examples), and the check script itself (pattern definitions would self-match).

## Dollar-zero check (dollar-zero-check.sh)

Detects positional-parameter-zero references inside fenced code blocks in `plugins/rite/skills/**/*.md`. The Skill loader expands such references in a skill body to the **invocation argument string** before the body reaches the model, and the expansion does not stop at a fence boundary. A skill invoked as `/rite:cleanup 2044` therefore received an awk line-match condition rewritten to the literal `2044`, which matches nothing — so the YAML reader returned empty for every key, the caller's opt-out default absorbed the empty value, and a run that should have ingested 30 pending raw sources reported a normal skip with `auto_ingest=false`. Nothing else could catch it: the file on disk is correct, so grep and the shell test suite both pass, and the corruption exists only in the delivered body. Four YAML readers and three line-processing programs carried the pattern when the check was added.

The fix direction is structural rather than cosmetic — move the program into a real script under `hooks/scripts/` and call it from the skill body, because files executed by bash never pass through the loader. For `wiki:` section reads the canonical helper already exists (`hooks/scripts/lib/wiki-config.sh`, `parse_wiki_scalar`). The scan deliberately ignores the fence info string: the loader expands regardless of the declared language, so exempting non-`bash` fences would leave a silent hole for the next writer who picks a different tag. Scan scope: `plugins/rite/skills/**/*.md`. Prose outside every fence is not matched (explaining the parameter must stay possible — this paragraph does it), and `hooks/**/*.sh` falls outside the scope entirely rather than being filtered out of it (real scripts are immune, and scanning them would yield nothing but false positives).

A file whose fences do not balance is skipped with a WARNING rather than parsed on a guess, **and the run then exits 2** — an unscannable file is recorded as an error, never as a clean bill. This matters because rc is the only channel the caller reads: a rc=0 paired with a stderr WARNING would be shown as `success` in the row above and its output would not be surfaced at all. When the run also has findings the exit code is 1 (findings win the code) and the unscannable count is still printed.
