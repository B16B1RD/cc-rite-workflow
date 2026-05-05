---
description: |
  (Internal sub-skill — invoked by /rite:issue:create only. Do NOT invoke directly.)
  Issue 作成のための適応的インタビューを実行する sub-skill。
  Phase 1 規模感判定 + Phase 1.1 深堀り質問を担当。
---

# /rite:issue:create-interview

Execute the adaptive interview for Issue creation. This sub-command is invoked from `create.md` after Phase 0 (Preconditions) completes.

**Prerequisites**: Phase 0 (Preconditions) has completed in the parent `create.md` flow. The following information is available in conversation context:
- Extracted elements (What/Why/Where/Scope/Constraints) from Phase 0.1
- Goal classification from Phase 0.5
- Tentative slug from [Phase 0.2](./references/slug-generation.md) — generated per [Slug Generation Rules](./references/slug-generation.md#slug-generation-rules)

---

## 🚨 MANDATORY Pre-flight: Flow State Update (MUST execute FIRST)

> 本 Pre-flight は sub-skill の **先頭** で実行し interview scope に関係なく flow-state write を保証する (Bug Fix / Chore preset path でも skip 不可)。末尾配置だと scope=skip path で sub-skill が早期 return し flow-state write が抜けるため、先頭配置が必須。

**MUST run before any interview logic** (Phase 1 scope evaluation / Phase 1.1 deep-dive / return-output emission)。**not optional**、**interview scope に conditional でない** — Bug Fix / Chore preset (scope = "skip") でも実行:

```bash
# bash 引数 / exit-code check / --preserve-error-count rationale は references/sub-skill-handoff-contract.md (canonical SoT)
# に集約。本ブロックは canonical bash 引数 symmetry を保持し、state-path-resolve.sh + _resolve-flow-state-path.sh で
# per-session (schema_version=2) / legacy 両形式に対応。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "create_post_interview" \
      --active true \
      --next "rite:issue:create-interview Pre-flight completed. Proceed to Phase 1/1.1 if applicable, then return to caller. Caller MUST proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_PATCH_FAILED=1" >&2
    # 非 blocking: create.md Step 0/Step 1 の redundant patch + phase-transition-whitelist.sh の create_interview case arm (pre-tool-bash-guard.sh / session-end.sh が source) が safety net。
  fi
else
  if ! bash {plugin_root}/hooks/flow-state-update.sh create \
      --phase "create_post_interview" --issue 0 --branch "" --pr 0 \
      --next "rite:issue:create-interview Pre-flight completed. Proceed to Phase 1/1.1 if applicable, then return to caller. Caller MUST proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] PREFLIGHT_CREATE_FAILED=1" >&2
  fi
fi
```

**Why `create_post_interview` (not `create_interview_running`)**: caller (`create.md` Phase 1 Delegation to Interview Pre-write) は既に `create_interview` を書込済 (delegation in flight signal)。本 Pre-flight が **interview 実行前** に `create_post_interview` へ進めることで、normal completion / Bug Fix preset early exit / unexpected stop のいずれの exit point でも orchestrator が flow state の `.phase = create_post_interview` を読んで Phase 2 へ進む経路に切り替わる。`phase-transition-whitelist.sh` が `create_post_interview → create_delegation` を唯一の whitelisted forward transition として graph 定義するため、orchestrator は Phase 3 Delegation Routing を必ず実行する必要がある。

**Idempotence**: 単一 sub-skill invocation 内で複数回実行されても safe — patch mode は pre-update `.phase` から `previous_phase` を設定し、re-entry で `create_post_interview` のまま phase regression しない。

---

## Phase 1: Adaptive Interview Depth

After Phase 0 completes, determine the interview scope for Phase 1.1 based on tentative complexity and task type. This avoids excessive questioning for simple Issues.

### Tentative Complexity Estimation

詳細は [`references/complexity-gate.md#tentative-complexity-estimation`](./references/complexity-gate.md#tentative-complexity-estimation) を参照。Phase 0 の情報から複雑度 (XS/S/M/L/XL) を暫定推定するロジックで、(1) 後続の Adaptive Interview Depth による perspective filtering と (2) Phase 2 task decomposition decision (XL のみ trigger) に使う。最終 complexity は Phase 3 Heuristics Scoring (`create-register.md`) で確定する。

### Complexity-Based Interview Scope

| Tentative Complexity | Interview Scope | Target Perspectives |
|---------------------|----------------|---------------------|
| **XS** | No deep-dive needed | Skip Phase 1.1 entirely → proceed to Phase 2 |
| **S** | Minimal deep-dive | Perspective 1 (Technical Implementation) and 3 (Edge Cases) only |
| **M** | Standard deep-dive | Perspectives 1, 2, 3, 4 (5, 6 only if user-initiated) |
| **L** | Full deep-dive | All 6 perspectives + follow-up questions |
| **XL** | Full + decomposition | All 6 perspectives + set decomposition flag for Phase 2 |

### Task Type Presets

Task type が complexity-based scope より強い signal となる場合、以下で override（task type が ambiguous なら complexity-based に fallback、user は scope に関係なく追加質問を要求可能）:

| Task Type | Detection Method | Interview Override |
|-----------|-----------------|-------------------|
| **Bug Fix** | goal = "既存機能のバグ修正" or labels contain `bug` | Phase 0 → 2 direct (skip deep-dive) |
| **Chore** | goal = "その他" + maintenance context (依存更新 / CI修正 / リネーム / cleanup / linter設定 / ツール更新) or labels `chore` | Phase 0 → 2 direct (skip deep-dive) |
| **Feature** | goal = "新機能の追加" | complexity-based scope を適用 |
| **Refactor** | goal = "リファクタリング" | complexity-based scope を適用 |
| **Documentation** | goal = "ドキュメントの更新" or labels `documentation` | Abbreviated Phase 1.1 (perspectives 2, 4, 6 only) |

### Applying the Scope

After determining the interview scope:

1. **skip** (XS, Bug Fix, Chore): Skip Phase 1.1, proceed to Phase 2
2. **limited** (S, Documentation): Enter Phase 1.1 with the specified perspectives only
3. **standard / full** (M, L, XL): Enter Phase 1.1 with the full interview flow + perspective filtering

When entering Phase 1.1, display the scope to the user. Select language per `language` setting (`ja` / `en` / `auto` based on input language):

| Scope | Japanese | English |
|-------|----------|---------|
| limited | `複雑度 {complexity} / タスク種別 {task_type} に基づき、以下の視点に絞って確認します:\n- {perspective_list}\n追加の確認が必要な場合はお知らせください。` | `Based on complexity {complexity} / task type {task_type}, focusing on the following perspectives:\n- {perspective_list}\nLet me know if you need additional confirmation.` |
| standard / full | `複雑度 {complexity} に基づき、{standard:標準 / full:フル}の深堀インタビューを実施します。` | `Based on complexity {complexity}, conducting a {standard / full} deep-dive interview.` |

---

## Phase 1.1: Deep-Dive Interview

- **Boundary with Phase 0.5 (Quick Confirmation)**: Phase 0.5 は **quick confirmation** (What/Why/Where ギャップ充填 + task type 分類、0-1 AskUserQuestion calls)。Phase 1.1 は **deep-dive interview** (実装詳細を multiple perspective から探求、complexity に応じ複数 round)
- **Purpose**: 実装詳細を明確化（surface requirements ではない）。decision-divergence point と easily-overlooked aspect に focus
- **Prerequisite**: Phase 1 の interview scope を確認。"skip" なら本 phase を完全 skip、limited なら perspective filtering を適用

### EDGE-5: Context Window Pressure Mitigation

詳細は [`references/edge-cases-create.md#edge-5-context-window-pressure-mitigation`](./references/edge-cases-create.md#edge-5-context-window-pressure-mitigation) を参照。Phase 1.1 開始前に context pressure を heuristics で評価し、High pressure 時は auto-shortening mode (perspectives 削減 + batching + 早期 exit option) を発動する。

---

> **Important**: AskUserQuestion でインタビューを実施し、user が明示的に「no more points to confirm」と回答するまで継続。当て推量で打ち切らない。迷ったら質問する（聞きすぎは無害、品質基準は下記）。

### Basic Interview Guidelines

**Principle of Continuous Interviewing**: User 明示終了まで継続。AI 判断 (`enough information gathered`) での打ち切りは禁止 (canonical: [Termination Logic > Phase 1.1](#phase-11-interview-termination))。Phase 1 scope の perspective を確認し、user が「任せる」「skip」と言うまで終了せず、各 perspective を掘り下げ回答から follow-up を導出する。

**Quality Standards**: 自明な質問 (Yes/No 即答可、選択肢が 1 つ) は避ける。tradeoff を伴う複数選択肢の質問を優先。見落としやすい edge case / concern を能動的に確認。

### Tentative Complexity & Interview Perspectives

- **Tentative Complexity**: Phase 1 で推定。詳細は [`references/complexity-gate.md#tentative-complexity-estimation`](./references/complexity-gate.md#tentative-complexity-estimation) 参照。Phase 1 interview scope と Phase 2 task decomposition decision に使われる
- **Filtering rule**: Phase 1 で決定された scope に含まれる perspective のみ質問。scope 外は user 明示要求がない限り silent skip
- **Template reference**: Perspective 定義・confirmation 条件・question template は `{plugin_root}/templates/issue/interview-perspectives.md` を参照

### Interview Flow

1. **First question**: 最重要 decision point から開始
2. **Deep-dive**: 回答から follow-up を導出
3. **End confirmation**: 全 applicable perspective 確認後、必ず end confirmation dialog を提示 ([Termination Logic > Phase 1.1](#phase-11-interview-termination))
4. **Specification summary**: user が "no" と回答したら interview results を Issue body に反映

**End confirmation question format**:
```
質問: 他に確認したい点はありますか？

オプション:
- ある（追加の質問・要望を入力）
- ない、この内容で進めてください
- 残りの詳細は任せる
```

### EDGE-2: Re-entry After Exit Confirmation

詳細は [`references/edge-cases-create.md#edge-2-re-entry-after-exit-confirmation`](./references/edge-cases-create.md#edge-2-re-entry-after-exit-confirmation) を参照。Phase 1.1 終了確認後にユーザーが新規情報を追加入力した場合の re-entry trigger 検出基準と、再開・spec 追加・無視の 3 分岐挙動 (1 セッション 1 回 limit 付き) を定義する。

### AskUserQuestion Batch Optimization

**Applies to**: Modifies the Interview Flow above. Apply the batching rules below instead of asking each perspective independently to minimize context pressure from many small interactions.

**Batching Rules**: Group perspectives into **1-2 AskUserQuestion calls** (use `multiSelect: true` when multi-select is appropriate):

| Interview Scope | Batch Strategy | Max Calls |
|-----------------|---------------|-----------|
| **S** (Perspectives 1, 3) | Single batch: Technical + Edge Cases | 1 + follow-ups |
| **M** (1, 2, 3, 4) | B1: Technical + Edge Cases. B2: UX + Consistency | 2 + follow-ups |
| **L/XL** (All 6) | B1: Technical + Edge Cases + NFR. B2: UX + Consistency + Tradeoffs | 2 + follow-ups |
| **Documentation** (2, 4, 6) | Single batch: all 3 perspectives | 1 + follow-ups |

**Example (S scope, Batch 1)**:
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

> **Note**: 組み合わせがオプションに該当しない場合（例: "A + 正常系のみ"）はユーザーが "Other" で自由記述で回答できる。M/L/XL スコープでも同形式で「技術 + エッジケース」「UX + 一貫性」等を Batch 化する。

**Pre-condition Evaluation**: Before asking, evaluate whether the question is necessary:

| Pre-condition | Action |
|--------------|--------|
| Implementation approach is uniquely determined | Skip Technical Implementation |
| No UI/UX changes | Skip UX |
| Input well-constrained (enum, fixed format) | Skip Edge Cases |
| No existing features affected | Skip Consistency |
| No performance/security concerns | Skip NFR (unless L/XL) |

**Important**: Pre-condition は batch 内の質問を減らすが user 確認を代替しない。batch 内の全質問が排除された場合は batch 全体を skip する。

**Follow-up Questions**: After batch responses, follow-ups are asked individually (not batched) as they require specific context from prior answers. After **2 rounds** of follow-ups, present the end confirmation dialog. User judgment is final — continue if requested (UX-2: No AI auto-termination).

### Deep-Dive Examples

各ユースケースの representative な質問パターンを示す（実際の質問は要件に応じて perspective filtering に従い導出）:

| Use Case | First Question | Representative Options | Follow-up Examples |
|----------|----------------|----------------------|---------------------|
| **User Authentication** | 認証方式は？ | メール/パスワード, ソーシャルログイン, 両方, 提案要 | (email/password 選択時) パスワードリセット機能の要否 / 認証状態の保持期間 (セッション/永続/期限付き) |
| **UI Component (Data Table)** | 必要な機能は？ | ソート, フィルタ, ページネーション, 全部 | 想定データ量 (少量100件以下 / 中量1000件 / 大量1万件以上) → クライアント or サーバーサイド処理判断 |
| **Refactoring (API Client)** | 主目的は？ | 可読性, テスタビリティ, パフォーマンス, 新機能準備 | インターフェース影響 (破壊的変更 / インターフェース維持 / 段階的移行) |

> **Pattern**: 第一質問はユースケースの最も重要な分岐点を提示し、follow-up は回答に応じて edge case / NFR / tradeoff を掘り下げる。option には常に「提案してほしい」「判断を任せる」を含めて user の judgment escape hatch を残す。

### Interview Termination Conditions

> **Reference**: See [Termination Logic > Phase 1.1 Interview Termination](#phase-11-interview-termination) for the complete termination rules, including the mandatory exit confirmation dialog and AI auto-termination prohibition (UX-2).

### Reflecting Interview Results

Interview Perspective → Target Sections の正規 mapping table は [`references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping`](./references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping) を参照。Phase 1.1 では本 reference の mapping に従って interview results を Section 1-9 に割り当てる。

**Note**: Phase 1.1 は raw interview results を会話コンテキストに保持するのみ。Implementation Contract Section 1-9 への構造化 mapping は Issue body 生成時 (`create-register.md` Phase 3) に実施する。

**Retention format** (会話コンテキスト保持、Issue body には書き込まない): JSON object `interview_results` に 6 perspective キー (`technical_implementation` / `user_experience` / `edge_cases` / `existing_feature_impact` / `non_functional_requirements` / `tradeoffs`) を持ち、各キーは「<項目>: <選択値>」形式の string array を保持する（例: `"technical_implementation": ["認証方式: JWT", "トークン保存: HttpOnly Cookie"]`）。スコープ外 perspective は空配列。

---

## Termination Logic

### Phase 1.1 Interview Termination

> **UX-2: Exit Condition Enforcement** — 全 applicable perspective 確認後、end confirmation dialog の提示は **MUST**（無条件、AI 判断 skip 禁止）。

**Rules**: (1) scope 内 perspective 完了後は無条件で end confirmation dialog 提示、(2) 「enough information gathered」AI 自己判断での終了禁止（終了判断は user のみ）、(3) user が明示的に "skip" を選択した場合のみ skip 可能、(4) Phase 1 scope が対象 perspective を決定。

**Scope-specific termination**:

| Interview Scope | Termination Rule |
|----------------|-----------------|
| **Skip** (XS, Bug Fix, Chore) | Phase 1.1 不実行、終了処理不要 |
| **Limited** (S, Documentation) | 指定 perspective 完了後 dialog 提示、追加なしなら Phase 2 へ |
| **Standard** (M) | Perspective 1-4 完了後 dialog 提示、追加あれば継続 |
| **Full** (L, XL) | 全 6 perspective 完了後 dialog 提示、user 明示終了まで継続 |

**Dialog format**: [Interview Flow > End confirmation question format](#interview-flow) を使用。

---

## Return Output Format (Before Return)

> **Reference**: `start.md` の sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0) に追従。flow-state write は 🚨 MANDATORY Pre-flight (本ファイル冒頭) で interview scope に関係なく post-interview phase を記録。本 re-patch は defense-in-depth second write として timestamp / `next_action` を refresh する。

Immediately before emitting the four-line return block, re-patch flow state (idempotent with Pre-flight write):

```bash
# bash 引数 / exit-code check / --preserve-error-count rationale は references/sub-skill-handoff-contract.md (canonical SoT)
# に集約。Pre-flight 後の同一 phase self-patch のため file 存在は保証済み。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "create_post_interview" \
      --active true \
      --next "rite:issue:create-interview completed. Proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
      --preserve-error-count; then
    echo "[CONTEXT] INTERVIEW_RETURN_PATCH_FAILED=1" >&2
    # 非 blocking: create.md Step 0/Step 1 の redundant patch が続行する。
  fi
fi
```

> **Why patch mode only (no create fallback)**: Pre-flight が "file missing" branch (`create` mode) を処理済。本 section 到達時は flow state file 存在 + `.phase = create_post_interview` が保証済。ここで `create` 呼出は `previous_phase` を空文字列にリセットし `phase-transition-whitelist.sh` whitelist transition check を defeat する (`pre-tool-bash-guard.sh` / `session-end.sh` が source) ため不可。patch mode で transition chain を preserve する。

After the flow-state update, output the result pattern. Caller-continuation reminder を **immediately before** result pattern に emit。Return block は **4 line** 構成: (1) `[CONTEXT] INTERVIEW_DONE=1` grep marker / (2) plain-text blockquote continuation reminder / (3) HTML-commented caller instructions / (4) HTML-commented result sentinel。全 4 行が sub-skill の **last visible lines**。

> **Return block design rationale**:
> - caller continuation hint を plain-text line + HTML comment の **dual form** で emit（HTML comment が rendering で strip される場合への defense）
> - result pattern を HTML comment 化 (`<!-- [interview:skipped] -->`) — sentinel は grep-matchable (`grep -F '[interview:'`) のまま AC-3 保持し、user-visible terminal token としての sentinel 出力を抑止して LLM turn-boundary heuristic 起因の `continue` 要求 stop を防ぐ
> - `[CONTEXT] INTERVIEW_DONE=1` marker を return block の **FIRST line** に追加（not last）— orchestrator Pre-check Item 0 と Mandatory After Interview Step 0 が consume する grep signal、HTML strip rendering でも検出可能な plain-text 形式

**Output format example (interview skipped)**:

```
[CONTEXT] INTERVIEW_DONE=1; scope=skipped; next=phase_2
> ⏭ 継続中: Phase 2 → Phase 3 Delegation Routing → terminal sub-skill (Issue 未作成、自動継続します)
<!-- caller: IMMEDIATELY run this as your next tool call (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview --active true --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 2. Do NOT stop.' --if-exists --preserve-error-count` THEN (after the bash command above succeeds) continue with Phase 2 (Task Decomposition Decision) in the SAME response turn. DO NOT stop. No GitHub Issue has been created yet. -->
<!-- [interview:skipped] -->
```

**Output format example (interview completed)**:

```
[CONTEXT] INTERVIEW_DONE=1; scope=completed; next=phase_2
> ⏭ 継続中: Phase 2 → Phase 3 Delegation Routing → terminal sub-skill (Issue 未作成、自動継続します)
<!-- caller: IMMEDIATELY run this as your next tool call (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview --active true --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 2. Do NOT stop.' --if-exists --preserve-error-count` THEN (after the bash command above succeeds) continue with Phase 2 (Task Decomposition Decision) in the SAME response turn. DO NOT stop. No GitHub Issue has been created yet. -->
<!-- [interview:completed] -->
```

> **Plain-text form rationale**: 短く user-friendly な Markdown blockquote (`> ⏭ 継続中:`) にすることで (a) rendered Markdown で視覚的に「自動継続中」の文脈が明確、(b) HTML コメント (LLM 向け詳細) との責任分担が明確。詳細な caller 向け instruction は HTML コメント側に残し、plain-text 行は user 向けの短い status indicator として機能する。user-visible な最終コンテンツは `⏭ 継続中:` blockquote となり、sentinel token は HTML コメント化されレンダリング時に不可視。

Result patterns (grep-matchable string inside HTML comment):

- **Interview completed**: `<!-- [interview:completed] -->` (matches `grep -F '[interview:completed]'`)
- **Interview skipped** (XS, Bug Fix, Chore): `<!-- [interview:skipped] -->` (matches `grep -F '[interview:skipped]'`)

This pattern is consumed by the orchestrator (`create.md`) to determine the next action. The plain-text reminder is visible to both the LLM and the human user; the HTML comments hide the caller instructions and sentinel token from the user-visible rendered view while keeping them available to LLM-side grep / context inspection.

---

## 🚨 Caller Return Protocol

Sub-skill 完了 (interview finished or skipped) 時、control は **MUST** caller (`create.md`) へ戻る。caller は **同 response turn で MUST immediately** 🚨 Mandatory After Interview を実行し Phase 2 (Task Decomposition Decision) へ進む。

**WARNING**: **GitHub Issue は未作成**。本セクションで停止すると deliverable なしで workflow 放棄。

**Output rules** (本セクションが marker 形式の SoT。bash 引数 / exit-code symmetry の SoT は [`references/sub-skill-handoff-contract.md`](./references/sub-skill-handoff-contract.md)):

0. **FIRST**: `[CONTEXT] INTERVIEW_DONE=1; scope={skipped|completed}; next=phase_2` を **plain-text line** で出力（HTML-commented 不可）。位置規定:
   - **0b (構造保証、canonical)**: Rules 0-1 の相対順序が **4-line return block** を pin する: Rule 0 (FIRST) → plain-text continuation reminder → HTML-commented caller instructions → Rule 1 (absolute LAST)。この 4-line invariant が canonical で、他の位置記述はここから導出
   - **0a (絶対位置、0b から導出)**: 4-line block 構造より、本 marker は **4th-to-last visible line**（`<!-- [interview:*] -->` absolute-last sentinel の 3 行前）。各行が single-line である前提。Line 2/3 が multi-line 化した場合は 0b 4-line invariant が先に壊れるため両 Rule の joint update が必要
   - **0c (目的)**: grep marker for orchestrator Pre-check Item 0 (routing dispatcher、本 site で active routing 発火) and for Mandatory After Step 0 bash block comment reference (informational — Step 0 は unconditional idempotent `flow-state-update.sh patch` であり marker 分岐なし、marker は documentation context); LLM turn-boundary heuristic 対策の defense-in-depth
1. Result pattern を HTML comment (`<!-- [interview:completed] -->` / `<!-- [interview:skipped] -->`) で **absolute last line** に出力 (sentinel は grep-matchable だが user-visible でない)
2. Bare `[interview:*]` 形式（HTML comment wrap なし）は **禁止**（user-visible terminal token として regressed）
3. Result pattern の **後ろに narrative text を出さない**（`→ Return to create.md` 等）— LLM の natural stopping point を生む
4. Caller は HTML comment 内の grep-matchable 文字列と plain-text `[CONTEXT] INTERVIEW_DONE=1` marker を grep で読取り、即 Phase 2 へ継続
