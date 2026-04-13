# AI Coding Principles Reference

A collection of principles to avoid common failure patterns in AI coding agents.
Structured for rite workflow based on Andrej Karpathy's "Issues with AI Coding".

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
| `reference_discovery` | Discover Reference Implementations | Phase 3 |
| `question_self_check` | Self-Check Before Asking | All Phases |
| `documentation_consistency` | Sync Documentation with Specification Changes | Phase 5.1 |

---

## Principle Details

### assumption_surfacing (Surface Assumptions)

**Summary**: Surface assumptions explicitly and confirm before proceeding.

**Failure Patterns**:
- Implementing ambiguous requirements based on own interpretation
- Guessing user intent and going off track
- Proceeding with "probably this" assumptions

**Rules**:
1. When requirements are ambiguous, state interpretation explicitly before implementing
2. When multiple interpretations are possible, present the options
3. Confirm important design decisions in advance

**Where to Apply**:
- Phase 3 (Implementation Plan): State assumptions when creating plans
- Phase 5.1 (Implementation): Record decisions made during implementation

**Example**:
```text
この Issue の「認証機能の追加」について、以下の解釈で進めます:
- 方式: JWT トークン認証
- スコープ: API エンドポイントのみ
- 既存機能への影響: 認証ミドルウェアを追加

この解釈で進めてよいですか？
```

---

### confusion_management (Manage Confusion/Contradictions)

**Summary**: Stop and confirm when contradictions or unknowns are detected.

**Failure Patterns**:
- Implementing contradictory instructions by choosing one side
- Ignoring unknowns and proceeding with guesses
- Swallowing errors and continuing

**Rules**:
1. Report contradictions immediately upon detection
2. Do not proceed with implementation until resolved
3. Clarify ambiguities before moving forward

**Where to Apply**:
- Phase 1 (Issue Quality Check): Stop when contradictions are detected
- Phase 3 (Implementation Plan): Identify unknowns

**Example**:
```text
Issue の内容に矛盾があります:
- 「パフォーマンスを最優先」と記載
- 一方で「すべてのエラーを詳細ログ出力」も要求

これらは相反する可能性があります。どちらを優先しますか？
```

---

### push_back_when_warranted (Push Back When Warranted)

**Summary**: Push back when problems are found.

**Failure Patterns**:
- Following obviously problematic designs without objection
- Not pointing out security risks
- Silently accepting technical debt

**Rules**:
1. Always point out security risks
2. Suggest alternatives for anti-patterns
3. Clearly communicate technical concerns

**Where to Apply**:
- PR Review: Flagging problematic implementations

**Example**:
```text
この実装にはセキュリティ上の懸念があります:
- SQL クエリに直接ユーザー入力を使用（SQLインジェクションリスク）

代替案: プリペアドステートメントを使用
```

---

### simplicity_enforcement (Enforce Simplicity)

**Summary**: Avoid excessive complexity.

**Failure Patterns**:
- Adding unnecessary abstraction layers
- Creating unused extension points
- Over-applying design patterns

**Rules**:
1. YAGNI (You Aren't Gonna Need It) principle
2. Question more than 3 levels of indirection
3. Avoid "for the future" implementations

**Where to Apply**:
- Phase 5.1 (Implementation): Simplicity check during coding

**Checklist**:
- [ ] Is this abstraction needed right now?
- [ ] Is this design pattern excessive?
- [ ] Is there a simpler solution?

---

### scope_discipline (Scope Discipline)

**Summary**: Only change what was requested.

**Failure Patterns**:
- Opportunistic refactoring
- "Improving" unrelated files
- Adding features outside scope

**Rules**:
1. Only change what is described in the Issue
2. Propose out-of-scope improvements as separate Issues
3. Resist the temptation of "while I'm at it"

**Where to Apply**:
- Phase 5.1 (Implementation): Restricting change scope

**Example**:
```text
実装中に以下の改善点を発見しました:
- utils.ts の関数名が不適切

これは今回のスコープ外のため、別 Issue として登録しますか？
```

---

### dead_code_hygiene (Dead Code Hygiene)

**Summary**: Identify dead code explicitly and confirm removal.

**Failure Patterns**:
- Leaving unused code
- Commenting out code as "insurance"
- Keeping meaningless backward-compatibility code

**Rules**:
1. Report unused code as removal candidates
2. Delete rather than comment out
3. Confirm before deletion

**Where to Apply**:
- Phase 5.1 (Implementation): Check for dead code after refactoring

**Example**:
```text
リファクタリング後、以下のコードが未使用になりました:
- `oldHandler()` 関数
- `legacyConfig` 変数

これらを削除してよいですか？
```

---

### inline_planning (Present Plan Before Implementation)

**Summary**: Present plan before implementing and get confirmation.

**Failure Patterns**:
- Starting implementation without a plan
- Implementing parts without seeing the whole picture
- Frequent rework due to lack of planning

**Rules**:
1. State plan explicitly before implementing
2. List target files in advance
3. Get approval before starting implementation

**Where to Apply**:
- Phase 3 (Implementation Plan): Present implementation plan upfront

**Example**:
```text
## 実装計画

### 変更対象ファイル
| ファイル | 変更内容 |
|---------|---------|
| src/auth.ts | 認証ロジックの追加 |
| src/middleware.ts | 認証ミドルウェアの追加 |

### 実装ステップ（依存グラフ）

| Step | 内容 | depends_on | 並列グループ |
|------|------|------------|-------------|
| S1 | 認証ロジックの実装 | — | A |
| S2 | ミドルウェアの統合 | S1 | B |
| S3 | テストの追加 | S1, S2 | C |

この計画で進めますか？
```

**Note**: For the full plan template including the "参考実装" section, see [implementation-plan.md](../../../commands/issue/implementation-plan.md) Phase 3.3.

---

### issue_accountability (Accountability for Discovered Issues)

**Summary**: Always address discovered issues; never dismiss as "out of scope".

**Failure Patterns**:
- Ignoring issues as "not my change"
- Skipping action as "existing problem"
- Dismissing problems as "out of scope"
- Completing without addressing items as "outside current scope"

**Rules**:
1. Always take some action on discovered problems/issues
2. "Not my change" or "existing problem" is not a valid reason to ignore
3. If outside the current Issue scope, **always create a separate Issue** to track it
4. When creating separate Issues, add to Projects with appropriate labels

**Where to Apply**:
- All phases: Immediate action when problems are discovered
- lint/test execution: Create Issues for out-of-scope errors
- PR Review: Genuine response to review comments
- Before PR creation: Check for unaddressed issues

**Example**:
```text
lint で以下の警告を検出しました:
- src/utils.ts:42 - 未使用の変数 'oldConfig'

この警告は今回の変更範囲外ですが、発見した問題には対応が必要です。

対応:
- 別 Issue #XXX を作成しました
- ラベル: lint, tech-debt
- Status: Todo
```

**Prohibited judgments**:
```text
❌ 「これは私の変更とは関係ない既存の問題です」
❌ 「このディレクトリは今回の修正対象外です」
❌ 「このエラーは無視して進めます」
```

**Correct responses**:
```text
✅ 「範囲外の問題を検出しました。別 Issue として登録します」
✅ 「既存のエラーですが、Issue #XXX として追跡します」
✅ 「対象外の警告を Issue 化しました: #YYY」
```

---

### no_unnecessary_fallback (No Unnecessary Fallback)

**Summary**: Don't add fallbacks that hide failure causes. Distinguish "expected absence" from "unexpected failure".

**Failure Patterns**:
- Silent fallback to a default value when the operation should have succeeded
- Multi-level fallback chains where scope silently changes at each level
- catch-all that swallows errors and continues as if nothing happened
- Fallback that makes bugs "go away" instead of surfacing them

**Rules**:
1. **"Expected absence"** (config not set, optional feature disabled) → Fallback is OK, but always with a visible warning
2. **"Unexpected failure"** (API error, file not found when it should exist) → Error, not fallback
3. **Visibility criterion**: Can the user see what happened and why? If the fallback hides the cause, it's unnecessary
4. Prefer failing loudly over degrading silently — bugs caught early are cheaper to fix

**Where to Apply**:
- Phase 5.1 (Implementation): Check for unnecessary fallbacks in new code
- PR Review: Flag fallback chains that hide root causes

**Example**:
```text
❌ Bad: Silent multi-level fallback
git symbolic-ref ... || git remote show origin ... || echo "main"
→ Silently falls to "main", hiding the real problem (misconfigured remote)

✅ Good: Explicit error with guidance
git symbolic-ref ... || {
  echo "エラー: デフォルトブランチを検出できません"
  echo "rite-config.yml で branch.base を設定してください"
  exit 1
}

❌ Bad: Scope silently changes
git diff origin/develop...HEAD || git diff HEAD || lint entire project
→ User thinks they're linting changed files, but actually linting everything

✅ Good: Fail and explain
git diff origin/develop...HEAD || git diff develop...HEAD || {
  echo "エラー: 変更ファイルを特定できません"
  echo "明示的にパスを指定してください: /rite:lint <path>"
  exit 1
}
```

**Judgment guide**:

| Situation | Correct Response | Reason |
|-----------|-----------------|--------|
| Config value not set | Fallback with warning | Expected absence — user chose not to set it |
| API call fails | Error | Unexpected failure — something is wrong |
| File not found (should exist) | Error | Unexpected failure — indicates a bug or misconfiguration |
| Optional feature unavailable | Skip with notice | Expected absence — feature is optional |
| Network error during branch detection | Error | Unexpected failure — don't guess the branch name |

---

### reference_discovery (Discover Reference Implementations)

**Summary**: Discover existing reference implementations in the same directory/pattern as change targets.

**Failure Patterns**:
- Implementing without checking existing conventions in the same directory
- Creating inconsistent coding styles across similar files
- Ignoring established patterns in neighbor files

**Rules**:
1. Before implementing, search for files in the same directory with the same extension
2. Identify naming patterns (e.g., `*-handler.ts` → other `*-handler.ts` files)
3. Check for corresponding test/implementation file pairs
4. Record discovered references in the implementation plan
5. Follow the structure and conventions of reference files during implementation

**Where to Apply**:
- Phase 3 (Implementation Plan): Discover references during plan generation

**Discovery Methods**:

| Method | Pattern | Example |
|--------|---------|---------|
| Same directory | Same extension files in target directory | `commands/issue/*.md` |
| Name pattern | Files matching `*-{suffix}.{ext}` | `*-handler.ts`, `*-service.ts` |
| Test correspondence | Test file ↔ implementation file | `foo.ts` ↔ `foo.test.ts` |

**Example**:
```text
## 参考実装

| 参考ファイル | 参考理由 |
|-------------|---------|
| commands/issue/create.md | 同ディレクトリの既存コマンド定義 |
| commands/issue/edit.md | 類似の Issue 操作コマンド |

### 参考にすべきパターン
- Phase 番号のフォーマット: `### 3.1`, `### 3.2` 形式
- フロントマター: `description` フィールドは日本語
- セクション構成: Module reference → Steps → Notes
```

**When No References Found**:
```text
参考実装: なし（新規ディレクトリまたは初めてのファイルパターン）
→ プロジェクト全体の慣習に従ってください
```

---

### documentation_consistency (Sync Documentation with Specification Changes)

**Summary**: When an implementation changes user-visible specification (commands, config keys, file paths, public API, workflow phases, hook names, etc.), update related documentation in the same PR. Detect drift before commit, not at PR review time.

**Failure Patterns**:
- Renaming a command or config key in code without updating README / docs / CLAUDE.md
- Adding a new workflow phase to `commands/issue/start.md` without updating the corresponding skill / reference docs
- Removing a feature from code while marketing copy in README still describes it
- Deferring documentation drift to a separate "follow-up" Issue that never gets done
- Relying on the tech-writer reviewer at PR review time to catch drift, causing avoidable review round-trips

**Rules**:
1. Before committing, identify user-facing identifiers introduced/changed/removed by the diff
2. Search the entire repository (`*.md`, `README*`, `CLAUDE.md`, `docs/`, `plugins/rite/**/*.md`) for those identifiers
3. Update stale documentation in the **same branch** as the implementation — never defer
4. Do **not** ask the user for permission via `AskUserQuestion`; documentation sync is mandatory when drift is detected
5. Do **not** create a separate Issue for the drift (this contradicts the same-PR rule and `issue_accountability` for in-scope work)
6. Skip when the diff is internals-only, documentation-only, or test-only

**Where to Apply**:
- Phase 5.1 (Implementation): Run as the dedicated `5.1.0.7 Documentation Impact Investigation` step before `5.1.1` commit
- This complements (does not replace) the tech-writer reviewer at PR review time

**Example**:

```text
実装で /rite:issue:resume コマンドを /rite:resume にリネームした

ドキュメント影響調査:
- Grep "/rite:issue:resume" → README.md L142, docs/getting-started.md L88, plugins/rite/commands/init.md L23
- 全 3 ファイルを Edit ツールで /rite:resume に更新
- 同じブランチでステージし、実装と同じコミットに含める
```

**Anti-pattern**:

```text
❌ 「ドキュメント追従は別 Issue として後で対応します」
❌ 「README の記述が古いですが、レビュアーが指摘してくれるはずです」
❌ AskUserQuestion: 「README を更新しますか？」
```

---

### question_self_check (Self-Check Before Asking)

**Summary**: Self-check whether the question is truly necessary before asking.

**Details**: See the `question_self_check` section in [common-principles.md](./common-principles.md).

**Where to Apply**:
- All phases: Before asking any question or requesting confirmation

---

## Markdown Authoring Conventions

> **Note**: このセクションは Markdown 記述規約であり、上記の `## Principle List` テーブルに登録されているコード規約 (AI Coding Principles) とは別軸のため、独立セクションとして配置している。`## Related` からも参照される。

These conventions apply to authoring Markdown files loaded by the Claude Code Skill loader. Certain inline-code patterns may interact with the loader's bash interpretation path and cause prose to be executed as shell commands.

**Applicable file paths** (Skill loader 経路にある全カテゴリ):

- `plugins/rite/skills/**/*.md`
- `plugins/rite/commands/**/*.md`
- `plugins/rite/agents/**/*.md`
- `plugins/rite/references/**/*.md`
- `plugins/rite/templates/**/*.md`

### bash negation operator inline code convention

**Summary**: When referencing the bash negation operator in Markdown inline code, never let a bare bang character (U+0021) sit immediately before the closing backtick of an inline code span. Always include a command, argument, or ellipsis token after the bang.

**Failure pattern** (observed incident): In Issue #365, the file `commands/pr/fix.md` contained 5 occurrences of bang-backtick adjacency (a bang character placed directly next to the closing backtick of an inline code span, with no intervening whitespace or token). The Skill loader mis-executed surrounding documentation text as shell commands at runtime — a silent failure that was only caught through careful diffing. Replacing each occurrence with the trailing-token form (`if ! cmd` / `if ! ...`) resolved the failure.

> **Note on mechanism**: The exact trigger (bash history expansion vs. the Skill loader's internal quoting/parsing processing) is **not fully characterized**. Empirically, bang-backtick adjacency is known to trigger failures in some files and contexts but long-standing occurrences exist in other files (e.g., `plugins/rite/references/gh-cli-patterns.md`) without reported Skill-load failures. See the `gh-cli-patterns.md` "Shell Escaping Notes" section for related unresolved areas. Treat this rule as a **defensive convention grounded in the Issue #365 incident**, not as a statement of a fully understood mechanism.

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

---

## Phase Checklists

### All Phases (Common)

- [ ] `issue_accountability`: Are any discovered problems being ignored?
- [ ] `question_self_check`: Did you self-check before asking? (Is the answer already in the request? Is it obvious?)

### Phase 3 (Implementation Plan)

- [ ] `assumption_surfacing`: Are assumptions stated explicitly?
- [ ] `confusion_management`: Are there contradictions or unknowns?
- [ ] `inline_planning`: Is the plan presented?
- [ ] `reference_discovery`: Are reference implementations identified?

### Phase 5.1 (Implementation)

- [ ] `simplicity_enforcement`: Is there excessive complexity?
- [ ] `scope_discipline`: Are there out-of-scope changes?
- [ ] `dead_code_hygiene`: Is dead code being left behind?
- [ ] `no_unnecessary_fallback`: Are there fallbacks that hide failure causes?
- [ ] `issue_accountability`: Are any discovered problems being ignored?
- [ ] `documentation_consistency`: Has related documentation been updated for any user-visible spec changes?

### PR Review

- [ ] `push_back_when_warranted`: Are problems being flagged?
- [ ] `simplicity_enforcement`: Is there excessive complexity?
- [ ] `scope_discipline`: Are there out-of-scope changes?
- [ ] `no_unnecessary_fallback`: Are there fallbacks that hide failure causes?
- [ ] `issue_accountability`: Are review comments being addressed genuinely?

### Before PR Creation

- [ ] `issue_accountability`: Are there unaddressed problems or review comments?
- [ ] `issue_accountability`: Are out-of-scope problems tracked as separate Issues?

**Reference**: The `/rite:pr:create` Phase 2.5 ([create.md](../../../commands/pr/create.md), "2.5 Unaddressed Issues Check" section) implements the unaddressed issues check.

---

## Related

- [SKILL.md](../SKILL.md) - Principle summary
- [Phase Mapping](./phase-mapping.md) - Phase details
- [Issue Start Workflow](../../../commands/issue/start.md) - start.md
- [PR Create Command](../../../commands/pr/create.md) - Unaddressed issues check before PR creation (Phase 2.5)
- [PR Review](../../../commands/pr/review.md) - review.md
- [Markdown Authoring Conventions](#markdown-authoring-conventions) - Skill loader に load される Markdown ファイルの記述規約 (bash negation operator inline code convention)
- [gh-cli-patterns.md](../../../references/gh-cli-patterns.md) - Related bang character (U+0021) handling in bash command contexts (Shell Escaping Notes)
- [graphql-helpers.md](../../../references/graphql-helpers.md) - Related bang character handling in GraphQL query / jq contexts (History Expansion and Special Character Prevention)
- [gh-cli-error-catalog.md](../../../references/gh-cli-error-catalog.md) - Related bang character handling error catalog (Category 6)
