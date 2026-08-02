# AI Coding Principles Reference

A collection of principles to avoid common failure patterns in AI coding agents.
Structured for rite workflow based on Andrej Karpathy's "Issues with AI Coding".
The `knowledge_routing` principle additionally draws on t-wada's four quadrants of where knowledge lives: code = How, test code = What, commit log = Why, code comments = Why not.

> **前提**: 標準的な clean-code / エージェント規律（YAGNI、DRY、dead code の削除、仮定の表明と確認、矛盾検出時の停止、技術的懸念の表明、スコープ規律など）はモデルの既知として本ファイルでは再教育しない。詳細節を持つのは rite workflow 固有の運用（手順・helper・phase との接続、実測 incident 由来の規約）が絡む原則のみで、それ以外の原則は下記 Principle List の 1 行が全てであり、標準的な規律をそのまま適用する。

## Principle List

| Principle ID | Principle Name | Applicable Phase |
|-------------|---------------|-----------------|
| `assumption_surfacing` | Surface Assumptions | Phase 3, 5.1 |
| `confusion_management` | Manage Confusion/Contradictions | Phase 1, 3 |
| `push_back_when_warranted` | Push Back When Warranted | PR Review |
| `simplicity_enforcement` | Enforce Simplicity | Phase 5.1 |
| `scope_discipline` | Scope Discipline | Phase 5.1 |
| `dead_code_hygiene` | Dead Code Hygiene | Phase 5.1 |
| `inline_planning` | Present Plan Before Implementation | Phase 3 |
| `issue_accountability` | Accountability for Discovered Issues | All Phases |
| `no_unnecessary_fallback` | No Unnecessary Fallback | Phase 5.1, PR Review |
| `no_speculative_structure` | No Speculative Structure | Phase 5.1, PR Review |
| `reference_discovery` | Discover Reference Implementations | Phase 3 |
| `question_self_check` | Self-Check Before Asking | All Phases |
| `documentation_consistency` | Sync Documentation with Specification Changes | Phase 5.1 |
| `knowledge_routing` | Route Knowledge to Its Durable Medium | Phase 5.1, PR Review |

## Principle Details

### inline_planning (Present Plan Before Implementation)

**Summary**: Present plan (target files / steps / AC mapping) before implementing and get confirmation.

**Rules**:
1. State plan explicitly and list target files before implementing
2. The canonical plan template is defined in [`skills/open/SKILL.md`](../../../skills/open/SKILL.md) ステップ 3.3 (実装計画生成) — do not duplicate it here

### issue_accountability (Accountability for Discovered Issues)

**Summary**: Always address discovered issues; never dismiss as "out of scope".

**Rules**:
1. Always take some action on discovered problems — "not my change" / "existing problem" is not a valid reason to ignore
2. If outside the current Issue scope, **always create a separate Issue** to track it (add to Projects with appropriate labels)
3. Applies to all phases: lint/test errors, review comments, pre-PR checks

### no_unnecessary_fallback (No Unnecessary Fallback)

**Summary**: Don't add fallbacks that hide failure causes. Distinguish "expected absence" from "unexpected failure".

**Rules**:
1. **"Expected absence"** (config not set, optional feature disabled) → Fallback is OK, but always with a visible warning
2. **"Unexpected failure"** (API error, file not found when it should exist) → Error, not fallback
3. **Visibility criterion**: Can the user see what happened and why? If the fallback hides the cause, it's unnecessary
4. Prefer failing loudly over degrading silently — no silent multi-level fallback chains where scope changes at each level

**Judgment guide**:

| Situation | Correct Response | Reason |
|-----------|-----------------|--------|
| Config value not set | Fallback with warning | Expected absence — user chose not to set it |
| API call fails | Error | Unexpected failure — something is wrong |
| File not found (should exist) | Error | Unexpected failure — indicates a bug or misconfiguration |
| Optional feature unavailable | Skip with notice | Expected absence — feature is optional |
| Network error during branch detection | Error | Unexpected failure — don't guess the branch name |

> **Operating-environment declaration**: Each project declares its operating environment (single-user development machine / shared host / multi-tenant, etc.) as prose in its own `CLAUDE.md` — not as a config key, and not in the Wiki, which reviewers do not read — because the reviewer-side [Finding Quality Guardrail](../../../agents/_reviewer-base.md#finding-quality-guardrail) Category #2 judges whether a defensive / hardening finding is reachable at all against that declaration.

### no_speculative_structure (No Speculative Structure)

**Summary**: Do not build for a future that has no Issue. Structure added "for later" — extension points, reserved fields, unused config keys, single-caller abstractions — is dead weight that still has to be read, reviewed, documented, and eventually removed.

**Rules**:
1. Add structure only when a real Issue requires it now. The anticipated future rarely arrives; when it does, handle it then — paying that cost later is cheaper than carrying an unused mechanism until then.
2. Applies to specification text as much as to code: reserved sentinels, placeholder branches, unused marker fields, and "for future use" notes in skill / reference / template files.
3. The legitimate trigger is the current Issue's Acceptance Criteria, or a consumer that lands in the same PR. "It might be needed" / "it keeps the design symmetric" is not a trigger.
4. When a plan or a review finding proposes speculative structure, drop it rather than adding a smaller version of it — see the "Simplification-First Response Principle" section in [`skills/fix/SKILL.md`](../../../skills/fix/SKILL.md).

### reference_discovery (Discover Reference Implementations)

**Summary**: Discover existing reference implementations in the same directory/pattern as change targets.

**Rules**:
1. Before implementing, search for files in the same directory / same naming pattern (`*-handler.ts` 等) / test-implementation pairs
2. Record discovered references in the implementation plan and follow their structure and conventions
3. When none found, state `参考実装: なし（新規ディレクトリまたは初めてのファイルパターン）` and follow project-wide conventions

### question_self_check (Self-Check Before Asking)

**Summary**: Self-check whether the question is truly necessary before asking.

**Details**: See the `question_self_check` section in [common-principles.md](./common-principles.md).

### documentation_consistency (Sync Documentation with Specification Changes)

**Summary**: When an implementation changes user-visible specification (commands, config keys, file paths, public API, workflow phases, hook names, etc.), update related documentation in the same PR. Detect drift before commit, not at PR review time.

**Rules**:
1. Before committing, identify user-facing identifiers introduced/changed/removed by the diff and search the entire repository (`*.md`, `README*`, `CLAUDE.md`, `docs/`, `plugins/rite/**/*.md`) for them
2. Update stale documentation in the **same branch** — never defer to a separate Issue, never ask permission via `AskUserQuestion`
3. Skip when the diff is internals-only, documentation-only, or test-only
4. Runs as the dedicated `5.1.0.7 Documentation Impact Investigation` step before commit; complements (does not replace) the tech-writer reviewer

### knowledge_routing (Route Knowledge to Its Durable Medium)

**Summary**: Every implementation produces four kinds of knowledge, and each has one medium where it survives. The medium's properties — lifespan, visibility, verifiability — decide the routing. Knowledge placed in the wrong medium rots, goes unread, or becomes a lie. For an LLM agent whose session memory vanishes, these four channels are the only persistent memory, so routing them correctly is a first-class discipline. Each channel's detailed rules live in its own SoT; this principle only routes.

**Four Channels**:

| Knowledge | Medium | Why this medium |
|-----------|--------|-----------------|
| How (current behavior) | The code itself (naming, structure) | Code is executed, so it is always true — it cannot drift from the running reality |
| What (specification, behavior) | Test code (test name + assertion) | Tests are executable specification — the name states What, the assertion proves it |
| Why (motive at change time) | Commit message body | The commit is the immutable record of the context at the moment of change |
| Why not (rejected alternative) — and the Why that must stay beside the code (hidden constraint, invariant, workaround) | Code comments | The comment is the only document that stays in the same place as the code it guards |

**Routing flowchart** (when unsure where to record a finding):
- Current behavior of the code → let the code say it (naming, structure)
- Specification or behavior → a test, with the test name written as a specification sentence
- Motive / choice / rejected alternative → if a future reader would be tempted to rewrite the code back to the naive shape, a comment (Why not); otherwise the commit message
- Hidden constraint / invariant / workaround → a comment (Why)

**Rules**:
1. Route each kind of knowledge to its one channel; do not record the same knowledge in two channels.
2. Defer each channel's detailed rules to its SoT — do not duplicate them here: comments → [comment-best-practices.md](./comment-best-practices.md), tests → [test-reviewer.md](../../../agents/test-reviewer.md). For commits, record the "why" in the commit message body (free-form prose).
3. Transport misplaced knowledge to its correct medium rather than leaving it: change history found in a comment → move it to the commit; How found in a comment → promote it to naming and delete the comment.

---

## Markdown Authoring Conventions

> **Note**: このセクションは Markdown 記述規約であり、上記の `## Principle List` テーブルに登録されているコード規約 (AI Coding Principles) とは別軸のため、独立セクションとして配置している。`## Related` からも参照される。

These conventions apply to authoring Markdown files loaded by the Claude Code Skill loader. Certain inline-code patterns may interact with the loader's bash interpretation path and cause prose to be executed as shell commands.

**Applicable file paths** (Skill loader 経路にある全カテゴリ):

- `plugins/rite/skills/**/*.md`
- `plugins/rite/agents/**/*.md`
- `plugins/rite/references/**/*.md`
- `plugins/rite/templates/**/*.md`

### bash negation operator inline code convention

**Summary**: When referencing the bash negation operator in Markdown inline code, never let a bare bang character (U+0021) sit immediately before the closing backtick of an inline code span. Always include a command, argument, or ellipsis token after the bang.

**Failure pattern** (observed incident): The file `skills/fix/SKILL.md` once contained 5 occurrences of bang-backtick adjacency (a bang character placed directly next to the closing backtick of an inline code span, with no intervening whitespace or token). The Skill loader mis-executed surrounding documentation text as shell commands at runtime — a silent failure that was only caught through careful diffing. Replacing each occurrence with the trailing-token form (`if ! cmd` / `if ! ...`) resolved the failure.

> **Note on mechanism**: The exact trigger (bash history expansion vs. the Skill loader's internal quoting/parsing processing) is **not fully characterized**. Empirically, bang-backtick adjacency is known to trigger failures in some files and contexts but long-standing occurrences exist in other files (e.g., `plugins/rite/references/gh-cli-patterns.md`) without reported Skill-load failures. See the `gh-cli-patterns.md` "Shell Escaping Notes" section for related unresolved areas. Treat this rule as a **defensive convention grounded in the observed incident above**, not as a statement of a fully understood mechanism.

**NG / OK examples** (the NG example is inside a fenced `text` block per Rule 3 below so it does not itself violate the convention):

```text
NG pattern (demonstration — do not write this in prose):
 backtick + bang + closing backtick (bang-backtick adjacency, no trailing token)

OK patterns:
 `if ! cmd`
 `if ! ...`
 `if ! command -v foo`
```

**Rules**:
1. Do not write bang-backtick adjacency in Markdown prose (outside fenced code blocks) in any file loaded by the Skill loader.
2. Always include a trailing token: use `if ! cmd` (specific command) or `if ! ...` (ellipsis placeholder) instead.
3. When the NG pattern must itself be quoted for documentation, enclose it in a fenced code block tagged `text`. Fenced blocks are not subject to inline-code parsing by the loader.

**Application scope** (silent retroactive sweep 回避): 本 convention は**新規編集時に目視で発見したもののみ**を対象とする。既存ファイルへの retroactive 一括書き換えは行わない — 長期間存在する既存箇所で Skill ロード失敗が観測されておらず、真のトリガ条件が未だ empirically 特定されていないため、一括書き換えは不要な変更を広範に生むリスクがある。真のトリガ条件の dry-run 実証調査は別 Issue で追跡する。

### operational bash block heaviness convention

**Summary**: command / reference 本文の operational bash ブロックは軽量に保つ — **1 ブロック 1 目的・<= 25 行を目安**とし、python inline (`python3 -c`)・入れ子 `$()`・複数 heredoc を 1 ブロックに密集させない。tmpfile や中間変数を process 境界を跨いで渡す必要がある場合は、1 本の Bash invocation に詰め込まず `hooks/` または `scripts/` の helper script へ切り出す。

**Failure pattern** (observed incident): 過去に複数のコマンド本文 (`pr/ready.md` / `pr/fix.md` / `pr/pr-review.md` 等) が 40〜360 行規模の operational bash ブロックを抱えており、各々「⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること」と注記した上で `python3 -c` heredoc・多引数 `jq -n`・入れ子 `$()`・`trap` + `mktemp` を密集させていた。Claude のツール呼び出し解析がこの巨大ブロックで malform し、**エラーすら出さず無言でターンが終了（停止）する**事象が `/rite:ready` 実行中および scout 1 行で計 3 回以上観測された。ブロックを phase ごとに分割する／重いロジックを helper script へ切り出して本文を数行の呼び出しにする、のいずれかで停止は解消した。

**Rules**:
1. 1 ブロック = 1 目的。operational bash ブロックは <= 25 行を目安とする。
2. command 本文 bash に `python3 -c` heredoc を埋め込まない。テキスト変換は helper (`*.py` を `*.sh` wrapper 経由で呼ぶ) に移す — 先例: `issue-comment-wm-update.py` / `issue-comment-wm-sync.sh`。
3. 入れ子 `$()` (`$(cmd "$(jq -n ...)")` 等) を避ける。pipe (`jq -n ... | cmd`) もしくは stdin / tmpfile を読む helper を優先する。
4. 1 ブロック内の複数 heredoc を避ける。file body が必要なら Write tool で tmpfile に書き出し、helper には `--content-file <tmp>` / `--body-file <tmp>` で渡す。
5. 値を process 境界を跨いで渡す必要があるときは helper へ切り出す (work-memory / state 系は `hooks/`、issue / projects 系は `scripts/`)。その際**既存のワークフロー契約 (sentinel emit / non-blocking / trap cleanup) を verbatim で引き継ぐ**こと。
6. `gh {pr,issue} create` の `--title` に長文 / 特殊文字（全角記号・`≠`・括弧・コロン等）の literal を**インライン展開しない**。title を **Write tool** でファイル化して bash で変数に読み込む（`pr_title=$(cat title.txt)` → `--title "$pr_title"`）か、helper の `--arg title` 経由で渡す。`gh` に `--title-file` は無い（body の `--body-file` と非対称）ため「変数経由」が canonical。先例: `skills/pr-create/SKILL.md` の pr_title.txt 変数経由パターン / `skills/issue-create/SKILL.md` の decompose path（`gh {pr,issue} create` のインライン特殊文字 title が malformed tool-call の dominant trigger だった）。

**Precedents**: `projects-status-update.sh` / `local-wm-update.sh` / `issue-body-safe-update.sh` / `issue-comment-wm-sync.sh` / `create-issue-with-projects.sh` — 重い操作を positional-JSON または stdin 入力 + tmpfile body file で helper に委譲済の前例。

**Where to Apply**:
- `plugins/rite/skills/**/*.md` の operational bash ブロックを新規記述 / 編集するとき。

**Mechanical enforcement**: 上記 Rules は `/rite:lint` Phase 3.5 (`hooks/scripts/bash-heaviness-check.sh`) が `plugins/rite/skills/**/*.md` を走査して非ブロッキング warning として機械的に surface する (`[lint:success]` は不変)。各 bash ブロックを 4 つの heaviness シグナル (+ standalone 検出 `inline-gh-create-title`) で評価し、これは Rules と対応する:

| シグナル | 判定 | 対応 Rule |
|---------|------|----------|
| `python-inline` | `python3 -c` / python heredoc を含む | Rule 2 |
| `nested-cmdsub` | 入れ子 `$( … $( … )`（同一行） | Rule 3 |
| `multi-heredoc` | heredoc が 2 つ以上 | Rule 4 |
| `long-block` | ブロック本文が >= 25 行 | Rule 1 |
| `inline-gh-create-title` | `gh {pr,issue} create` 行に literal な `--title "…"` を inline（`--title "$var"` は対象外） | Rule 6 |

**2 シグナル以上**該当したブロックのみ flag する (single signal — 単発の helper 呼び出し + 1 個の JSON heredoc、または 1 個の長文テンプレート heredoc — は誤検知を避けるため flag しない)。heredoc 本文はデータ扱いで python-inline / nested-cmdsub の評価対象外。意図的・レビュー済の重いブロックは行内 `drift-check-ignore` marker で除外できる。既存の重いブロックの helper 切り出しは段階的 cleanup であり、本 guard は awareness のための warning に留める。

**例外: `inline-gh-create-title` は単独でも flag する**。これは複数シグナルの密集（heaviness）ではなく、単一行でも malform を誘発する高確度の独立パターンのため、2-signal モデルとは別に扱う。example / template の title は plain ` ``` ` fence（` ```bash ` 以外は走査対象外）や heredoc 本文（データ扱い）に置くことで誤検知を避ける。`drift-check-ignore` marker による除外は他シグナルと同様に効く。

---

## Phase Checklists

各 phase の完了前に、該当する原則を自己チェックする（詳細節を持たない原則は標準規律としてチェックする）:

| Phase | Checklist (principle IDs) |
|-------|---------------------------|
| All Phases (Common) | `issue_accountability` / `question_self_check` |
| Phase 3 (Implementation Plan) | `assumption_surfacing` / `confusion_management` / `inline_planning` / `reference_discovery` |
| Phase 5.1 (Implementation) | `simplicity_enforcement` / `scope_discipline` / `dead_code_hygiene` / `no_unnecessary_fallback` / `no_speculative_structure` / `issue_accountability` / `documentation_consistency` / `knowledge_routing` |
| PR Review | `push_back_when_warranted` / `simplicity_enforcement` / `scope_discipline` / `no_unnecessary_fallback` / `no_speculative_structure` / `issue_accountability` / `knowledge_routing` |
| Before PR Creation | `issue_accountability`（未対応の問題・レビュー指摘がないか / スコープ外の問題が別 Issue として追跡されているか） |

**Reference**: The `/rite:pr-create` Phase 2.5 ([create.md](../../../skills/pr-create/SKILL.md), "2.5 Unaddressed Issues Check" section) implements the unaddressed issues check.

---

## Related

- [SKILL.md](../SKILL.md) - Principle summary
- [Phase Mapping](./phase-mapping.md) - Phase details
- [PR Create Command](../../../skills/pr-create/SKILL.md) - Unaddressed issues check before PR creation (Phase 2.5)
- [Markdown Authoring Conventions](#markdown-authoring-conventions) - Skill loader に load される Markdown ファイルの記述規約 (bash negation operator inline code convention / operational bash block heaviness convention)
- [gh-cli-patterns.md](../../../references/gh-cli-patterns.md) - Related bang character (U+0021) handling in bash command contexts (Shell Escaping Notes)
- [graphql-helpers.md](../../../references/graphql-helpers.md) - Related bang character handling in GraphQL query / jq contexts (History Expansion and Special Character Prevention)
- [gh-cli-error-catalog.md](../../../references/gh-cli-error-catalog.md) - Related bang character handling error catalog (Category 6)
