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

## 🚨 MANDATORY Pre-flight: Flow State Update (MUST execute FIRST)

> **Issue #622 (regression of #552)**: This section was historically placed at the end of the file (titled "Defense-in-Depth: Flow State Update (Before Return)"). In the Bug Fix / Chore preset path (Phase 0.4.1 → skip Phase 0.5), the LLM running this sub-skill sometimes skipped the Defense-in-Depth bash block and jumped directly to the return output. The result: `.rite-flow-state.phase` stayed at `create_interview`, which had no dedicated `stop-guard.sh` case arm in versions prior to #622 fix, so the orchestrator's implicit stop after `<!-- [interview:skipped] -->` was not blocked and the user had to type `continue` manually. Moving the flow-state write to the **absolute beginning** of the sub-skill guarantees it runs regardless of interview scope.
>
> **DRIFT-CHECK ANCHOR (semantic)**: This section is mirrored by `stop-guard.sh` `create_interview` case arm (Issue #622) and `phase-transition-whitelist.sh` `create_interview → create_post_interview` edge. The three sites form a 3-site symmetry — when updating any one, update the others.
>
> **DRIFT-CHECK ANCHOR (semantic, bash 引数 symmetry)** — F-06 / #636: 本 Pre-flight bash block の引数 (`--phase`, `--next`, `--preserve-error-count`) は `create.md` 🚨 Mandatory After Interview **Step 0 Immediate Bash Action** および **Step 1** (両方の patch mode call に `--preserve-error-count` を含む) と symmetry を取る必要がある。`create.md` の **DRIFT-CHECK ANCHOR (semantic)** 節 (Step 0 Rationale 直後) から本セクションへの逆参照であり、create.md 側と本 Pre-flight の bash 引数のいずれかが崩れると error_count reset loop (cycle 3 F-01 / cycle 4 F-01/F-02) が再発する。本セクションの Return Output 直前 re-patch (Return Output Format section) も同一 contract に属する。

**MUST run before any interview logic** (Phase 0.4.1 scope evaluation, Phase 0.5 deep-dive, or return-output emission). This bash block is **not optional** and **not conditional on interview scope**. Execute it even when Phase 0.4.1 determines the Bug Fix / Chore preset (interview scope = "skip"):

```bash
# verified-review cycle 3 F-06 / #636: Pre-flight は create.md コメントで「primary 防御層」と
# 位置付けられており、Step 0/Step 1 と同格の idempotent write。exit-code check を対称に
# 入れることで persistent な disk full / permission denied 障害下でも silent に通過せず、
# [CONTEXT] PREFLIGHT_PATCH_FAILED=1 retained flag を残す。layered defense は
# stop-guard の create_interview case arm が routing する safety net がある。
#
# verified-review cycle 4 F-01 / #636: --preserve-error-count を create.md Step 0/Step 1 と
# 対称に付与。本 Pre-flight bash block は sub-skill 再入時に同一 phase self-patch
# (create_post_interview → create_post_interview) となるため、flag がないと
# flow-state-update.sh patch mode の JQ_FILTER が `.error_count = 0` でリセットし、
# stop-guard.sh の RE-ENTRY DETECTED escalation + THRESHOLD=3 bail-out 層が永久に fire しない。
# create mode (file 不在時の初回書き込み) は phase transition ではないため flag は実質 no-op
# だが、drift 防止の consistency で対称に付与する。
if [ -f ".rite-flow-state" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "create_post_interview" \
      --next "rite:issue:create-interview Pre-flight completed. Proceed to Phase 0.4.1/0.5 if applicable, then return to caller. Caller MUST proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_PATCH_FAILED=1" >&2
    # 非 blocking: create.md Step 0/Step 1 の redundant patch が 2 段目防御として存在し、
    # stop-guard の create_interview case arm が routing する safety net でも間接検出される。
  fi
else
  if ! bash {plugin_root}/hooks/flow-state-update.sh create \
      --phase "create_post_interview" --issue 0 --branch "" --pr 0 \
      --next "rite:issue:create-interview Pre-flight completed. Proceed to Phase 0.4.1/0.5 if applicable, then return to caller. Caller MUST proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_CREATE_FAILED=1" >&2
  fi
fi
```

**Why `create_post_interview` (not `create_interview_running`) at Pre-flight time**: The caller (`create.md` Delegation to Interview Pre-write) has already written `create_interview` to signal that delegation is in flight. The Pre-flight advances the phase to `create_post_interview` **before** the interview runs so that, no matter at which point the sub-skill exits (normal completion, early exit via Bug Fix preset, or unexpected stop), the stop-guard routes to the `create_post_interview` WORKFLOW_HINT which correctly tells the orchestrator to run the 🚨 Mandatory After Interview section and proceed to Phase 0.6. This is safe because `create_post_interview → create_delegation` is the only whitelisted forward transition — the orchestrator must still execute Delegation Routing to advance past it.

**Idempotence**: Running this multiple times within a single sub-skill invocation is safe; each call refreshes the timestamp and `next_action` but does not regress the phase (patch mode sets `previous_phase` from the pre-update `.phase`, which stays `create_post_interview` on re-entry).

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

## Return Output Format (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0). The flow-state write was moved to the 🚨 MANDATORY Pre-flight section at the top of this file (Issue #622) so the post-interview phase is recorded regardless of interview scope. The idempotent re-patch below is retained as a defense-in-depth second write that refreshes the timestamp and `next_action` immediately before emitting the return output.

Immediately before emitting the four-line return block, re-patch `.rite-flow-state` to refresh the timestamp. This is idempotent with the 🚨 MANDATORY Pre-flight write (same phase, same transition target):

```bash
# verified-review cycle 3 F-06 / #636: Return Output 直前 re-patch も Step 0/Step 1 と対称に
# exit-code check を追加。primary Pre-flight 防御層の補強として silent failure を surface する。
#
# verified-review cycle 4 F-02 / #636: --preserve-error-count を create.md Step 0/Step 1 と
# 対称に付与。本 re-patch は Pre-flight 後の確定的な同一 phase self-patch であり、
# flag がないと sub-skill mid-execution で本 re-patch 通過時に error_count が 0 にリセットされ、
# 直後の orchestrator implicit stop で escalation が再度 ERROR_COUNT=0 から始まり永久に
# THRESHOLD bail-out 未到達。Pre-flight (F-01) と対称。
if [ -f ".rite-flow-state" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "create_post_interview" \
      --next "rite:issue:create-interview completed. Proceed to Phase 0.6 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] INTERVIEW_RETURN_PATCH_FAILED=1" >&2
    # 非 blocking: create.md Step 0/Step 1 の redundant patch が続行する。
  fi
fi
```

> **Why patch mode only (no create fallback here)**: The 🚨 MANDATORY Pre-flight section at the top already handles the "file missing" branch (`create` mode). By the time execution reaches the return-output section, `.rite-flow-state` is guaranteed to exist with `.phase = create_post_interview`. A second `create` call here would reset `previous_phase` to an empty string and defeat the whitelist-based transition check in stop-guard — patch mode preserves the transition chain correctly.

After the flow-state update above, output the appropriate result pattern. Emit the caller-continuation reminder **immediately before** the result pattern. The return block MUST be composed of four lines in the order below: (1) `[CONTEXT] INTERVIEW_DONE=1` grep marker, (2) plain-text blockquote continuation reminder, (3) HTML-commented caller instructions, (4) HTML-commented result sentinel. All four MUST be the last visible lines of this sub-skill's output.

> **Issue #552 enhancement**: The caller continuation hint is emitted as **both** a plain-text line (visible in rendered Markdown) **and** an HTML comment (visible only in the LLM's raw context). The dual form ensures the reminder is robust against rendering modes where HTML comments are stripped before the LLM sees them. Rewriting this to HTML-comment-only is a regression.
>
> **Issue #561 UX fix**: The result pattern (`[interview:skipped]` / `[interview:completed]`) is now emitted as an HTML comment (`<!-- [interview:skipped] -->`). The string `[interview:skipped]` / `[interview:completed]` inside the HTML comment is still grep-matchable (`grep -F '[interview:'`) so the orchestrator's Pre-check Item 0 (routing dispatcher) and any hook/test contract remain intact (AC-3). The HTML comment form prevents the sentinel token from being the user-visible final line, weakening the LLM's turn-boundary heuristic that previously caused premature `continue`-requiring stops.
>
> **Issue #634 enhancement**: `[CONTEXT] INTERVIEW_DONE=1` marker is added as the FIRST line of the return block (not the last). This establishes a grep-detectable signal `INTERVIEW_DONE=1` that the orchestrator's Pre-check list Item 0 and Mandatory After Interview Step 0 both consume. Placing the marker FIRST (not last) means the sub-skill's last line remains the sentinel HTML comment (preserving #561 ordering), while the context grep can still find `INTERVIEW_DONE=1` anywhere in recent context. The marker is a plain-text line (not HTML-commented) because Pre-check Item 0 uses context grep which may strip HTML comments in some rendering modes. DRIFT-CHECK ANCHOR (semantic, 4-site): create.md 🚨 Mandatory After Interview Step 0 Immediate Bash Action / create-interview.md 🚨 MANDATORY Pre-flight / create-interview.md Return Output re-patch (本セクション末尾) / stop-guard.sh create_post_interview case arm WORKFLOW_HINT と **4 site 対称** (Issue #651 PR #654 cycle 2 review F-NEW1 で 3-site → 4-site 拡張、本セクション末尾の DRIFT-CHECK ANCHOR (semantic, 4-site) と同一 scope)。

**Output format example (interview skipped)**:

```
[CONTEXT] INTERVIEW_DONE=1; scope=skipped; next=phase_0_6
> ⏭ 継続中: Phase 0.6 → Delegation Routing → terminal sub-skill (Issue 未作成、自動継続します)
<!-- caller: IMMEDIATELY run this as your next tool call (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 0.6. Do NOT stop.' --if-exists --preserve-error-count` THEN (after the bash command above succeeds) continue with Phase 0.6 (Task Decomposition Decision) in the SAME response turn. DO NOT stop. No GitHub Issue has been created yet. -->
<!-- [interview:skipped] -->
```

**Output format example (interview completed)**:

```
[CONTEXT] INTERVIEW_DONE=1; scope=completed; next=phase_0_6
> ⏭ 継続中: Phase 0.6 → Delegation Routing → terminal sub-skill (Issue 未作成、自動継続します)
<!-- caller: IMMEDIATELY run this as your next tool call (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 0.6. Do NOT stop.' --if-exists --preserve-error-count` THEN (after the bash command above succeeds) continue with Phase 0.6 (Task Decomposition Decision) in the SAME response turn. DO NOT stop. No GitHub Issue has been created yet. -->
<!-- [interview:completed] -->
```

> **Issue #651 enhancement (4-site 対称化、syntax-safe inline bash command)**: caller HTML コメントに Step 0 Immediate Bash Action の bash command literal を **backtick で明示的に区切って** inline で含めることで、orchestrator が次に実行すべき具体的な tool call を sub-skill 出力直後に視認できるようにする。`bash ... --preserve-error-count` までを backtick で囲い、その後を散文 `THEN (after the bash command above succeeds) continue with Phase 0.6 ...` で続けることで、LLM が caller HTML コメントを literal 解釈しても **bash 構文として valid な単一コマンド** として実行可能になる (旧版 `; then continue with Phase 0.6` は `if cmd; then ... fi` 構文の一部と誤解釈されて syntax error になる問題を修正、Issue #651 PR #654 review F-01)。bash 引数 (`--phase create_post_interview` / `--if-exists` / `--preserve-error-count`) は **create.md Mandatory After Interview Step 0 Immediate Bash Action** / **Pre-flight (本ファイル冒頭)** / **Return Output re-patch (本セクション直前)** / **stop-guard.sh `create_post_interview` case arm WORKFLOW_HINT bash literal** と **4-site 対称**。
>
> **`--if-exists` の非対称性** (時系列で説明): orchestrator が caller HTML コメントの bash command を実行する時点では、本 sub-skill (create-interview.md) の Pre-flight が既に完了しており `.rite-flow-state` の存在は保証されている → よって `--if-exists` は no-op safety net として無害に働く。一方 create-interview.md の Pre-flight / Return Output re-patch は **file 不在時に `create` mode で新規生成する 2 経路分岐** を持つため `if [ -f ".rite-flow-state" ]; then ... else ... fi` 形式で明示処理 (意図的非対称、本 inline bash literal は orchestrator-side 実行想定)。
>
> **DRIFT-CHECK ANCHOR (semantic, 4-site)** — Issue #651: 本 caller HTML コメント内 bash literal は (1) create.md 🚨 Mandatory After Interview Step 0 / (2) create-interview.md 🚨 MANDATORY Pre-flight / (3) create-interview.md Return Output re-patch (本セクション直前) / (4) stop-guard.sh `create_post_interview` case arm WORKFLOW_HINT と **4-site 対称**。bash 引数 symmetry (`--phase` / `--if-exists` / `--preserve-error-count`) は #636 cycle 3 F-01 の error_count reset loop 防止規約に従う。`--next` 文字列は HINT/canonical で異なる (Step 0 fired vs continue caller) が動作影響なし。
>
> **2 site 内対称性 (skipped/completed paths)**: 本ファイル内の `[interview:skipped]` (line 586 周辺) と `[interview:completed]` (line 595 周辺) の両 example で同一 bash literal を保持する必要がある。片方のみの更新は drift とみなされ、TC-651-B の 2-site count 検証で fail する (PR #654 review F-05 / F-08)。

> **Plain-text form rationale**: 短く user-friendly な Markdown blockquote (`> ⏭ 継続中:`) にすることで (a) rendered Markdown で視覚的に「自動継続中」の文脈が明確、(b) HTML コメント (LLM 向け詳細) との責任分担が明確。詳細な caller 向け instruction は HTML コメント側に残し、plain-text 行は user 向けの短い status indicator として機能する。user-visible な最終コンテンツは `⏭ 継続中:` blockquote となり、sentinel token は HTML コメント化されレンダリング時に不可視。

Result patterns (grep-matchable string inside HTML comment):

- **Interview completed**: `<!-- [interview:completed] -->` (matches `grep -F '[interview:completed]'`)
- **Interview skipped** (XS, Bug Fix, Chore): `<!-- [interview:skipped] -->` (matches `grep -F '[interview:skipped]'`)

This pattern is consumed by the orchestrator (`create.md`) to determine the next action. The plain-text reminder is visible to both the LLM and the human user; the HTML comments hide the caller instructions and sentinel token from the user-visible rendered view while keeping them available to LLM-side grep / context inspection.

---

## 🚨 Caller Return Protocol

When this sub-skill completes (interview finished or skipped), control **MUST** return to the caller (`create.md`). The caller **MUST immediately** execute its 🚨 Mandatory After Interview section — proceeding to Phase 0.6 (Task Decomposition Decision) in the **same response turn**.

**WARNING**: **No GitHub Issue has been created yet.** Stopping here abandons the workflow with no deliverable.

**Output rules**:
0. **FIRST**: Output `[CONTEXT] INTERVIEW_DONE=1; scope={skipped|completed}; next=phase_0_6` as a **plain-text line** (not HTML-commented). Position rules (#636 cycle 8 F-06 — Rule 1 absolute 位置規定との対称化、#636 cycle 9 F-02 — sub-bullet 分解で読解負荷軽減、#636 cycle 10 F-03/F-05 — canonical 規定の明示化 + routing dispatcher 表現の正確化):
   - **0b (構造保証、canonical)**: the relative ordering of Rules 0-1 pins the full block structure as a **4-line return block**: Rule 0 (FIRST) → plain-text continuation reminder → HTML-commented caller instructions → Rule 1 (absolute LAST). This 4-line invariant is the canonical structural rule — all other position descriptions derive from it
   - **0a (絶対位置、0b から導出)**: derived from Rule 0b's 4-line block, this marker is the **4th-to-last visible line** of this sub-skill's output — i.e., 3 lines before the `<!-- [interview:*] -->` absolute-last sentinel defined in Rule 1. Note: this derived position assumes each of the other 3 lines is single-line; if Line 2 (plain-text reminder) or Line 3 (HTML comment) grows to multi-line in the future, Rule 0b's 4-line invariant is broken first and both rules need joint update
   - **0c (目的)**: Issue #634 補強 — grep marker for orchestrator Pre-check Item 0 (routing dispatcher — the marker actively triggers routing at this site) and for Mandatory After Step 0 bash block comment reference (informational — Step 0 itself is an unconditional idempotent `flow-state-update.sh patch` and does not branch on the marker; the marker serves as documentation context); defense-in-depth against LLM turn-boundary heuristics
1. Output the result pattern as an HTML comment (`<!-- [interview:completed] -->` or `<!-- [interview:skipped] -->`) as the **absolute last line** of this sub-skill's output (Issue #561 UX fix — the sentinel is grep-matchable but not user-visible)
2. Do **NOT** emit the sentinel as a bare `[interview:*]` line (without HTML comment wrapping) — the bare form regressed in Issue #561 as the user-visible terminal token
3. Do **NOT** output any narrative text (e.g., `→ Return to create.md`) after the result pattern — it creates a natural stopping point for the LLM
4. The caller reads the result pattern via grep (the HTML comment contains the matchable string, plus the plain-text `[CONTEXT] INTERVIEW_DONE=1` marker) and immediately continues to Phase 0.6
