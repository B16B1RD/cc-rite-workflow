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

> P5/P6（説明的番号参照）の検出設計の根拠・除外の実測値は `../../wiki-lint/references/descriptive-refs-rationale.md` が SoT。本節は P5/P6 の**検出定義**（キーワード語彙・whitelist・self-exclude 判断）を扱う。

Detects high-confidence narrative comment violations **and descriptive Issue/PR number references** in `plugins/rite/**/*.{sh,md}`, repo-root `docs/**/*.md`, and `.rite/wiki/**/*.md` (ドキュメント散文・Wiki ページまでスコープ拡張 — SoT [適用スコープ](../../rite-workflow/references/comment-best-practices.md#適用スコープ) の永続成果物全般).

> **`.rite/wiki/**` に届く条件**: Wiki ページ (`pages/` / `index.md`) の実体がワークツリーにあるのは `wiki.branch_strategy: same_branch` のときだけで、`separate_branch` では wiki ブランチにあり本チェックの走査範囲外になる（ページ分の走査は `/rite:wiki-lint` ステップ 7.5 が `git show` で担う。責務分割であり未実装ではない）。ただし `separate_branch` でも ingest 待ちの Raw Source が `.rite/wiki/raw/` に一時的に実在する窓では raw 由来の検出が出うる。7.5 は `log.md` / `raw/**` / `SCHEMA.md` を意図的に除外するため、両検出器の対象集合は一致しない（`same_branch` では本チェックが `log.md` の番号参照も報告する。7.5 が意図的除外としたものが本チェックでは warning として出る非対称で、非ブロッキングのため merge は止まらない）。

This is the fast-fail mechanical layer below the LLM reviewers — patterns that are 100%-mechanically detectable get killed here so the reviewer queue stays focused on WHY > WHAT semantic judgments.

Detected patterns:

- **P1** `verified-review cycle N` — leftover narration referring to a verified-review iteration
- **P2** `旧実装(は|では)` — comments explaining what the previous version did (belongs in commit/PR history)
- **P3** `PR #N cycle N fix` — comments tagging a fix to a specific PR review cycle
- **P4** `cycle N F-N で(導入|確立|集約)` — comments referencing review-finding identifiers
- **P5** descriptive Issue/PR ref — 参照キーワード (`Issue` / `PR` / `Refs` / `See` / `Related to` / `Closes` / `Fixes` / `Resolves`、大小文字対称) が番号の直前に来る形。裸の `PR #N は…` / `Issue #N` / 小文字の `issue #N` も含む。左側に `(^|[^A-Za-z])` の境界を置き `prefs #12` / `hrefs #3` の語尾一致を弾く。キーワード列は語彙であって表層形の列挙ではなく、括弧付き `(refs #N)` も `see PR #N` も同じ 1 規則に畳まれる
- **P6** descriptive Issue/PR ref (ja) `#N で(別途)対応` / `詳細は #N` — 参照キーワードを持たないため P5 へ畳めない日本語 2 構文

キーワードを伴わない裸の `#N` は意図的に検出しない (正当な文脈が多すぎて機械的に切り分けられず、対応するには除外を過大に広げる必要が生じるため)。番号一致は `([^0-9]|$)` で語境界を取る — gawk は `\b` をバックスペースとして読むため、`\b` を使うと検出器が無言で沈黙する。

Whitelist (line-level skip): `<!-- example:` / `# example:` / `// example:` markers, and **`TODO` / `FIXME` lines** (追跡番号は前方ポインタ=維持). ファイル名アンカー (`xxx.test.sh` 等) は `#N` を含まないため P5/P6 に該当せず自然に除外される.

P5/P6 のみに効く追加除外 (P1-P4 の検出結果は不変): コードフェンス / インラインコードスパン (逐語引用の中の番号は主張ではなく literal。スパンは削除ではなく `_` へ置換する — 削除するとキーワードと後続番号が隣接して偽の一致を作るため) / `## ソース` **節** (Wiki ページの provenance リンクラベルは出所の監査証跡として維持対象)。ソース節の除外は見出しから次の `##` 見出しの手前までで、ファイル末尾までではない — wiki-ingest が `## ソース` の後ろに `## 補強:` 等の本文節を追記するため、EOF まで打ち切ると後続本文が丸ごと盲点になる (現行の接尾辞許容見出しに対して実測 7 ページ / 28 hits。接尾辞を許容する前の計測では 13 ページ / 81 hits)。判定はフェンス状態の更新後に行い、フェンス内に引用された `## ソース` では発火しない。見出しは `## ソース（追記分）` / `## ソース（追記分 N）` 等の接尾辞を許容する（wiki-ingest の LLM 生成形、実測 13 箇所。厳密一致にすると節の開始として認識されないまま「次の見出し」としては認識され、直前の節の除外を打ち切って実測 53 hits の誤検出になる）。いずれの除外もその範囲内では再発が見えなくなるため、P1-P4 には広げず説明的参照の検出に限定している。

P6 は P5 より先に走らせ、報告した ja 接尾構文 (`#N で対応`) を P5 の走査行からマスクする。「PR #N で別途対応」は両規則に当たるため、順序を決めないと同一位置で 2 件に膨らむ。

Self-exclude: the script itself, `comment-best-practices.md` SoT, the parity test, and 検出器自身の test 2 本 (`comment-journal-check.test.sh` / `wiki-lint-descriptive-refs.test.sh`) — いずれも禁止句を例示 (test では fixture) として保持するため。

**`docs/SPEC.md` は self-exclude しない**: 裸形への拡張により同ファイルの provenance 注記 (`Issue #2024` 等) が 8 件検出されるようになったが、これらは SoT の廃止判定ルール上ほんとうに説明的参照であり、「禁止句を定義・例示するファイル」という self-exclude の根拠には当たらない。除外を「検出されると煩わしいファイル」へ広げると、その範囲内で既知アンチパターンの再発が見えなくなる (本節の P5/P6 除外方針と同じ理由)。progressive cleanup の対象として warning に残す。

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

## Tempfile lifecycle check (tempfile-lifecycle-check.sh)

Three tempfile defects kept returning to `hooks/` and `scripts/` because every new helper writes the surrounding boilerplate from scratch, and each writing is a fresh chance to get it wrong: a silenced `mktemp` failure degrading into an empty path, cleanup registered for EXIT only, and the registration written after the `mktemp` rather than before. Wiki pages and prose rules in `fix/SKILL.md` already existed when they recurred — prose does not reach the author at the moment they type `mktemp`.

The primary fix is not this check. `hooks/scripts/lib/tempfile.sh` takes over the whole tempfile lifecycle, so that sequence is no longer hand-written and cannot be written wrong. This check covers the one residue a lib cannot reach, because it is a way of writing a *path* rather than a way of calling a function.

`mktemp-derived-path`: mktemp's safety is that it creates a random name with `O_CREAT|O_EXCL`. A name derived from that result was never created that way and becomes predictable once the original is observed, so a symlink planted at the derived path is followed and its target truncated — measured end to end by a security reviewer on `dollar-zero-check.sh`. The fix is to take a second handle; the cost is negligible and the handler removes both.

Handles are tracked from `x=$(mktemp ...)` and from the lib form `rite_tempfile_new x` / `rite_tempdir_new x` — tracking only the raw spelling would put the form that `coding-principles.md` mandates into the checker's blind spot. One shape is deliberately *not* a derivation: unbraced `$tmp_suffix` is the variable `tmp_suffix`, because bash reads the whole `[A-Za-z0-9_]` run as one name, so treating it as a derivation fires on every sibling variable sharing a prefix. A carve-out for the dirname and basename expansions (`${tmp%/*}`, `${tmp##*/}`) was tried and removed: measured against this tree it suppressed no false positive at all, while it hid `"${tmp##*/}.log"` and `"${tmp%/*}/planted"` — component extraction with a suffix bolted on, which is a sibling path by any reading. A child path *inside* a `rite_tempdir_new` handle (`"$WORKDIR/scan.awk"`, the shape this checker itself uses) is likewise not a finding: the parent directory carries mktemp's 0700, so the child inherits the guarantee instead of losing it.

Out of contract by design: `x=$(mktemp 2>/dev/null) || x=""`. It resembles the silencing defect but is the sanctioned idiom for a non-blocking stderr-capture slot, at scale (100+ sites; the exact count moves with the tree, so measure rather than trust a number here). A warning there would be noise at a volume that gets the whole check ignored.

A file that could not be scanned is an error, not a clean bill — an unreadable target, a failed enumeration, or a failed awk run is counted and the run exits 2 (findings still win the exit code). Folding "did not look" into "found nothing" inside a checker reproduces, within the guard, the defect class the guard exists to catch; same contract as `dollar-zero-check.sh`.

Scan scope: `plugins/rite/hooks/**/*.sh` and `plugins/rite/scripts/**/*.sh`, excluding `tests/` (fixtures embed the pattern deliberately). Exclusion marker: `drift-check-ignore` on the finding line or the line directly above. The same marker name is used by `sh-cross-ref-check.sh` and `number-reference-check.sh` (same line only) and `bash-heaviness-check.sh` (anywhere in the block); the line-above form is specific to this checker. Backslash-continued lines are joined before scanning. Comments are skipped before a handle is registered, so a usage example in a docstring does not seed the registry.

**A second pattern was attempted and withdrawn.** Detecting `grep -q` consuming a pipeline under `set -o pipefail` — the SIGPIPE class that dropped one file per ~200 runs from a parity sweep — turned out to need a shell parser to be accurate. Command-name-based exemption is a proxy for payload size and misses `printf` payloads that scale with repository content; splitting on `|` without tracking quotes misreads a pipe inside an argument as a stage boundary; and control-operator splitting without tracking `{ }` loses the producer entirely. Each tightening produced a new false-positive class. The pattern is tracked separately with the measured data rather than shipped at a precision that would train readers to ignore the checker.
