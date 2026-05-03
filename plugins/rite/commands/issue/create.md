---
description: |
  Issue 作成 / new issue / 起票 / Issue 化 — 新規 Issue を作成し、GitHub Projects に登録する。
  重複検出・親 Issue 候補検出・XL 自動分解（Sub-Issue 作成 + 設計仕様書生成）を含む。
  Use when 「Issue 作って」「タスクを起票」「create issue」「新規 Issue」など。
---

# /rite:issue:create

Create a new Issue and add it to GitHub Projects.

---

## Happy Path (90% のケース)

1. **Phase 0.1**: ユーザ入力から What/Why/Where を抽出
2. **`rite:issue:create-interview`**: 適応的インタビュー (Bug Fix/Chore は skip)
3. **Phase 0.6**: XL 判定 (大規模なら自動分解)
4. **`rite:issue:create-register`** または **`rite:issue:create-decompose`**: Issue 作成
5. ✅ Issue #N 作成完了

詳細フローは下のセクション。回帰防止メタ情報は `references/regression-history.md`（TBD: Sub-Issue P1-3 完了後に link 有効化）。

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

> **Reference**: See `start.md` [Sub-skill Return Protocol (Global)](./start.md#sub-skill-return-protocol-global) and the global reference `plugins/rite/skills/rite-workflow/references/sub-skill-return-protocol.md` for the full contract. The same rules apply here — DO NOT end your response after a sub-skill returns, DO NOT re-invoke the completed skill, and IMMEDIATELY proceed to the 🚨 Mandatory After section in the **same response turn**.

### Pre-check list (Issue #552 — mandatory before ending any response turn)

**Enforcement coupling**: protocol violation 時は `stop-guard.sh` が block し、`manual_fallback_adopted` workflow_incident sentinel が stderr に echo されて Phase 5.4.4.1 で post-hoc 検出される (AC-7)。つまり「turn を閉じたつもりが stop-guard に止められる」という体験で強制される。

**Evaluation context** (2 場面で同じチェックリストを使う):

| 場面 (a): sub-skill return 直後 | 場面 (b): turn 終了直前 |
|---|---|
| まだワークフロー中途。`NO` は「次の継続ステップを実行すべき」を意味する | 終端到達確認。`NO` は **protocol violation** (工程を飛ばして停止しようとしている) |

場面 (a) では Item 1-3 が `NO` でも正常 (まだ Issue 未作成段階)。場面 (b) では 4 項目すべて `YES` が turn 終了の必要条件。

**Procedure**: Item 0 は **routing dispatcher** (YES/NO ではなく tag に応じて経路を選ぶ前段処理)。Item 0 を最優先で evaluate し、該当する経路に進んだ後、場面 (b) では **Item 1-3 が YES/NO で評価される状態チェック**。turn 終了の可否は Item 1-3 のみを集計する。

| # | Check (種別) | If YES/NO / routing, do |
|---|-------------|------------------------|
| 0 | **Routing dispatcher** (状態質問ではない): 直前の sub-skill return tag は何か? | grep the recent output (HTML comments included) for `[interview:skipped]` / `[interview:completed]` / `[create:completed:{N}]` / `[CONTEXT] INTERVIEW_DONE=1` (Issue #634). Both the bare bracket form (legacy) and HTML-comment form (`<!-- [...] -->`, Issue #561 current) match. 推奨形式は 3 回の `grep -F` 呼び出し: `grep -F '[create:completed:'`, `grep -F '[interview:'`, `grep -F '[CONTEXT] INTERVIEW_DONE=1'`。ERE を使う場合は `grep -E '\[(interview\|create):[a-z:0-9]+\]'` **ではなく** `grep -E '\[(interview|create):[a-z:0-9]+\]'` (unescaped pipe — ERE では `\|` がリテラル `|` として解釈されるため alternation として機能しない、#582 で検出)。**Issue #634 補強**: `[CONTEXT] INTERVIEW_DONE=1` grep marker は `create-interview.md` Return Output Format の FIRST 行として emit される plain-text marker で、HTML コメント除去 rendering でも grep 可能。`[interview:skipped]` / `[interview:completed]` のいずれかが matched **または** `[CONTEXT] INTERVIEW_DONE=1` が matched した時点で **continuation trigger** として扱う — immediately run 🚨 Mandatory After Interview (Step 0 Immediate Bash Action → Step 1 → Step 2 → Step 3 → Phase 0.6 → Delegation Routing → terminal sub-skill)。If `[create:completed:{N}]` matched: run 🚨 Mandatory After Delegation self-check (Step 1/2 no-ops when marker is present, Step 3 is idempotent output)。If tag が上記いずれでもない / 無い: 通常の Phase 進行中なので Item 1-3 を評価 (場面 (a) は NO でも legitimate)。未知 tag (unexpected return format): manual 停止して diag log を確認。**本 Item は YES/NO 集計から除外** — ルーティング前段として機能する。 |
| 1 | **State check**: `[create:completed:{N}]` が HTML コメントまたはベアブラケット形式で最終行 (あるいは末尾近傍) に出力済みか? | 推奨形式: `grep -F '[create:completed:'` (fixed string で HTML コメント内の string も matchable)。ERE 使用時は `grep -E '\[create:completed:[0-9]+\]'` (`-E` flag 必須 — BRE では `[0-9]+` が「1 個の数字 + リテラル `+`」と解釈され sentinel にマッチしない、#582 で検出)。**注意**: bracket-unescaped 形式 `[create:completed:[0-9]+]` は character class として誤解釈されるため使用禁止。場面 (a) では `NO` でも legitimate — 次の Pre-write + sub-skill invocation に進む。場面 (b) では `NO` は terminal sub-skill が未完了 — Mandatory After Delegation Step 3 (defense-in-depth として完了メッセージ + 次のステップ + HTML コメント sentinel を出力) を実行。 |
| 2 | **State check**: ユーザー向け完了メッセージが表示済みか? (3 形式のいずれか 1 つを含めば YES) | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は terminal sub-skill の完了メッセージが欠落 — Mandatory After Delegation Step 3 を実行 (idempotent)。**識別 substring**: 3 形式は以下の排他的な substring で識別可能 — register: `を作成しました:` (コロン付き URL), decompose: `を分解して` (中間句), orchestrator fallback: `を作成しました` かつ `:` を含まない。いずれか 1 形式の識別 substring を含めば YES 判定。 |
| 3 | **State check**: flow state が deactivate 済みか? (`active: false`, `phase: create_completed`) | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は terminal state 未到達 — terminal sub-skill を呼ぶか Mandatory After Delegation Step 2 を実行。 |

**Rule**: **Item 1-3 すべて `YES`** が turn 終了の必要条件 **ただし場面 (b) においてのみ**。Item 0 は routing dispatcher で YES/NO 集計には含まれない (経路選択が完了すれば Item 1-3 の evaluation に進む)。場面 (a) では Item 1-3 の `NO` は「次のステップに進め」を意味する正常シグナル。Item 1-3 全 `YES` は terminal state (Issue 作成完了 + sentinel 出力 + flow-state deactivate) を保証する。

**Responsibility split**: 本 Pre-check list は turn 終了直前の手続的検証、Anti-pattern / Correct-pattern sections は sub-skill return 直後の推奨/禁止パターン (重複ではなく補完関係)。Pre-check list の各項目が `NO` の場合は Anti-pattern のルール (「turn を閉じない」) に従い即時継続すること。

**Self-check alias** (後方互換): `Has [create:completed:{N}] been output?` = Pre-check Item 1。下流の Mandatory After sections から本 Pre-check list を参照する際は Item 1-3 の終端条件をまとめて評価する。

### Anti-pattern (what NOT to do)

When `rite:issue:create-interview` returns `<!-- [interview:skipped] -->` or `<!-- [interview:completed] -->` (HTML comment form per Issue #561):

```
[WRONG]
<Skill rite:issue:create-interview returns>
<LLM output: "<!-- [interview:skipped] -->">
<LLM ends turn. User sees "Cooked for 2m 0s" and must type `continue` manually.>
```

This is a **bug**. The return tag is NOT a turn boundary — it is a hand-off signal. Ending the turn here abandons the workflow mid-flight with no Issue created. Note: even though the sentinel is now wrapped in an HTML comment (#561 UX fix), the LLM's turn-boundary heuristic may still fire if the Mandatory After section is not executed immediately.

### Correct-pattern (what to do)

```
[CORRECT]
<Skill rite:issue:create-interview returns>
<LLM output: "<!-- [interview:skipped] -->">
<In the same response turn, LLM IMMEDIATELY:>
  1. Runs the Pre-write bash for Phase 0.6 / Delegation Routing
  2. Evaluates Phase 0.6 triggers
  3. Runs the Delegation Routing Pre-write bash
  4. Invokes skill: "rite:issue:create-register" (or create-decompose)
  5. Waits for <!-- [create:completed:{N}] --> (HTML comment form)
  6. Runs Mandatory After Delegation self-check
```

**Rule**: Treat `[interview:skipped]` / `[interview:completed]` (both now emitted inside HTML comments per Issue #561) as **continuation triggers**, not as stopping points. Both terminal sub-skills (`create-register`, `create-decompose`) output `<!-- [create:completed:{N}] -->` as the unified completion marker (HTML comment form). The **only** valid stop in this workflow is after the user-visible completion message (`✅ Issue #{N} を作成しました: {url}`) + next-steps block have been displayed AND `<!-- [create:completed:{N}] -->` is output as the absolute last line (the terminal sub-skill emits them in this order — see `create-register.md` Phase 4.2/4.3/4.4 and `create-decompose.md` Phase 1.0.2/1.0.3).

> **Contract phrases (AC-3, Issue #525)**: The anti-pattern / correct-pattern contract above uses these exact phrases: `anti-pattern`, `correct-pattern`, `same response turn`, `DO NOT stop`. These phrases are grep-verified as part of the AC-3 static check — do not rewrite them away. Manual verification command:
>
> ```bash
> for p in "anti-pattern" "correct-pattern" "same response turn" "DO NOT stop"; do
>   grep -c "$p" plugins/rite/commands/issue/create.md
> done
> # Expected: all 4 counts >= 1
> ```

**Completion marker convention** (Issue #444 + Issue #561): The unified completion marker for the entire `/rite:issue:create` workflow is `[create:completed:{N}]`, emitted as an HTML comment (`<!-- [create:completed:{N}] -->`) on the absolute last line of the terminal sub-skill's output. The HTML comment form (Issue #561 D-01) keeps the string grep-matchable (`grep -F '[create:completed:'` / `grep -E '\[create:completed:[0-9]+\]'`) while ensuring the user-visible final content is the `✅` completion message + next-steps block (AC-2 / AC-3 of #561). Terminal sub-skills (`create-register.md`, `create-decompose.md`) handle flow-state deactivation, user-visible completion message, next-step display, and the HTML-commented sentinel internally (Terminal Completion pattern). The orchestrator's 🚨 Mandatory After Delegation section serves as defense-in-depth.

**Defense-in-depth**: `create-interview.md` updates flow state to a `post_*` phase (`create_post_interview`) before returning. Terminal sub-skills (`create-register.md`, `create-decompose.md`) set `create_completed` with `active: false` and output the completion marker directly. This ensures the workflow completes even if the orchestrator fails to continue after sub-skill return.

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

> **Identity reference**: 本 skip semantics は [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md) の `no_step_omission` / `no_context_introspection` principle の具体化である。「時間的制約」「context 残量」を理由にした step 省略は禁止。user-facing 確認 dialog の skip は 0.4.1 / 0.4.2 / Interview delegation / Phase 0.6 / Routing の MUST step 省略を許可するものではない。

When Phase 0.1 already extracted What/Why/Where clearly and Phase 0.4 confirmation questions are skipped, this means **ONLY** that the user-facing confirmation dialog is skipped. It does **NOT** mean any of the following are skipped:

| MUST execute even when Phase 0.4 confirmation is skipped | Why (enforcement layer) |
|---|---|
| Phase 0.4.1 goal classification (infer task type from Phase 0.1) | Required by Phase 0.5 interview scope determination |
| Delegation to Interview section (Pre-write + `rite:issue:create-interview` Skill) | Without the `create_interview` flow-state write, stop-guard has no hook to enforce delegation |
| 🚨 Mandatory After Interview | Updates flow state の `.phase=create_post_interview`; stop-guard keeps blocking until `create_delegation` is written below |
| Phase 0.6 (Task Decomposition Decision) | Chooses between `create-register` (single Issue) and `create-decompose` (sub-Issues) |
| Delegation Routing (Pre-write + terminal sub-skill Skill invocation) | Writes `create_delegation`, advancing the whitelist past `create_post_interview` |
| 🚨 Mandatory After Delegation | Defense-in-depth for the terminal `create_completed` state |

**The only legitimate way to create a GitHub Issue from this command is by invoking `rite:issue:create-register` or `rite:issue:create-decompose` as a Skill.** Calling `gh issue create` directly from the orchestrator bypasses flow-state tracking, Projects integration, and every enforcement layer — and is **blocked by `pre-tool-bash-guard.sh`** when flow state の `.phase = create_*`.

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

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing bash hook commands in this file.

**Pre-write** (before invoking interview sub-skill): Update flow state so stop-guard can prevent interruptions:

```bash
# state file の正しい path を解決 (schema_version=2 は per-session file、
# legacy は single-file 形式)。helper が空文字列を返す異常ケースは create branch に進む。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  # Preserve existing fields (issue_number, branch, etc.) from caller (e.g., start.md)
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_interview" \
    --active true \
    --next "After rite:issue:create-interview returns: proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
else
  bash {plugin_root}/hooks/flow-state-update.sh create \
    --phase "create_interview" --issue 0 --branch "" --pr 0 \
    --next "After rite:issue:create-interview returns: proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
fi
```

Invoke `skill: "rite:issue:create-interview"`.

**🚨 Immediate after interview returns**: When `rite:issue:create-interview` outputs a result pattern (`[interview:completed]` / `[interview:skipped]`) or emits the `[CONTEXT] INTERVIEW_DONE=1` marker and returns control, do **NOT** churn or pause — **immediately** proceed to 🚨 Mandatory After Interview below. The interview sub-skill has already updated flow state to `create_post_interview` via its Defense-in-Depth section; execute the 🚨 Mandatory After Interview steps without delay.

### 🚨 Mandatory After Interview

> **⚠️ 同 turn 内で必ず実行すること (MUST execute in the SAME response turn)**: `rite:issue:create-interview` の return 直後、**応答を終了せずに** 以下の Step 0 から Step 3 を順に即座に実行する。`[interview:*]` return tag は turn 境界ではなく継続トリガである。turn を閉じた場合、ユーザーの `continue` 介入なしに workflow が停止し、Issue は作成されない (本 Issue #525 の再発条件)。

> **Enforcement**: flow state の `.phase` は `create_post_interview` at this point (the sub-skill wrote this via its Defense-in-Depth section). Stop-guard blocks any stop attempt while the flow-state is active — it will not unblock until flow state の `.phase` advances to `create_delegation` (via the Delegation Routing Pre-write below) or reaches `create_completed` (via the terminal sub-skill). Step 1 below refreshes the state timestamp but does NOT advance the phase on its own — the only legitimate path to a stoppable state is to continue through Phase 0.6 → Delegation Routing → terminal sub-skill. See start.md [Sub-skill Return Protocol (Global)](./start.md#sub-skill-return-protocol-global).

No GitHub Issue has been created yet. The interview only collects information.

**Step 0: Immediate Bash Action (Issue #634)**: Execute this bash block as the **very first tool call** after `rite:issue:create-interview` returns, **before any other tool use or narrative text**. This step replaces the natural turn-boundary point ("the sub-skill finished") with a concrete, non-optional next tool call — the LLM is invoking a bash command, not ending a task. The bash block re-affirms the flow-state phase (idempotent with Step 1) and, on failure only, emits a `[CONTEXT] STEP_0_PATCH_FAILED=1` retained flag to stderr that the LLM can observe in subsequent context (the actual continuation marker `[CONTEXT] INTERVIEW_DONE=1` is produced by the sub-skill *before* Step 0 runs). **stderr observability 前提** (#636 cycle 8 F-07 対応): 本 flag は Claude Code の `ToolUseResult.stderr` として後続 turn の context に流入する — これは `pr/review.md` の `[CONTEXT] LOCAL_SAVE_FAILED=1` / `pr/fix.md` の `[CONTEXT] WM_UPDATE_FAILED=1` 他 40+ 箇所で採用されている repo-wide convention に依拠している。convention 自体が変われば 40+ 箇所すべてを同時改修する必要があるため、ここでは個別に前提明示せず共通 convention として参照する。

```bash
# Verify sub-skill returned with [CONTEXT] INTERVIEW_DONE=1 in recent context
# (grep the conversation context, not a file, so this is informational — the actual
#  continuation is driven by the Pre-flight flow-state write done by the sub-skill).
# Re-affirm phase and refresh timestamp (idempotent with Step 1 below, but Step 0 is
# a concrete tool call that prevents LLM implicit stop).
#
# Exit code を明示 check して silent failure を防ぐ (verified-review F-03 / #636)。
# --if-exists は「file 不在 skip」と「patch 成功」を両方 exit 0 で返すため、
# 真の patch 失敗 (disk full / permission denied 等) のみを区別して STEP_0_PATCH_FAILED
# として emit する。Step 1 は idempotent patch として redundant に実行されるため、
# Step 0 の失敗自体は非 blocking (defense-in-depth の 2 重化は維持される)。
# verified-review cycle 3 F-01 / #636: --preserve-error-count は同一 phase への self-patch で
# stop-guard.sh の RE-ENTRY DETECTED escalation counter を保持するために必須。未指定だと
# flow-state-update.sh patch mode の JQ_FILTER が `.error_count = 0` でリセットし、
# error_count >= 1 escalation と THRESHOLD=3 bail-out 層が永久に fire しなくなる (実測確認済み)。
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_post_interview" \
    --active true \
    --next "Step 0 Immediate Bash Action fired; proceeding to Phase 0.6. Do NOT stop." \
    --if-exists \
    --preserve-error-count; then
  echo "[CONTEXT] STEP_0_PATCH_FAILED=1" >&2
  # 非 blocking: Step 1 が idempotent patch として再試行する。ここで exit 1 すると
  # 既に進捗している workflow を kill してしまうため、warning のみで continue する。
  # 本 flag は stop-guard.sh create_post_interview case arm の HINT で grep 参照される
  # (verified-review cycle 2 F-05 / #636): dead marker ではなく LLM post-hoc 観察用の
  # retained flag。検出時は Step 1 の redundant patch が primary 防御層になる。
fi
```

> **Rationale (Issue #634)**: The regression pattern observed in #552/#561/#622/#628 is that the LLM, after seeing the sub-skill's HTML-comment sentinel (`<!-- [interview:skipped] -->` or `<!-- [interview:completed] -->`), perceives the work as "complete" and ends the turn. Step 0 inserts a **concrete bash tool invocation** as the first required action after the sub-skill returns, eliminating the turn-boundary signal. The LLM sees "I need to run this bash first" instead of "I'm done". Step 0 is redundant with Step 1 (patch mode is idempotent) — the redundancy IS the defense.
>
> **Issue #651 補強 (stop-guard 経由再入は正規 fallback path)**: 以下の 3 観点に分解して記載する (1 段落 packing による可読性低下を避けるため、Issue #651 PR #654 review F-09 で sub-bullet 化):
>
> - **(a) 機構**: Step 0 (および Step 1) が同 turn 内で fire せず implicit stop に至った場合でも、flow state の `.phase = create_post_interview` (Pre-flight + Return Output re-patch で記録済み) により **`stop-guard.sh` の `create_post_interview` case arm が exit 2 で stop を block** する。stderr には WORKFLOW_HINT (本 Step 0 と同一の bash literal を含む) と `[CONTEXT] WORKFLOW_INCIDENT=1; type=manual_fallback_adopted` sentinel が emit される。Step 0 → Step 1 → stop-guard exit 2 経由再入 という 3 層の defense が機能し、いずれか 1 層で sub-skill return 後の continuation が enforced される。
> - **(b) 実証根拠**: **類似経路の実証根拠** として、Issue #634 修正セッション (2026-04-21) の `.rite-stop-guard-diag.log` で `EXIT:2 reason=blocking phase=phase5_post_review` が複数件記録されている。**注意**: 本 phase 名は `phase5_post_review` (pr/review.md の review-fix loop 文脈) であり、本 Step 0 の `create_post_interview` (issue/create flow 文脈) とは異なる。同 case arm pattern (`stop-guard.sh case arm + exit 2 + WORKFLOW_HINT emit`) を共有する**類比的実証**であり、`create_post_interview` 自体の直接ログではない。両者は同型実装のため等価動作を期待できる。
> - **(c) Claude Code UI 限界**: Stop hook の UI 上は exit 2 後でも `Churned for X` 表示が出る場合があり、ユーザーが「`continue` 手動入力が必要」と認識する余地がある (技術的には自動継続している)。本 Issue #651 では declarative 強化路線で 4-site 対称化 (本 Step 0 + Pre-flight + Return Output re-patch + stop-guard WORKFLOW_HINT) を維持・強化することで、いずれの経路でも同一 bash literal が caller に提示されるよう保証する。
>
> **DRIFT-CHECK ANCHOR (semantic, 4-site)** — 本 Step 0 bash block は 4 site 対称契約に属する。bash 引数 (`--phase` / `--active` / `--next` / `--preserve-error-count`) symmetry / `--if-exists` の意図的非対称性 / path 表現の意図的非対称性 / pair 同期契約 / 関連 Issue history (#525 / #552 / #561 / #622 / #634 / #636 / #651 / #660 / #771 / #773) の **正規定義は [`references/sub-skill-handoff-contract.md`](./references/sub-skill-handoff-contract.md)** を参照。各 site (本 Step 0 / `create-interview.md` Pre-flight / Return Output re-patch / `stop-guard.sh` WORKFLOW_HINT) の更新時は本 reference の Overview 表で該当 site を確認し、4 引数 symmetry が破壊されていないかを `hooks/tests/4-site-symmetry.test.sh` で検証する。

**Step 1**: Update flow state to post-interview phase (atomic). The sub-skill has already written `create_post_interview` via its Defense-in-Depth section; this second write refreshes the timestamp and `next_action`. `--if-exists` を付与することで、flow state file 不在時 (Pre-flight 漏れ経路) は silent skip し、create-interview.md Pre-flight が create mode で file 生成する先着性を defeat しない。file 存在時は Step 0 と Step 1 が 2 重 patch を行い、同時失敗のみ `[CONTEXT] STEP_1_PATCH_FAILED=1` として retained flag を残す (Pre-flight 漏れ経路は stop-guard の create_interview case arm で間接検出される)。`--preserve-error-count` も Step 0 と対称に付与 — これがないと RE-ENTRY DETECTED escalation + THRESHOLD bail-out が永久に unreachable になる (verified-review cycle 3 F-01 / #636):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_post_interview" \
    --active true \
    --next "rite:issue:create-interview completed. Proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
    --if-exists \
    --preserve-error-count; then
  echo "[CONTEXT] STEP_1_PATCH_FAILED=1" >&2
  # 非 blocking: Step 0 / Step 1 同時失敗の persistent 障害シグナルを LLM が post-hoc で
  # 観察可能にする。create-interview.md Pre-flight 側の patch が primary 防御層として残る。
fi
```

**Step 2 (Issue #552 — mandatory continuation step)**: Run the Pre-check list at the top of this document (section "Pre-check list"). If any item is `NO`, do NOT end the turn — continue to Phase 0.6 evaluation.

**Step 3**: **→ Proceed to Phase 0.6 (Task Decomposition Decision) now. Do NOT stop.**

> **Issue #552 reminder**: The return tag `[interview:skipped]` / `[interview:completed]` is a **continuation trigger**, not a turn boundary. Ending the turn here is a **protocol violation** — the stop-guard hook will emit a workflow incident (`type=manual_fallback_adopted` or equivalent) if implicit stop is detected.

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

**Pre-write** (before invoking delegation sub-skill): Update flow state so stop-guard can prevent interruptions:

```bash
# state file の正しい path を解決 (schema_version=2 は per-session file、
# legacy は single-file 形式)。helper が空文字列を返す異常ケースは create branch に進む。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  # Preserve existing fields (issue_number, branch, etc.) from caller
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_delegation" \
    --active true \
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

> **⚠️ 同 turn 内で必ず実行すること (MUST execute in the SAME response turn)**: delegation sub-skill の return 直後、**応答を終了せずに** 以下の self-check と Step 1-3 を即座に実行する。Terminal sub-skill は通常 `[create:completed:{N}]` を出力して完了するが、万一出力が欠落した場合は本セクションが唯一のリカバリ経路である。

> **Enforcement**: Terminal sub-skills (`create-register.md`, `create-decompose.md`) write `create_completed` + `active: false` and output `[create:completed:{N}]` internally (Issue #444 Terminal Completion pattern). See start.md [Sub-skill Return Protocol (Global)](./start.md#sub-skill-return-protocol-global).

**Self-check and branching**:

1. **Has `[create:completed:{N}]` been output?**
   - **Yes** — terminal state reached. flow state の `.phase` は既に `create_completed`、`active: false`。Steps 1-3 below are **no-ops** and MUST be skipped (executing Step 1 would write `create_post_delegation` which is a retrograde transition from the terminal state).
   - **No** — the sub-skill failed to complete its Terminal Completion phase. Steps 1-3 below are **critical** and must execute to force the workflow into the terminal state.

**Step 1**: Update flow state to post-delegation phase (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_post_delegation" \
  --active true \
  --next "Sub-skill completed. Deactivate flow state and output next steps. Do NOT stop."
```

**Step 2**: Deactivate flow state (idempotent — safe to re-execute if already deactivated by sub-skill):

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_completed" \
  --next "none" --active false
```

**Step 3 (conditional defense-in-depth)**: Output user-facing completion message, next steps, and HTML-commented sentinel **only if the terminal sub-skill did NOT emit them**. In the Normal path the terminal sub-skill (`create-register` Phase 4.2-4.4 / `create-decompose` Phase 1.0.2-1.0.3) already outputs the full terminal sequence, so this Step 3 is typically a **no-op**. Execute only when the self-check detected missing output:

- **Register 経路** (single Issue created via `create-register`): if the sub-skill's completion message `✅ Issue #{N} を作成しました: {url}` is missing, output the fallback form (matching `create-register.md` Phase 4 Concrete output example):
  ```
  ✅ Issue #{number} を作成しました

  次のステップ:
  1. `/rite:issue:start {number}` で作業を開始
  2. 作業完了後 `/rite:pr:create` で PR 作成

  <!-- [create:completed:{number}] -->
  ```
- **Decompose 経路** (parent + sub-Issues via `create-decompose`): if the sub-skill's completion message `✅ Issue #{parent} を分解して {count} 件の Sub-Issue を作成しました: {url}` is missing, output the fallback form (matching `create-decompose.md` Phase 1.0 Concrete output example):
  ```
  ✅ Issue #{parent_number} を分解して {count} 件の Sub-Issue を作成しました

  次のステップ:
  1. `/rite:issue:start #{first_sub_issue}` で最初の Sub-Issue から作業開始
  2. `/rite:issue:list` で Sub-Issue 一覧を確認

  <!-- [create:completed:{first_sub_issue}] -->
  ```

Where `{number}` / `{parent_number}` / `{first_sub_issue}` / `{count}` are extracted from the sub-skill's result pattern and work memory.

> **Issue #552 / #561 reminder**: `[create:completed:{N}]` sentinel marker is for hooks/scripts and **always** remains in the output as the absolute last line wrapped in an HTML comment (`<!-- [create:completed:{N}] -->`). The user-facing `✅` completion message + next-steps block is the last user-visible content; the HTML-commented sentinel appears after it (invisible in rendered views, grep-matchable). Terminal sub-skills emit all three in the correct order — this Step 3 only fires as defense-in-depth when that output path failed.

**Step 4 (terminal gate)**: Run the Pre-check list (top of this document) one final time in **場面 (b) mode** — **Item 1-3 すべて MUST be `YES`** (Item 0 は routing dispatcher で集計対象外)。Termination conditions:

- 場面 (b) Item 2 が `NO` のまま Step 3 を実行しても still `NO` → loop 防止のため **manual 停止** し、stop-guard 経由で `workflow_incident` を emit させる (sub-skill / orchestrator 双方で完了メッセージ出力が失敗した異常経路)
- それ以外 (Item 1-3 全 `YES`) → Stop is allowed after cleanup.

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
