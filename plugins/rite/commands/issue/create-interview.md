---
description: Issue 作成のためのインタビュー実行
---

# /rite:issue:create-interview

Execute the adaptive interview for Issue creation. This sub-command is invoked from `create.md` after Phase 0.4 completes.

**Prerequisites**: Phase 0.1-0.4 have completed in the parent `create.md` flow. The following information is available in conversation context:
- Extracted elements (What/Why/Where/Scope/Constraints) from Phase 0.1
- Goal classification from Phase 0.4
- Tentative slug from Phase 0.1.3

---

## Phase 0.4.1: Adaptive Interview Depth

After Phase 0.4 completes, determine the interview scope for Phase 0.5 based on tentative complexity and task type. This avoids excessive questioning for simple Issues.

### Tentative Complexity Estimation

Estimate tentative complexity from information gathered in Phases 0.1-0.4. This estimation is used for:
1. **Adaptive Interview Depth** (below) — determines which interview perspectives to apply
2. **Task decomposition decision** (Phase 0.6) — XL triggers decomposition

| Tentative Complexity | Criteria | Example |
|---------------------|----------|---------|
| **XS** | Change location is clear, 1 to a few lines of modification | typo fix, constant value change |
| **S** | Content update in a single file, implementation method is uniquely determined | function fix, style adjustment |
| **M** | Multiple files (approx. 2-5 files) or involves one design decision | small feature addition |
| **L** | Multiple files (approx. 6-10 files), requires multiple design decisions | medium-scale feature, design change |
| **XL** | Large-scale change (10+ files) or spans multiple domains, architecture-level design decisions | new system construction, architecture change |

**Notes**:
- In Phase 0.6 decomposition decision, only XL triggers decomposition (L is not subject to decomposition)
- The final complexity (XS/S/M/L/XL) is determined in Phase 1.1 and recorded in the Issue

### Complexity-Based Interview Scope

| Tentative Complexity | Interview Scope | Target Perspectives |
|---------------------|----------------|---------------------|
| **XS** | No deep-dive needed | Skip Phase 0.5 entirely → proceed to Phase 0.6 |
| **S** | Minimal deep-dive | Perspective 1 (Technical Implementation) and 3 (Edge Cases) only |
| **M** | Standard deep-dive | Perspectives 1, 2, 3, 4 (5, 6 only if user-initiated) |
| **L** | Full deep-dive | All 6 perspectives + follow-up questions |
| **XL** | Full + decomposition | All 6 perspectives + set decomposition flag for Phase 0.6 |

### Task Type Presets

Override the complexity-based scope when task type provides a stronger signal:

| Task Type | Detection Method | Interview Override |
|-----------|-----------------|-------------------|
| **Bug Fix** | Phase 0.4 goal = "既存機能のバグ修正" or labels contain `bug` | Phase 0.4 → 0.6 direct (skip deep-dive) |
| **Chore** | Phase 0.4 goal = "その他" with maintenance context (e.g., 依存関係更新, CI修正, リネーム, cleanup, linter設定, ツール更新), or labels contain `chore` | Phase 0.4 → 0.6 direct (skip deep-dive) |
| **Feature** | Phase 0.4 goal = "新機能の追加" | Apply complexity-based scope above |
| **Refactor** | Phase 0.4 goal = "リファクタリング" | Apply complexity-based scope above |
| **Documentation** | Phase 0.4 goal = "ドキュメントの更新" or labels contain `documentation` | Abbreviated Phase 0.5 (perspectives 2, 4, 6 only) |

**Notes**:
- Task type presets take precedence over complexity-based scope
- When task type is ambiguous, fall back to complexity-based scope
- Users can always request additional questions regardless of the determined scope

### Applying the Scope

After determining the interview scope:

1. **If scope is "skip"** (XS, Bug Fix, Chore): Skip Phase 0.5 entirely and proceed to Phase 0.6
2. **If scope is "limited"** (S, Documentation): Enter Phase 0.5 but only ask questions from the specified perspectives
3. **If scope is "standard" or "full"** (M, L, XL): Enter Phase 0.5 with the full interview flow, applying perspective filtering as specified

When entering Phase 0.5 with limited scope, display (select based on `language` setting):

**Japanese** (`ja` or `auto` with Japanese input):
```
複雑度 {complexity} / タスク種別 {task_type} に基づき、以下の視点に絞って確認します:
- {perspective_list}
追加の確認が必要な場合はお知らせください。
```

**English** (`en` or `auto` with English input):
```
Based on complexity {complexity} / task type {task_type}, focusing on the following perspectives:
- {perspective_list}
Let me know if you need additional confirmation.
```

When entering Phase 0.5 with standard or full scope, display:

**Japanese** (`ja` or `auto` with Japanese input):
```
複雑度 {complexity} に基づき、{standard の場合: 標準 / full の場合: フル}の深堀インタビューを実施します。
```

**English** (`en` or `auto` with English input):
```
Based on complexity {complexity}, conducting a {standard: standard / full: full} deep-dive interview.
```

---

## Phase 0.5: Deep-Dive Interview

**Boundary with Phase 0.4**: Phase 0.4 is a **quick confirmation** that fills gaps in basic information (What/Why/Where) and classifies the task type — it should complete in 0-1 AskUserQuestion calls. Phase 0.5 is a **deep-dive interview** that explores implementation details across multiple perspectives — it may require multiple rounds of questions depending on complexity.

**Purpose**: Clarify the details needed for implementation, not just surface-level requirements. Avoid asking obvious questions; focus on points where decisions diverge or aspects easily overlooked.

**Prerequisite**: Check the interview scope determined in Phase 0.4.1. If the scope is "skip", do not execute this phase. If the scope specifies limited perspectives, only ask questions from those perspectives.

#### EDGE-5: Context Window Pressure Mitigation

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

Select the template based on the `language` setting (see [Language-Aware Template Selection](./create.md#language-aware-template-selection)):

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

---

> **Important**: Read the user's request and use the AskUserQuestion tool to conduct a detailed interview. Ask questions from the perspectives determined in Phase 0.4.1 (interview scope). Continue until the user explicitly states "no more points to confirm". Then write the final specifications to the Issue.
>
> **Note**: See the "Quality Standards for Questions" section below for quality criteria. When in doubt, ask. There is no harm in asking too many questions.

### Basic Interview Guidelines

**Principle of Continuous Interviewing**:

- **Continue until the user explicitly ends the interview**
- Confirm perspectives included in the interview scope from Phase 0.4.1, and do not end until the user explicitly says "leave the details to you" or "I want to skip"
- Do not end the interview based solely on AI judgment that "enough information has been gathered" (canonical rule: see [Termination Logic > Phase 0.5](#phase-05-interview-termination))
- Dig deep into each perspective and ask follow-up questions derived from answers

**Quality Standards for Questions**:
- Avoid questions that are too obvious (can be answered immediately with Yes/No, have only one possible answer)
- Prioritize questions where multiple options exist with tradeoffs
- Actively confirm edge cases and concerns that are easily overlooked

### Tentative Complexity

The tentative complexity was estimated in Phase 0.4.1. Refer to the "Tentative Complexity Estimation" section there for criteria and the complexity table. The estimated value drives the interview scope (Phase 0.4.1) and the task decomposition decision (Phase 0.6).

### Interview Perspectives

**Filtering rule**: Apply the interview scope from Phase 0.4.1. Only ask questions from perspectives included in the determined scope. For perspectives outside the scope, skip them silently unless the user explicitly requests them.

> **Template reference**: Read `{plugin_root}/templates/issue/interview-perspectives.md` for the full perspective definitions, confirmation conditions, and question templates.

### Interview Flow

1. **First question**: Start with the most important decision point
2. **Deep-dive based on answers**: Ask follow-up questions derived from answers
3. **End confirmation**: **After confirming all applicable perspectives**, present the end confirmation dialog (see [Termination Logic > Phase 0.5](#phase-05-interview-termination))
4. **Specification summary**: When the user answers "no", reflect the interview results in the Issue body

**End confirmation question format**:
```
質問: 他に確認したい点はありますか？

オプション:
- ある（追加の質問・要望を入力）
- ない、この内容で進めてください
- 残りの詳細は任せる
```

#### EDGE-2: Re-entry After Exit Confirmation

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

Select the template based on the `language` setting (see [Language-Aware Template Selection](./create.md#language-aware-template-selection)):

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

### AskUserQuestion Batch Optimization

**Applies to**: This optimization modifies the Interview Flow above. When executing Phase 0.5, apply the batching rules below instead of asking each perspective independently.

**Purpose**: Reduce the number of AskUserQuestion round-trips by grouping related perspectives into batched calls. This minimizes context pressure from multiple small interactions.

#### Batching Rules

Group perspectives into **1-2 AskUserQuestion calls** instead of asking each perspective independently:

| Interview Scope | Batch Strategy | Max AskUserQuestion Calls |
|-----------------|---------------|--------------------------|
| **S** (Perspectives 1, 3) | Single batch: combine Technical + Edge Cases | 1 + follow-ups |
| **M** (Perspectives 1, 2, 3, 4) | Batch 1: Technical + Edge Cases. Batch 2: UX + Consistency | 2 + follow-ups |
| **L/XL** (All 6) | Batch 1: Technical + Edge Cases + NFR. Batch 2: UX + Consistency + Tradeoffs | 2 + follow-ups |
| **Documentation** (Perspectives 2, 4, 6) | Single batch: combine all 3 perspectives | 1 + follow-ups |

#### Batching Technique

Compose a single AskUserQuestion prompt that includes multiple questions in the text body with consolidated options. Use `multiSelect: true` when the user may need to select more than one option:

**Example — S scope (Batch 1: Technical + Edge Cases)**:
```
以下の点について確認させてください:

1. {機能} の実装アプローチはどちらを想定していますか？
2. 以下のエッジケースへの対応は必要ですか？

オプション:
- {アプローチA} / エッジケース対応あり
- {アプローチB} / 正常系のみ
- 詳細を説明するので提案してほしい（番号ごとに個別回答可）
- 判断を任せる
```

> **Note**: When the pre-defined option combinations don't cover the user's intent (e.g., "アプローチA + 正常系のみ"), the user can select "Other" to provide a free-text answer specifying each question independently.

**Example — M scope (Batch 1: Technical + Edge Cases)**:
```
技術的な実装とエッジケースについて確認します:

1. {機能} の実装アプローチ: {A} vs {B}
2. エッジケース対応: {ケース1}, {ケース2}

オプション:
- {アプローチA} / 主要なエッジケースに対応
- {アプローチB} / 正常系のみ
- 要件を説明するので提案してほしい
```

#### Pre-condition Evaluation

Before asking each perspective's questions, evaluate whether the question is necessary based on information already gathered:

| Pre-condition | Action |
|--------------|--------|
| Implementation approach is uniquely determined (only one option) | Skip Technical Implementation question |
| No UI/UX changes involved | Skip UX question |
| Input is well-constrained (enum values, fixed format) | Skip Edge Cases question |
| No existing features affected | Skip Consistency question |
| No performance/security concerns | Skip NFR question (unless L/XL) |

**Important**: Pre-condition evaluation reduces questions within a batch, but does NOT replace user confirmation. If pre-conditions eliminate all questions in a batch, skip that batch entirely.

#### Follow-up Questions

After batch responses, derive follow-up questions from answers. Follow-ups are asked individually (not batched) as they require specific context from prior answers. After **2 rounds** of follow-ups, present the end confirmation dialog. If the user requests additional follow-ups, continue — user judgment is the final decision (consistent with UX-2: No AI auto-termination).

### Deep-Dive Examples

#### Example 1: User Authentication Feature

**Initial input**: "I want to add user authentication"

**Deep-dive question 1**:
```
質問: 認証方式はどれを想定していますか？

オプション:
- メール/パスワード認証
- ソーシャルログイン（Google, GitHub等）
- 両方対応
- 要件を説明するので提案してほしい
```

**Deep-dive question 2** (when the answer is "email/password"):
```
質問: パスワードリセット機能は必要ですか？

オプション:
- 必要（メールでリセットリンク送信）
- 不要（管理者が手動リセット）
- 将来的に必要（今回は対象外）
```

**Deep-dive question 3**:
```
質問: 認証状態の保持期間は？

オプション:
- ブラウザを閉じるまで（セッション）
- 明示的にログアウトするまで（永続）
- 一定期間（例: 7日間）で自動ログアウト
- 要件に応じて提案してほしい
```

#### Example 2: UI Component Addition

**Initial input**: "I want to add a data table component"

**Deep-dive question 1**:
```
質問: テーブルに必要な機能はどれですか？

オプション:
- ソート機能
- フィルタリング機能
- ページネーション
- すべて必要
```

**Deep-dive question 2**:
```
質問: データ量はどの程度を想定していますか？

オプション:
- 少量（100件以下）- 全件クライアント側で処理
- 中量（1000件程度）- 仮想スクロール検討
- 大量（1万件以上）- サーバーサイドページネーション必須
- 不明（要件に応じて提案してほしい）
```

#### Example 3: Refactoring

**Initial input**: "I want to refactor the API client"

**Deep-dive question 1**:
```
質問: リファクタリングの主な目的は？

オプション:
- コードの可読性向上
- テスタビリティの改善
- パフォーマンス改善
- 新機能追加への準備
```

**Deep-dive question 2**:
```
質問: 既存の API 呼び出し箇所への影響は許容しますか？

オプション:
- 破壊的変更 OK（すべて書き換え）
- インターフェースは維持（内部実装のみ変更）
- 段階的移行（新旧並存期間あり）
```

### Interview Termination Conditions

> **Reference**: See [Termination Logic > Phase 0.5 Interview Termination](#phase-05-interview-termination) for the complete termination rules, including the mandatory exit confirmation dialog and AI auto-termination prohibition (UX-2).

### Reflecting Interview Results

Interview results are mapped to Implementation Contract sections (Section 1-9) for the Issue body. The mapping follows Step 3 of the Issue Body Generation process in `create-register.md`:

| Interview Perspective | Target Sections |
|----------------------|----------------|
| Technical Implementation | 4.1 Target Files, 4.3 Interface/Data Contract, 4.4 Behavioral Requirements |
| User Experience | 1 Goal, 3 Type Core (Feature scenarios), 5 AC (Happy Path) |
| Edge Cases | 5 AC (Boundary/Error), 6 Test Specification |
| Existing Feature Impact | 2 Scope (Out), 4.2 Non-Target, 4.4 MUST NOT |
| Non-Functional Requirements | 4.5 Error/Constraints, 5 AC (NFR outcome), 6 Test Specification |
| Tradeoffs | 1 Non-goal, 4.4 SHOULD/MAY, 9 Decision Log |

**Note**: This mapping is applied during Issue body generation in `create-register.md` Phase 2.2 (Step 3). Phase 0.5 collects and retains the raw interview results in conversation context; the structured mapping to Implementation Contract sections occurs at generation time.

**Retention format** (in conversation context, not in Issue body):

```json
{
  "interview_results": {
    "technical_implementation": ["認証方式: JWT ベース", "トークン保存: HttpOnly Cookie"],
    "user_experience": ["ログイン失敗時: エラーメッセージを表示"],
    "edge_cases": ["同一アカウントの複数デバイスログイン: 許可"],
    "existing_feature_impact": [],
    "non_functional_requirements": ["セッション期間: 7日間"],
    "tradeoffs": ["ソーシャルログイン: スコープ外"]
  }
}
```

---

## Termination Logic

### Phase 0.5 Interview Termination

> **UX-2: Exit Condition Enforcement**

**Mandatory exit confirmation dialog**: After confirming all applicable perspectives (determined by Phase 0.4.1 interview scope), the end confirmation dialog **MUST always be presented**. This is not optional.

**Rules**:

| Rule | Description |
|------|-------------|
| **Always present end confirmation** | After covering all perspectives in scope, always present the end confirmation dialog — no exceptions |
| **No AI auto-termination** | Do NOT end the interview based on AI judgment that "enough information has been gathered". Only the user decides when the interview is complete |
| **Skip only by user request** | The interview can only be skipped when the user explicitly selects "skip" or equivalent |
| **Scope-based behavior** | The interview scope from Phase 0.4.1 determines which perspectives to cover before presenting the exit dialog |

**Scope-specific termination**:

| Interview Scope | Termination Rule |
|----------------|-----------------|
| **Skip** (XS, Bug Fix, Chore) | Phase 0.5 is not entered; no termination needed |
| **Limited** (S, Documentation) | After confirming all specified perspectives, present the end confirmation dialog. If user confirms no additional points, proceed to Phase 0.6 |
| **Standard** (M) | After confirming perspectives 1-4, present the end confirmation dialog. Continue if user has more to add |
| **Full** (L, XL) | After confirming all 6 perspectives, present the end confirmation dialog. Continue until user explicitly ends |

**End confirmation dialog format**: Use the dialog template defined in the [Interview Flow > End confirmation question format](#interview-flow) section (mandatory after all applicable perspectives are covered).

---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0).

Before returning control to the caller, update `.rite-flow-state` to the post-interview phase. This ensures the stop-guard routes correctly even if the caller's 🚨 Mandatory After section is not executed immediately:

```bash
if [ -f ".rite-flow-state" ]; then
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_post_interview" \
    --next "rite:issue:create-interview completed. Proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
else
  bash {plugin_root}/hooks/flow-state-update.sh create \
    --phase "create_post_interview" --issue 0 --branch "" --loop 0 --pr 0 \
    --session {session_id} \
    --next "rite:issue:create-interview completed. Proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
fi
```

After the flow-state update above, output the appropriate result pattern:

- **Interview completed**: `[interview:completed]`
- **Interview skipped** (XS, Bug Fix, Chore): `[interview:skipped]`

This pattern is consumed by the orchestrator (`create.md`) to determine the next action.

---

## 🚨 Caller Return Protocol

When this sub-skill completes (interview finished or skipped), control **MUST** return to the caller (`create.md`). The caller (`create.md`) **MUST immediately** execute its 🚨 Mandatory After Interview section:

1. Proceed to Phase 0.6 (Task Decomposition Decision)

**WARNING**: **No GitHub Issue has been created yet.** No GitHub Issue exists at this point. The interview only collected information — creation happens in `create-register.md` or `create-decompose.md`. Stopping here would completely abandon the workflow with no Issue created.

**Concrete next action for caller**: Evaluate decomposition triggers (Phase 0.6.1), then delegate to `rite:issue:create-register` (single Issue) or `rite:issue:create-decompose` (sub-Issue decomposition).

**→ Return to `create.md` and proceed to Phase 0.6 now. Do NOT stop.**
