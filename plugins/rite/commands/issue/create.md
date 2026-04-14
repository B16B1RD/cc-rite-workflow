---
description: 新規 Issue を作成し、GitHub Projects に追加
---

# /rite:issue:create

Create a new Issue and add it to GitHub Projects.

---

## Responsibility Matrix

This table clarifies responsibility boundaries between `create.md`, `start.md`, and `implementation-plan.md`.

| Responsibility | `create.md` | `start.md` | `implementation-plan.md` |
|----------------|:-----------:|:----------:|:------------------------:|
| **Issue specification (What/Why/Where)** | ✅ Primary (Phase 0-0.7) | — | — |
| **Issue quality validation** | — | ✅ Primary (Phase 1) | — |
| **Duplicate detection** | ✅ Phase 0.3 | — | — |
| **Parent Issue detection** | — | ✅ Phase 0.3 | — |
| **Deep-dive interview** | ✅ Phase 0.5 | — | — |
| **Specification document generation** | ✅ Phase 0.7 (high-level design) | — | — |
| **Detailed implementation plan (How)** | — | — | ✅ Phase 3 (step-by-step) |
| **Issue creation + Projects registration** | ✅ Phase 2 | — | — |
| **Branch creation + work start** | — | ✅ Phase 2-5 | — |

**Key distinctions**: `create.md` Phase 0.3 = Similar Issue Search (duplicates, context, extensions). `start.md` Phase 0.3 = Parent Issue Auto-Detection. `create.md` Phase 0.7 = High-level design (What/Why/Where). `implementation-plan.md` Phase 3 = Detailed plan (How/Step-by-step).

---

## Sub-command Architecture

This command orchestrates the Issue creation flow by delegating to specialized sub-commands:

```
create.md (orchestrator)
├── create-interview.md   ← Phase 0.4.1 + 0.5 (Adaptive Interview)
├── create-decompose.md   ← Phase 0.7 + 0.8 + 0.9 + 1.0 (Spec + Decompose + Bulk Create + Terminal Completion)
└── create-register.md    ← Phase 1 + 2 + 3 + 4 (Classify + Confirm + Create Single Issue + Terminal Completion)
```

---

**CRITICAL**: This command orchestrates Issue creation end-to-end. After every sub-skill invocation returns, **immediately** proceed to the next phase. Do NOT stop until the Issue is created and the completion report (Issue URL) is output.

| Phase | Sub-skill | Next Phase | Stop Allowed? |
|-------|-----------|------------|---------------|
| 0.1-0.4 (Analysis) | — | Interview | No |
| Interview | `rite:issue:create-interview` | 0.6 | **No** |
| 0.6 (Decomposition) | — | Delegation | No |
| Delegation | `rite:issue:create-register` or `rite:issue:create-decompose` | (completes) | **No** |

When this command is executed, follow the phases below in order.

## Sub-skill Return Protocol

> **Reference**: See `start.md` [Sub-skill Return Protocol (Global)](./start.md#sub-skill-return-protocol-global) for the full protocol. The same rules apply here — DO NOT end your response after a sub-skill returns, DO NOT re-invoke the completed skill, and IMMEDIATELY proceed to the 🚨 Mandatory After section.

**Self-check**: After every sub-skill returns, ask yourself: "Has `[create:completed:{N}]` been output?" If not, you are NOT done — keep going.

**Completion marker convention** (Issue #444): The unified completion marker for the entire `/rite:issue:create` workflow is `[create:completed:{N}]`. Terminal sub-skills (`create-register.md`, `create-decompose.md`) output this marker as their absolute last line after handling flow-state deactivation and next-step display internally (Terminal Completion pattern). The orchestrator's 🚨 Mandatory After Delegation section serves as defense-in-depth.

**Defense-in-depth**: `create-interview.md` updates `.rite-flow-state` to a `post_*` phase (`create_post_interview`) before returning. Terminal sub-skills (`create-register.md`, `create-decompose.md`) set `create_completed` with `active: false` and output the completion marker directly. This ensures the workflow completes even if the orchestrator fails to continue after sub-skill return.

## Arguments

| Argument | Description |
|----------|-------------|
| `<title or description>` | Issue title or description of the work (required) |

---

## Preparation: Retrieve Project Settings

### Retrieve Repository Information

Get the owner and name of the current repository:

```bash
gh repo view --json owner,name
```

### Retrieve Language Settings

Read the `language` field from `rite-config.yml` to determine the output language:

```bash
# rite-config.yml を読み取り、language フィールドを確認
# 未設定の場合は "auto" として扱う
```

This value is used **from Phase 0 onward** to determine the language for:
- **Phase 0.1.5**: Parent Issue Pre-detection confirmation template
- **Phase 0.3**: Duplicate detection display and AskUserQuestion templates
- **Phase 0.4**: Quick Confirmation question templates
- **Phase 0.4.1**: Interview scope display messages
- **Phase 2.1**: Issue title and body language

**Note**: Phase 0.5 (Deep-Dive Interview) templates remain Japanese-only. Language-aware variants for Phase 0.5 are planned as future scope.

#### Language-Aware Template Selection

Throughout Phase 0, select the appropriate language variant for AskUserQuestion templates and display messages based on the `language` setting:

| Setting | Template Language | Detection |
|---------|-------------------|-----------|
| `ja` | Japanese templates | — |
| `en` | English templates | — |
| `auto` | Detect from user input language (default: Japanese) | Simplified check for CJK characters (`/[\u3000-\u9FFF\uF900-\uFAFF]/` — covers hiragana, katakana, kanji, and CJK punctuation) |

**Rule**: When `language` is `ja` or `auto` (with Japanese input detected), use Japanese templates. When `language` is `en` or `auto` (with English input detected), use English templates. Do not mix languages within a single AskUserQuestion call.

### Identify the Project

Determine which Project to use based on the following priority:

1. **If `project_number` is set in `rite-config.yml`**: Use that Project
2. **If not set**: Detect Projects linked to the repository

#### Method 1: Retrieve from rite-config.yml

```bash
# rite-config.yml を読み取り、github.projects.project_number を確認
```

If `project_number` is set, use that value.

#### Method 2: Detect Projects Linked to the Repository

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    projectsV2(first: 10) {
      nodes {
        id
        number
        title
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}"
```

**Important**: If multiple Projects are found, select the one whose name matches the repository name or the most relevant one.

#### If No Project is Found

```
警告: GitHub Projects が設定されていません。
Issue は作成しますが、Projects への追加はスキップします。
Projects を使用するには /rite:init を実行してください。
```

---

## Phase 0: Input Analysis and Completion

> **🚫 MUST NOT — Bypass prohibition (Mode B defense, #475)**
>
> Between this point and `[create:completed:{N}]`, the orchestrator MUST NOT:
>
> 1. Execute `gh issue create` via the Bash tool (blocked by `pre-tool-bash-guard.sh` hook)
> 2. Skip from here directly to output without invoking `rite:issue:create-interview`
> 3. Collapse the Delegation to Interview / Phase 0.6 / Delegation Routing sections into a single synthetic "create Issue" step
>
> Any of the above is a **protocol violation** regardless of how clearly Phase 0.1 extracted the information. The only legitimate path forward is: Pre-write below → `skill: "rite:issue:create-interview"` → 🚨 Mandatory After Interview → Phase 0.6 → Delegation Routing → terminal sub-skill.
>
> **⚠️ Drift guard**: This same block is repeated verbatim before the `## Delegation to Interview` section below. **Both occurrences MUST stay identical** — if you update one, update both. A grep-based check is the only drift detector.

### 0.1 Extract Information from User Input

#### EDGE-4: Short Input Handling

**Execution timing**: This check runs at the beginning of Phase 0.1, before the extraction table below.

Before extraction, check input length. If user input is **less than 10 Unicode characters** (excluding the command name), the input is too short to extract meaningful information:

**Step 1**: Detect short input

Count the number of Unicode characters (not bytes) in the user's input text after stripping whitespace. If fewer than 10 characters, treat as short input.

Examples of short input: "Fix" (3 chars), "Bug" (3 chars), "Update" (6 chars), "リファクタ" (5 chars), "修正" (2 chars)

**Note**: "Excluding the command name" means the text provided as the skill argument (e.g., the `args` parameter of the Skill tool). If the user invoked `/rite:issue:create "Fix"`, the input to check is `"Fix"` (3 characters).

**Step 2**: Request supplementary information via AskUserQuestion

Select the template based on the `language` setting (see [Language-Aware Template Selection](#language-aware-template-selection)):

**Japanese** (`ja` or `auto` with Japanese input):
```
質問: 入力が短すぎるため、もう少し詳しく教えてください。何を達成したいですか？

オプション:
- 詳細を入力する
- 既存の Issue を参照する（Issue 番号を入力）
```

**English** (`en` or `auto` with English input):
```
Question: The input is too short. Could you provide more details? What do you want to achieve?

Options:
- Provide details
- Reference an existing Issue (enter Issue number)
```

**Step 3**: Process the user's selection

| Selection | Action |
|-----------|--------|
| **Provide details / 詳細を入力する** | Use the supplementary input as the new user input and proceed to normal extraction below |
| **Reference an existing Issue / 既存の Issue を参照する** | Execute Step 3a below |

**Step 3a**: Reference an existing Issue

1. Prompt for the Issue number via AskUserQuestion (free-text input)
2. Verify the Issue exists: `gh issue view {issue_number} --json number,title,state,body --jq '{number,title,state}'`
3. If the Issue does not exist (404 error), display an error and re-prompt for the number
4. If the Issue exists and is CLOSED, present options (language-aware): "Use as reference to create new Issue" / "Re-enter Issue number". If reference selected, read body via `gh issue view {issue_number} --json body --jq '.body'` and use as context.

5. If the Issue exists and is OPEN, present options (language-aware): "Use as context for new Issue" / "Run /rite:issue:start on this Issue (cancel create)". If start selected, terminate create and output: `参照先の Issue に対して /rite:issue:start #{issue_number} を実行してください。` (or English equivalent).

**Phase 0.4 skip decision for short inputs**: If the original input was short (< 10 chars) but the supplementary input provides clear What/Why/Where, Phase 0.4 confirmation can be skipped (same logic as normal inputs where Phase 0.1 extracts all elements clearly).

---

Analyze user input and extract the following elements:

| Element | Description | Example |
|---------|-------------|---------|
| **What** | What to do | "Add login feature" |
| **Why** | Why it is needed | "For user authentication" |
| **Where** | Where to make changes | "Under src/auth/" |
| **Scope** | Scope of impact | "Frontend and backend" |
| **Constraints** | Constraints | "Maintain compatibility with existing API" |

### 0.1.3 Slug Pre-generation

**Purpose**: Generate the Issue slug early to avoid redundant Japanese→English translation in Phase 0.7.2. The slug is tentative and confirmed later when the Issue title is finalized.

Generate a slug from the extracted **What** element (or user input title):

**Slug generation rules** (canonical definition — referenced by Phase 0.7.2):
1. For Japanese: Claude translates to appropriate English considering context
   - Example: "テトリスゲームを作る" -> `tetris-game`
   - Example: "ユーザー認証システム" -> `user-auth-system`
   - Example: "ECサイト基盤構築" -> `ec-site-infrastructure`
2. Convert to lowercase
3. Replace spaces with hyphens
4. Remove special characters
5. Truncate to 50 characters or fewer

**Translation guidelines**:
- Technical terms are directly converted to English (e.g., "API" -> `api`, "データベース" -> `database`)
- Proper nouns may be romanized (e.g., "お知らせ機能" -> `oshirase-feature` or `notification-feature`)
- When in doubt, choose a commonly used, easily searchable English expression

Retain the generated slug in context as `{tentative_slug}` for use in Phase 0.7.2.

<!-- Phase 0.2: Removed — ambiguity detection merged into Phase 0.3 (context gathering) and Phase 0.5 Perspective 1 (Technical Implementation Details) -->

### 0.1.5 Parent Issue Pre-detection

**Purpose**: Detect early whether the user intends to create a large task that should be decomposed into sub-Issues, before investing in detailed questioning. This pre-empts Phase 0.6 (Task Decomposition Decision) by catching obvious parent Issue candidates upfront.

**Conditional execution**: Only execute this phase when the user input suggests a large-scope task. Skip if the input clearly describes a single, focused change.

**Detection heuristics** (any match triggers the confirmation):

| Signal | Example |
|--------|---------|
| Multiple distinct changes mentioned | "Add auth, logging, and caching" |
| Explicit scope keywords | "全体的に", "across all", "multiple files", "一括" |
| Estimated complexity >= L (rough) | Rough estimate from Phase 0.1 scope/constraints — not the formal tentative complexity from Phase 0.4.1. Use as a supplementary signal alongside other heuristics |
| Umbrella/epic language | "プロジェクト", "大型", "epic", "umbrella", "phase" |

**When pre-detection triggers:**

Select the template based on the `language` setting (see [Language-Aware Template Selection](#language-aware-template-selection)):

**Japanese** (`ja` or `auto` with Japanese input):
```
この Issue は複数の Sub-Issue に分解すべき大型タスクですか？

オプション:
- はい、Sub-Issue に分解する（推奨）
- いいえ、単一の Issue として作成する
```

**English** (`en` or `auto` with English input):
```
Is this a large task that should be decomposed into sub-Issues?

Options:
- Yes, decompose into sub-Issues (Recommended)
- No, create as a single Issue
```

**Selection handling:**

| Selection (ja) | Selection (en) | Action |
|-----------|-----------|--------|
| **はい、Sub-Issue に分解する** | **Yes, decompose into sub-Issues** | Skip Phases 0.3-0.5. Proceed directly to Phase 0.6 (Task Decomposition Decision) with `force_decompose: true` flag. Phase 0.6.1 skips trigger evaluation and Phase 0.6.2 confirmation, proceeding to Phase 0.7 (Specification Document Generation) |
| **いいえ、単一の Issue として作成する** | **No, create as a single Issue** | Proceed to Phase 0.3 normally |

**⚠️ Note on skipping Phase 0.3**: When "はい、Sub-Issue に分解する" is selected, Phase 0.3 (Similar Issue Search) is skipped. This means duplicate detection is not performed. This is acceptable because: (1) large/parent tasks are less likely to have exact duplicates, and (2) Phase 0.9 creates sub-Issues individually, where duplicates can be caught at that stage. If duplicate risk is a concern, the user should select "いいえ" and proceed through the normal flow.

**When pre-detection does not trigger:** Proceed to Phase 0.3 directly (no user prompt).

### 0.3 Search for Similar Issues

**Purpose**: Resolve ambiguity in user input by finding related existing Issues. This phase handles duplicate detection, context gathering, and related Issue linkage — parent Issue detection is handled by `start.md`.

Collect related information from existing Issues using keyword-based search:

```bash
# Extract 2-3 keywords from user input for targeted search
# Example: "Add login feature" → keywords: "login feature"
# Example: "認証バグの修正" → keywords: "認証 バグ"
result=$(gh issue list --search "is:open {keywords}" --limit 10 --json number,title,labels)

# If no results with --search, fall back to broader search
if [ "$(echo "$result" | jq 'length')" -eq 0 ]; then
  result=$(gh issue list --state all --limit 10 --json number,title,labels)
fi

echo "$result"
```

**Keyword extraction rules**:
1. Remove stop words (a, the, is, を, が, の, で, etc.)
2. Extract 2-3 most significant nouns/verbs from user input
3. For Japanese input, extract key terms as-is (no translation)
4. Use space-separated keywords in the `--search` query

Identify Issues with similar titles or related labels. Use them to:
1. **Detect potential duplicates** and warn the user before creating a new Issue
2. **Gather context** to clarify ambiguous user input (e.g., resolve "Fix the auth bug" by identifying which specific auth Issue it relates to)
3. **Detect extension opportunities** — when a similar Issue exists, confirm whether the new Issue is an extension of it (GAP-1)

#### 0.3.1 Relevance Scoring and Sorting

When multiple similar Issues are found, sort them by relevance before presenting to the user:

**Relevance scoring criteria:**

| Factor | Weight | Description |
|--------|--------|-------------|
| Title similarity | High | Keyword overlap between user input and Issue title |
| Label match | Medium | Shared labels between inferred labels and existing Issue labels |
| Recency | Low | More recently updated Issues rank higher |
| State | Low | OPEN Issues rank slightly higher than CLOSED |

Sort primarily by title similarity, then by label match as tiebreaker, then by recency. Display the top 5 matches maximum.

#### 0.3.2 Single Similar Issue Found

When exactly one similar Issue is found, present an enhanced confirmation (language-aware) with 3 options:

| Selection | Action |
|-----------|--------|
| **Create as extension of #{number}** | Proceed to Phase 0.4. In Phase 2, append `Extends: #{number}` to the Issue body and add a reference link |
| **Use existing Issue** | Terminate the create flow. Output the selected Issue number and suggest `/rite:issue:start {number}` |
| **Create as a new Issue (no relation)** | Proceed to Phase 0.4 (no relation) |

#### 0.3.3 Multiple Similar Issues Found

When 2+ similar Issues are found (sorted by relevance per 0.3.1), present the list with `{relevance_summary}` (e.g., "タイトル類似", "title overlap") and 3 options (language-aware):

| Selection | Action |
|-----------|--------|
| **Create as extension of #{number_1}** | Proceed to Phase 0.4. In Phase 2, append `Extends: #{number}` to the Issue body |
| **Select a different existing Issue** | Prompt for Issue number. Follow-up: "Start working on this Issue" / "Create as extension". Route accordingly |
| **No relation — create as new Issue** | Proceed to Phase 0.4 (no relation) |

#### 0.3.4 No Similar Issues Found

**When no potential duplicates are found:** Proceed directly to Phase 0.4.

### 0.4 Quick Confirmation

**Purpose**: Supplement only the information gaps from Phase 0.1. This phase does NOT re-confirm What/Why/Where if they were already clearly extracted in Phase 0.1.

**Conditional execution**:

| Phase 0.1 Result | Action in Phase 0.4 |
|-------------------|---------------------|
| What/Why/Where all clear | Skip confirmation questions → proceed directly to goal classification |
| What clear, Why or Where unclear | Ask only about the missing elements (1 AskUserQuestion call, see template below) |
| What unclear | Ask the full goal clarification question (1 AskUserQuestion call) |

**Missing element question templates** (language-aware, select based on `language` setting):

| Missing Element | Question (ja/en) | Options |
|----------------|-------------------|---------|
| Why only | なぜこの変更が必要ですか？ / Why is this change needed? | `{inferred_reason}` / Other |
| Where only | 変更対象のファイル/ディレクトリは？ / Which files/directories? | `{inferred_location}` / Other |
| Both Why and Where | Combine into single AskUserQuestion with 2 questions | `{inferred_reason} / {inferred_location}` / Other |

**Goal classification** (always determined, either by asking or by inference from Phase 0.1):

Determine the task type for Phase 0.4.1 adaptive interview depth via AskUserQuestion (language-aware). Options: 新機能の追加 / 既存機能のバグ修正 / ドキュメントの更新 / リファクタリング / その他 (or English equivalents).

**Note**: If Phase 0.1 extraction already provides a clear task type (e.g., user input starts with "bug:", title contains "refactor"), infer the goal classification without asking.

**Completion criteria for Phase 0.4**: See [Termination Logic > Phase 0.4 Completion Criteria](#phase-04-completion-criteria).

### 0.4.2 Skip Semantics (Critical — Mode B Defense)

> **⚠️ READ THIS EVERY TIME Phase 0.4 is skipped.**

When Phase 0.1 already extracted What/Why/Where clearly and Phase 0.4 confirmation questions are skipped, this means **ONLY** that the user-facing confirmation dialog is skipped. It does **NOT** mean any of the following are skipped:

| MUST execute even when Phase 0.4 confirmation is skipped | Why (enforcement layer) |
|---|---|
| Phase 0.4.1 goal classification (infer task type from Phase 0.1) | Required by Phase 0.5 interview scope determination |
| Delegation to Interview section (Pre-write + `rite:issue:create-interview` Skill) | Without the `create_interview` flow-state write, stop-guard has no hook to enforce delegation |
| 🚨 Mandatory After Interview | Updates `.rite-flow-state.phase=create_post_interview`; stop-guard keeps blocking until `create_delegation` is written below |
| Phase 0.6 (Task Decomposition Decision) | Chooses between `create-register` (single Issue) and `create-decompose` (sub-Issues) |
| Delegation Routing (Pre-write + terminal sub-skill Skill invocation) | Writes `create_delegation`, advancing the whitelist past `create_post_interview` |
| 🚨 Mandatory After Delegation | Defense-in-depth for the terminal `create_completed` state |

**The only legitimate way to create a GitHub Issue from this command is by invoking `rite:issue:create-register` or `rite:issue:create-decompose` as a Skill.** Calling `gh issue create` directly from the orchestrator bypasses flow-state tracking, Projects integration, and every enforcement layer — and is **blocked by `pre-tool-bash-guard.sh`** when `.rite-flow-state.phase = create_*`.

---

## Delegation to Interview

> **🚫 MUST NOT — Bypass prohibition (Mode B defense, #475)**
>
> Between this point and `[create:completed:{N}]`, the orchestrator MUST NOT:
>
> 1. Execute `gh issue create` via the Bash tool (blocked by `pre-tool-bash-guard.sh` hook)
> 2. Skip from here directly to output without invoking `rite:issue:create-interview`
> 3. Collapse the Delegation to Interview / Phase 0.6 / Delegation Routing sections into a single synthetic "create Issue" step
>
> Any of the above is a **protocol violation** regardless of how clearly Phase 0.1 extracted the information. The only legitimate path forward is: Pre-write below → `skill: "rite:issue:create-interview"` → 🚨 Mandatory After Interview → Phase 0.6 → Delegation Routing → terminal sub-skill.
>
> **⚠️ Drift guard**: This same block is repeated verbatim at the start of Phase 0 above. **Both occurrences MUST stay identical** — if you update one, update both. A grep-based check is the only drift detector.

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before executing bash hook commands in this file.

**Pre-write** (before invoking interview sub-skill): Update `.rite-flow-state` so stop-guard can prevent interruptions:

```bash
if [ -f ".rite-flow-state" ]; then
  # Preserve existing fields (issue_number, branch, etc.) from caller (e.g., start.md)
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_interview" \
    --next "After rite:issue:create-interview returns: proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
else
  bash {plugin_root}/hooks/flow-state-update.sh create \
    --phase "create_interview" --issue 0 --branch "" --pr 0 \
    --next "After rite:issue:create-interview returns: proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
fi
```

Invoke `skill: "rite:issue:create-interview"`.

**🚨 Immediate after interview returns**: When `rite:issue:create-interview` outputs a result pattern (`[interview:completed]` or `[interview:skipped]`) and returns control, do **NOT** churn or pause — **immediately** proceed to 🚨 Mandatory After Interview below. The interview sub-skill has already updated `.rite-flow-state` to `create_post_interview` via its Defense-in-Depth section; execute the 🚨 Mandatory After Interview steps without delay.

### 🚨 Mandatory After Interview

> **Enforcement**: `.rite-flow-state.phase` is `create_post_interview` at this point (the sub-skill wrote this via its Defense-in-Depth section). Stop-guard blocks any stop attempt while the flow-state is active — it will not unblock until `.rite-flow-state.phase` advances to `create_delegation` (via the Delegation Routing Pre-write below) or reaches `create_completed` (via the terminal sub-skill). Step 1 below refreshes the state timestamp but does NOT advance the phase on its own — the only legitimate path to a stoppable state is to continue through Phase 0.6 → Delegation Routing → terminal sub-skill. See start.md [Sub-skill Return Protocol (Global)](./start.md#sub-skill-return-protocol-global).

No GitHub Issue has been created yet. The interview only collects information.

**Step 1**: Update `.rite-flow-state` to post-interview phase (atomic). The sub-skill has already written `create_post_interview` via its Defense-in-Depth section; this second write refreshes the timestamp and `next_action`:

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_post_interview" \
  --next "rite:issue:create-interview completed. Proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 0.6 (Task Decomposition Decision) now. Do NOT stop.**

---

## Phase 0.6: Task Decomposition Decision

**Purpose**: Detect coarse-grained Issues and determine whether decomposition is needed.

### 0.6.1 Decomposition Trigger Evaluation

**Fast path**: If `force_decompose: true` flag is set from Phase 0.1.5 (Parent Issue Pre-detection), skip the trigger evaluation below and Phase 0.6.2 confirmation. Proceed directly to decomposition via `rite:issue:create-decompose`.

Proceed to the decomposition flow when **all** of the following conditions are met:

| Condition | Criteria |
|-----------|----------|
| **Tentative complexity is XL** | Tentative complexity determined in Phase 0.4.1 is XL |
| **Contains comprehensive expressions** | Title or body contains the following patterns |

**Patterns of Comprehensive Expressions**:

The following patterns are limited to expressions indicating "overall picture" or "new system". Simple feature additions (e.g., "implement login feature") are excluded.

| Language | Patterns Subject to Decomposition (broad scope) | Patterns NOT Subject to Decomposition (limited scope) |
|----------|------------------------------------------------|------------------------------------------------------|
| Japanese | "~system wo tsukuru", "~platform", "~app wo kaihatsu", "~wo zenmen renewal", "~kiban wo kouchiku" | "~kinou wo tsuika", "~gamen wo jissou", "~wo shuusei" |
| English | "build ~ system", "create ~ platform", "develop ~ application", "rebuild ~ from scratch", "implement ~ infrastructure" | "add ~ feature", "implement ~ screen", "fix ~" |

**Supplementary rules for evaluation**:
- "~wo tsukuru" alone is excluded (too ambiguous). Only applies when the type of deliverable is specified, e.g., "~system wo tsukuru", "~app wo tsukuru"
- When spanning multiple domains (e.g., authentication + payment + notification), consider decomposition regardless of patterns

**Notes**:
- Even with tentative complexity XL, decomposition is unnecessary if the scope is clear and can be completed in a single PR
- Decomposition evaluation is executed automatically, but the final decision is left to the user
- When in doubt, ask the user for confirmation (Phase 0.6.2 confirmation dialog)

### 0.6.2 Decomposition Confirmation

> **Reference**: See [Termination Logic > Phase 0.6 Decomposition Decision Termination](#phase-06-decomposition-decision-termination) for the termination routing table.

When decomposition triggers are met, confirm with `AskUserQuestion`:

```
この Issue は大規模なタスク（複雑度: XL）です。

タイトル: {title}

複数の Sub-Issue に分解することで、以下のメリットがあります:
- 進捗の可視化が容易になる
- 各タスクを独立して管理できる
- 複数人での並行作業が可能になる

オプション:
- Sub-Issue に分解する（推奨）: 詳細な仕様書を生成し、複数の Issue に分割します
- 単一 Issue として作成: このまま1つの Issue として作成します
```

**Subsequent processing for each option**: See [Termination Logic > Phase 0.6 Decomposition Decision Termination](#phase-06-decomposition-decision-termination).

**Context carryover when "単一 Issue として作成" is selected**:

Information collected through Phase 0.5 is utilized in Phase 1 onwards as follows:

| Collected Information | Carryover Destination |
|----------------------|----------------------|
| What/Why/Where | Implementation Contract Section 1 (Goal), Section 2 (Scope) of the Issue body |
| Interview results (technical decisions, etc.) | Implementation Contract Sections 1-9 via interview-to-section mapping (see `create-register.md` Phase 2.2 Step 3) |
| Tentative complexity XL | Finalized in Phase 1.1. Recorded as XL even when decomposition is cancelled |
| Out-of-scope items | Implementation Contract Section 2 (Out of Scope), Section 1 (Non-goal) |

#### EDGE-3: Interview Result Reflection Rules

When "単一 Issue として作成" is selected (Phase 0.6) or "キャンセル" is selected (Phase 0.7), interview results **MUST** be reflected in the Implementation Contract sections of the Issue body. The following rules enforce this:

**Condition logic for inclusion**:

| Phase 0.5 Status | Implementation Contract Sections | Content |
|-------------------|----------------------------------|---------|
| Phase 0.5 executed with interview results | **MUST populate** target sections per interview-to-section mapping (`create-register.md` Phase 2.2 Step 3) | Map each interview perspective to corresponding Implementation Contract sections (e.g., Technical Implementation → 4.1, 4.3, 4.4) |
| Phase 0.5 skipped (XS/Bug Fix/Chore) | **Populate if** Phase 0.4 gathered useful context | Summary of Phase 0.4 context in relevant sections; omit optional sections if no meaningful detail exists |
| Phase 0.5 executed but user gave minimal responses | **MUST populate** | Whatever was gathered, plus AI-inferred details marked with `（推定）` |
| Phase 0.3-0.5 all skipped (Phase 0.1.5 early decomposition → cancel back to single Issue) | **MUST populate** MUST sections per Complexity Gate | Phase 0.1 context (What/Why/Where) for available sections; `<!-- 情報未収集 -->` placeholder for MUST sections without data. Goal classification: infer from Phase 0.1 extraction. Complexity: use XL (from Phase 0.1.5 detection) as tentative baseline, finalize via Heuristics Scoring in `create-register.md` Phase 1.1 |

**Display rules for Implementation Contract sections**:

1. **Complexity Gate compliance**: Follow the Complexity Gate table to determine which sections are MUST/SHOULD/OMIT for the given complexity level. This applies uniformly regardless of which phases were executed or skipped
2. **AI inference marking**: When AI infers details not explicitly confirmed by the user, mark them with `（推定）` suffix
3. **Cross-reference with Phase 0.4**: Include any What/Why/Where context from Phase 0.4 that was not repeated in Phase 0.5 to avoid information loss. When Phase 0.4 was not executed, use Phase 0.1 context directly
4. **MUST section placeholder**: If a section is MUST by Complexity Gate but no interview data exists, include the section with a placeholder comment (`<!-- 情報未収集 -->`). This rule applies to all paths — no path is exempt from Complexity Gate compliance

---

## Delegation Routing

Based on Phase 0.6 result, delegate to the appropriate sub-command.

**Pre-write** (before invoking delegation sub-skill): Update `.rite-flow-state` so stop-guard can prevent interruptions:

```bash
if [ -f ".rite-flow-state" ]; then
  # Preserve existing fields (issue_number, branch, etc.) from caller
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_delegation" \
    --next "Wait for sub-skill (create-register or create-decompose) to output completion report (Issue URL). Issue has NOT been created yet. Do NOT stop."
else
  bash {plugin_root}/hooks/flow-state-update.sh create \
    --phase "create_delegation" --issue 0 --branch "" --pr 0 \
    --next "Wait for sub-skill (create-register or create-decompose) to output completion report (Issue URL). Issue has NOT been created yet. Do NOT stop."
fi
```

### When decomposition is selected

Invoke `skill: "rite:issue:create-decompose"`.

### When single Issue is selected (or decomposition not triggered)

Invoke `skill: "rite:issue:create-register"`.

**Context handoff to `create-register`**: The following context MUST be available when `create-register` is invoked. When invoking the skill, include these as part of the prompt context to prevent information loss across skill boundaries:

| Context | Source | When Phase 0.3-0.5 skipped (Phase 0.1.5 path) |
|---------|--------|------------------------------------------------|
| What/Why/Where | Phase 0.1 extraction | Always available |
| Goal classification | Phase 0.4 | **Not available** — `create-register` Phase 1.2 infers from Phase 0.1 |
| Tentative complexity | Phase 0.4.1 | **Not available** — `create-register` Phase 1.1 uses XL as baseline (from Phase 0.1.5 detection) and finalizes via Heuristics Scoring |
| Interview results | Phase 0.5 | **Not available** — EDGE-3 row 4 applies (MUST sections with placeholders) |
| Tentative slug | Phase 0.1.3 | Always available |
| `phases_skipped` flag | Phase 0.1.5 | Set to `"0.3-0.5"` when Phase 0.1.5 triggered early decomposition. Set to `null` otherwise |

**🚨 Immediate after delegation returns**: When the sub-skill outputs a result pattern (`[create:completed:{N}]`) and returns control, verify that the workflow completed successfully.

> **Note on result patterns** (Issue #444): Terminal sub-skills (`create-register`, `create-decompose`) now output `[create:completed:{N}]` as the unified completion marker. The sub-skill handles flow-state deactivation, next-step output, and completion marker internally (Terminal Completion pattern). The legacy patterns `[register:created:{N}]` and `[decompose:completed:{N}]` have been replaced and are no longer output.

### 🚨 Mandatory After Delegation (Defense-in-Depth)

> **Enforcement**: Terminal sub-skills (`create-register.md`, `create-decompose.md`) write `create_completed` + `active: false` and output `[create:completed:{N}]` internally (Issue #444 Terminal Completion pattern). See start.md [Sub-skill Return Protocol (Global)](./start.md#sub-skill-return-protocol-global).

**Self-check and branching**:

1. **Has `[create:completed:{N}]` been output?**
   - **Yes** — terminal state reached. `.rite-flow-state.phase` is already `create_completed` and `active: false`. Steps 1-3 below are **no-ops** and MUST be skipped (executing Step 1 would write `create_post_delegation` which is a retrograde transition from the terminal state).
   - **No** — the sub-skill failed to complete its Terminal Completion phase. Steps 1-3 below are **critical** and must execute to force the workflow into the terminal state.

**Step 1**: Update `.rite-flow-state` to post-delegation phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_post_delegation" \
  --next "Sub-skill completed. Deactivate flow state and output next steps. Do NOT stop."
```

**Step 2**: Deactivate flow state (idempotent — safe to re-execute if already deactivated by sub-skill):

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_completed" \
  --next "none" --active false
```

**Step 3**: Output the next steps (idempotent — if already output by sub-skill, this is a duplicate that the user can safely ignore):

```
次のステップ:
1. `/rite:issue:start {number}` で作業を開始
2. 作業完了後 `/rite:pr:create` で PR 作成
```

Where `{number}` is the Issue number extracted from the sub-skill's result pattern.

**Step 4**: The workflow is now complete. Stop is allowed after cleanup.

---

## Termination Logic

> **Note**: This is a reference section, not part of the sequential Phase 0.x flow. During execution, jump here only when referenced by a specific Phase.

### Phase 0.4 Completion Criteria

Phase 0.4 completes when **all** of the following are satisfied:

| Criterion | Description |
|-----------|-------------|
| What | What to do is clear |
| Why | Why it is needed is understood |
| Where | Target of changes is identified |

If any criterion is not met, ask clarifying questions (see Phase 0.4 templates).

### Phase 0.6 Decomposition Decision Termination

Phase 0.6 terminates based on the user's selection in the decomposition confirmation dialog (Phase 0.6.2):

| User Selection | Next Phase |
|----------------|------------|
| Sub-Issue に分解する（推奨） | Invoke `skill: "rite:issue:create-decompose"` |
| 単一 Issue として作成 | Invoke `skill: "rite:issue:create-register"`. Interview results from Phase 0.5 are mapped to Implementation Contract sections via `create-register.md` Phase 2.2 Step 3. See Phase 0.6.2 for context carryover details |
