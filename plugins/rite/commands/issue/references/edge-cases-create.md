# Edge Cases — `/rite:issue:create` Workflow

> **Source of Truth**: 本ファイルは `/rite:issue:create` workflow の 4 つの Edge Case (EDGE-2 / EDGE-3 / EDGE-4 / EDGE-5) の正規定義 SoT である。各 caller (`create.md` / `create-interview.md` / `create-decompose.md` / `create-register.md`) からは本 reference へ semantic 参照する。
>
> **抽出経緯**: Issue #773 (#768 P1-3 PR 3/8) で `create.md` 内の EDGE-3 / EDGE-4 と `create-interview.md` 内の EDGE-2 / EDGE-5 を本 reference に集約。元ファイルには見出しと redirect notice のみ stub 残置 (歴史的アンカー保持 + caller 内ナビゲーション維持)。caller の機能リンクは本ファイルのアンカー (`#edge-2-...` 等) へ書き換え済み。

## EDGE-2: Re-entry After Exit Confirmation

When the user selects "ない、この内容で進めてください" or "残りの詳細は任せる", the interview normally proceeds to Phase 0.6. However, if **new information emerges** after the exit confirmation (e.g., user realizes they forgot to mention something), allow re-entry:

**Re-entry trigger**: After the exit confirmation, if the user provides additional input that contains new requirements or corrections, present the re-entry dialog. Detection criteria:

| Criterion | Examples | Result |
|-----------|----------|--------|
| Contains specific technical terms or proper nouns not previously mentioned | "Redis キャッシュも必要", "OAuth2 対応を追加" | New information |
| Contains requirement verbs (追加, 変更, 削除, 対応, 修正, add, change, remove, support) | "エラーハンドリングを追加したい" | New information |
| Input is 5 or more words/tokens | "認証フローにMFAサポートを追加してほしい" | New information |
| Simple acknowledgment or confirmation | "OK", "了解", "ありがとう", "はい", "Sure", "Thanks" | NOT new information (proceed to Phase 0.6) |
| Single-word response without context | "いいね", "Good", "完璧" | NOT new information (proceed to Phase 0.6) |

If the input is detected as new information, present the re-entry dialog:

Select the template based on the `language` setting (see [Language-Aware Template Selection](../create.md#language-aware-template-selection)):

**Japanese** (`ja` or `auto` with Japanese input):
```
質問: 新しい情報が追加されました。インタビューを再開しますか？

オプション:
- インタビューを再開する（追加情報を深堀り）
- この情報を仕様に追加して先に進む（深堀りなし）
- この情報は無視して先に進む
```

**English** (`en` or `auto` with English input):
```
Question: New information was provided. Would you like to resume the interview?

Options:
- Resume the interview (explore the new information)
- Add this information to the spec and proceed (no deep-dive)
- Ignore this information and proceed
```

**Re-entry behavior**:

| Selection | Action |
|-----------|--------|
| Resume interview | Return to Phase 0.5. Only ask about the new information — do NOT re-ask previously confirmed perspectives |
| Add to spec | Append the new information to the interview results (retained in context for Implementation Contract mapping) and proceed to Phase 0.6 |
| Ignore | Proceed to Phase 0.6 without changes |

**Limit**: Re-entry is allowed **once** per interview session. If the user triggers re-entry a second time, automatically select "Add to spec" behavior and display a message based on the `language` setting:

- **Japanese** (`ja` or `auto` with Japanese input): `再入力は1回までです。新しい情報を仕様に追加して先に進みます。`
- **English** (`en` or `auto` with English input): `Re-entry is limited to once. Adding the new information to the spec and proceeding.`

---

## EDGE-3: Interview Result Reflection Rules

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

## EDGE-4: Short Input Handling

**Execution timing**: This check runs at the beginning of Phase 0.1, before the extraction table below.

Before extraction, check input length. If user input is **less than 10 Unicode characters** (excluding the command name), the input is too short to extract meaningful information:

**Step 1**: Detect short input

Count the number of Unicode characters (not bytes) in the user's input text after stripping whitespace. If fewer than 10 characters, treat as short input.

Examples of short input: "Fix" (3 chars), "Bug" (3 chars), "Update" (6 chars), "リファクタ" (5 chars), "修正" (2 chars)

**Note**: "Excluding the command name" means the text provided as the skill argument (e.g., the `args` parameter of the Skill tool). If the user invoked `/rite:issue:create "Fix"`, the input to check is `"Fix"` (3 characters).

**Step 2**: Request supplementary information via AskUserQuestion

Select the template based on the `language` setting (see [Language-Aware Template Selection](../create.md#language-aware-template-selection)):

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

## EDGE-5: Context Window Pressure Mitigation

Before starting the interview, estimate context pressure using the following heuristics:

| Heuristic | Threshold | Indicator |
|-----------|-----------|-----------|
| Tool calls in conversation | > 30 | High pressure |
| Total Read lines in conversation | > 3000 | High pressure |
| AskUserQuestion calls so far | > 5 | Moderate pressure |

**Note**: These thresholds are intentionally lower than `start.md` (> 50 / > 5000) because `create.md` runs the interview earlier in its flow and needs to detect pressure sooner to preserve context for Phase 0.6+ processing.

**Pressure level actions:**

| Pressure Level | Trigger | Action |
|---------------|---------|--------|
| **High** | Any High pressure threshold exceeded (Tool calls > 30 OR Read lines > 3000) | Activate auto-shortening mode (see below) |
| **Moderate** | Only Moderate threshold exceeded (AskUserQuestion > 5), no High thresholds | Display warning but continue normal interview. Add a language-appropriate note (see below) |

**Moderate pressure warning message:**

Select the template based on the `language` setting:
- **Japanese** (`ja` or `auto` with Japanese input): `ℹ️ AskUserQuestion の回数が多くなっています。残りの質問を効率的にまとめます。`
- **English** (`en` or `auto` with English input): `ℹ️ The number of AskUserQuestion calls is high. Remaining questions will be consolidated efficiently.`

**When high pressure is detected**, activate **auto-shortening mode**:

1. **Reduce perspectives**: Limit to the top 2 most relevant perspectives (based on interview scope priority)
2. **Batch aggressively**: Combine all remaining questions into a single AskUserQuestion call
3. **Offer early exit**: Present the following option before starting:

Select the template based on the `language` setting (see [Language-Aware Template Selection](../create.md#language-aware-template-selection)):

**Japanese** (`ja` or `auto` with Japanese input):
```
⚠️ Context の残量が少なくなっています。

オプション:
- 短縮モードでインタビューを続行（最重要の視点のみ確認）
- 現在の情報で推定して先に進む（インタビューをスキップ）
- 通常通り続行（context 不足のリスクあり）
```

**English** (`en` or `auto` with English input):
```
⚠️ Context window is running low.

Options:
- Continue interview in shortened mode (confirm only the most important perspectives)
- Continue with estimated plan (skip interview)
- Continue normally (risk of context overflow)
```

**Auto-shortening mode behavior**:

| Aspect | Normal Mode | Auto-Shortening Mode |
|--------|-------------|---------------------|
| Perspectives | All in scope | Top 2 most relevant |
| Questions per perspective | Multiple follow-ups | 1 key question each |
| End confirmation | Standard dialog | Skipped (auto-proceed after questions) |
| Specification detail | Full structured | Condensed bullet points |

**When "Continue with estimated plan" is selected**: AI generates the specification based on available information, marking all inferred details with `（推定）`. Proceed directly to Phase 0.6. Note: Decomposition trigger evaluation in Phase 0.6.1 uses estimated information, so tentative complexity may be less accurate.
