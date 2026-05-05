---
description: |
  (Internal sub-skill — invoked by /rite:issue:create only. Do NOT invoke directly.)
  Issue の仕様書作成・Sub-Issue 分解・一括作成を行う sub-skill。
  Phase 3.1 仕様書生成 + Phase 3.2/3.3 分解・bulk-create を担当。
---

# /rite:issue:create-decompose

Generate a specification document, decompose into sub-Issues, and create them in bulk. This sub-command is invoked from `create.md` when the user selects decomposition in Phase 2.

**Prerequisites**: Phase 0.1 and Phase 2 have completed in the parent `create.md` flow. Phases 0.4-0.5 may or may not have been executed depending on the flow path (Phase 0.3 early decomposition skips Phase 0.4-0.5). The following information is available in conversation context:
- Extracted elements (What/Why/Where/Scope/Constraints) from Phase 0.1 — **always available**
- Interview results from Phase 1.1 — available if conducted; `null` if skipped
- Tentative slug from [Phase 0.2](./references/slug-generation.md) — **always available** — generated per [Slug Generation Rules](./references/slug-generation.md#slug-generation-rules)
- Decomposition decision from Phase 2 — **always available**

---

## Phase 3: Execution (Decompose Path)

### 3.1 Specification Document Generation

**Purpose**: Generate an independent design document based on the deep-dive interview results.

> **Relationship with `implementation-plan.md`**: This phase generates a **high-level design** (What/Why/Where) saved as `docs/designs/{slug}.md`. When the Issue is later started via `/rite:issue:start`, the [Implementation Plan module](./implementation-plan.md) generates a **detailed implementation plan** (How/Step-by-step) that builds on this specification. The specification document provides pre-validated requirements and architectural decisions — the implementation plan adds file-level changes, dependency graphs, and reference implementations.

#### Specification Document Structure

Generate a specification document with the structure below. Each section has a **Section ID** (e.g., `SPEC-REQ-FUNC`) embedded as `<!-- Section ID: ... -->` HTML comment immediately before the heading. Phase 3.2 references these IDs directly to avoid re-analyzing the full document.

| Section ID | Level | Heading | Content | Phase 3.2 Usage |
|------------|-------|---------|---------|-----------------|
| `SPEC-OVERVIEW` | h2 | `## 概要` | What: 何を作るか | (完成度のみ) |
| `SPEC-BACKGROUND` | h2 | `## 背景・目的` | Why: なぜ必要か | (完成度のみ) |
| `SPEC-REQ-FUNC` | h3 | `### 機能要件` (under `## 要件`) | Phase 1.1 インタビュー結果から抽出 | Primary source for feature-based decomposition |
| `SPEC-REQ-NFR` | h3 | `### 非機能要件` (under `## 要件`) | Phase 1.1 インタビュー結果から抽出 | NFR constraints per Sub-Issue |
| `SPEC-TECH-DECISIONS` | h2 | `## 技術的決定事項` | Phase 1.1 で確定した技術的選択 | (完成度のみ) |
| `SPEC-ARCH-COMPONENTS` | h3 | `### コンポーネント構成` (under `## アーキテクチャ`) | 主要コンポーネントと役割 | Layer-based decomposition |
| `SPEC-ARCH-DATAFLOW` | h3 | `### データフロー` (under `## アーキテクチャ`) | データの流れの説明 | (完成度のみ) |
| `SPEC-IMPL-FILES` | h3 | `### 変更が必要なファイル/領域` (under `## 実装ガイドライン`) | Where の詳細 | File assignment per Sub-Issue |
| `SPEC-IMPL-CONSIDERATIONS` | h3 | `### 考慮事項` (under `## 実装ガイドライン`) | エッジケース・セキュリティ・パフォーマンス等 | Risk allocation per Sub-Issue |
| `SPEC-OUT-OF-SCOPE` | h2 | `## スコープ外` | 今回の実装範囲に含めないもの | Scope boundary per Sub-Issue |

**Document outline** (h1 = `# {Issue タイトル}` followed by sections in the order above):

```markdown
# {Issue タイトル}
<!-- Section ID: SPEC-OVERVIEW -->
## 概要
<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的
## 要件
<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件
<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件
<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項
## アーキテクチャ
<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成
<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー
## 実装ガイドライン
<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域
<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項
<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外
```

**Notes**:
- `## Sub-Issue 候補` 節は Phase 3.2 完了後に自動追記される (Phase 3.1 では含めない)
- `(完成度のみ)` の Section ID は document completeness のために定義されているが Phase 3.2 decomposition では直接参照されない
- Phase 3.2 は ID コメントマーカーで該当 section のみを抽出読みすることで redundant analysis と token 消費を削減する

#### Saving the Specification Document

Save the generated specification document in the `docs/designs/` directory:

```bash
# ディレクトリが存在しない場合は作成
mkdir -p docs/designs

# ファイル名は references/slug-generation.md ルールで事前生成した {tentative_slug} を使用
# タイトルが変更された場合のみ再生成する
```

**Slug source**: Use `{tentative_slug}` from [Phase 0.2](./references/slug-generation.md). If the Issue title was modified after Phase 0.1 (e.g., through interview refinement), regenerate the slug using the rules defined in [`references/slug-generation.md#slug-generation-rules`](./references/slug-generation.md#slug-generation-rules) (single source of truth for slug generation rules).

**When `{tentative_slug}` is not available** (e.g., Phase 0.2 was skipped or context was compacted): Generate a new slug following the rules in [`references/slug-generation.md#slug-generation-rules`](./references/slug-generation.md#slug-generation-rules).

#### Specification Document Confirmation

> **Reference**: See [Termination Logic > Phase 3.1 Specification Document Termination](#phase-31-specification-document-termination) for the termination routing table.

Display the generated specification document and confirm with `AskUserQuestion`:

```
以下の仕様書を生成しました:

{仕様書の内容（要約）}

保存先: docs/designs/{slug}.md

オプション:
- 仕様書を承認: この内容で Sub-Issue の分解に進みます
- 仕様書を編集: 追加・修正したい点を教えてください
- キャンセル: 分解をキャンセルし、単一 Issue として作成します
```

**Context carryover when "キャンセル" is selected**:

Phase 1.1 / Phase 3.1 で収集した情報は cancel 後も Phase 3 (Single Issue path) で利用される。`docs/designs/{slug}.md` は **削除されず保持** され、後続 `/rite:issue:start` で [Implementation Plan module](./implementation-plan.md) が high-level design context として参照する。Interview result の反映は [EDGE-3: Interview Result Reflection Rules](./references/edge-cases-create.md#edge-3-interview-result-reflection-rules) に従う。

Implementation Contract Section への mapping は [`references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping`](./references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping) を参照。本 Issue cancel 時に carryover される項目の対応:

| 収集情報 | Carryover 先 |
|---------|-------------|
| What/Why/Where | Implementation Contract Section 1 (Goal) / Section 2 (Scope) |
| Interview results (technical decisions 等) | Implementation Contract Sections 1-9 (interview-to-section mapping 経由) |
| Tentative complexity XL | Phase 3 (Single Issue path) で確定 (cancel 後も XL として記録) |
| Out-of-scope items | Implementation Contract Section 2 (Out of Scope) / Section 1 (Non-goal) |
| Spec document content (Phase 3.1) | Implementation Contract Section 4 (Implementation Details) で design context として参照 |

**When "キャンセル" is selected**: Invoke `skill: "rite:issue:create-register"` で単一 Issue として作成。`create-register.md` Phase 3 (Single Issue path) は本 carryover を利用する。

**Context handoff to `create-register`**: skill 起動時 prompt に decompose 固有の追加項目 (`create.md` Phase 3 Delegation Routing の base context に追記):

| Context | Value |
|---------|-------|
| Specification document | `docs/designs/{slug}.md` (retained on cancel) — Section 4 で参照 |
| `phases_skipped` flag | `"0.4-0.5"` (Phase 0.3 early decomposition trigger) / `null` (normal flow) |
| EDGE-3 applicable row | Phase 1.1 status から決定 ([EDGE-3 condition table](./references/edge-cases-create.md#edge-3-interview-result-reflection-rules))。Phase 0.4-0.5 + Phase 1.1 全 skip 時は row 4 適用 |

base context (What/Why/Where / Goal classification / Tentative complexity / Interview results) は `create.md` Phase 3 Delegation Routing の正規定義を参照。

---

### 3.2 Sub-Issue Decomposition

**Purpose**: Extract specific Sub-Issues from the specification document and formulate an implementation plan.

**Structured reuse**: Use Section IDs from Phase 3.1 (Specification Document Structure) to directly reference specification sections instead of re-analyzing the full document. See the Section ID mapping table at the top of Phase 3.1 — the "Phase 3.2 Usage" column indicates which sections each decomposition path consumes (`(完成度のみ)` rows are not directly referenced by Phase 3.2).

#### Decomposition Algorithm

Decomposition criteria + selection priority:

| Priority | Criteria | Description | Applicable Scenario |
|---------:|----------|-------------|---------------------|
| 1 | **By feature** (preferred) | Split by independent features (auth / data display / settings 等) | 独立した複数 feature が存在 (default) |
| 2 | **By layer** | Architecture layer (UI / logic / data) で分割 | 単一 feature が複数 layer にまたがる |
| 3 | **By dependency order** | 実装依存 (foundation → application) に基づく分割 | 上記で分割後に実装順序を決定する際 |
| Fallback | **By work timeline** | initial setup → implementation → testing | 上記いずれも適用不可な場合 |

**Sub-Issue granularity**: 各 Sub-Issue は **1 Issue = 1 PR** 規模、Complexity S–L (XL は更に分割)、独立完結 (他 Sub-Issue と並行作業可能)。

#### Dependency Analysis

Sub-Issue 間の依存を解析。表現例: `#1 データモデル定義 (依存なし)` → `#2 API 実装 (依存: #1)` → `#3 UI 実装 (依存: #1)` → `#4 API 連携 (依存: #2, #3)` → `#5 テスト (依存: #4)`。

#### Implementation Order Proposal

依存関係に基づく実装順序を 4 フェーズ (`### フェーズ 1: 基盤構築` / `### フェーズ 2: コア実装（並行可能）` / `### フェーズ 3: 統合` / `### フェーズ 4: 品質保証`) で提示。各エントリは `1. #{number} - {title} (複雑度: {complexity})` 形式。

#### Decomposition Result Confirmation

> **Reference**: 終了 routing は [Termination Logic > Phase 3.2 Decomposition Result Termination](#phase-32-decomposition-result-termination) を参照。

`AskUserQuestion` で分解結果を確認 (項目: タイトル / 複雑度 / 依存 を持つ Sub-Issue table を表示し、合計 N 件)。オプション: `この分解で作成する（推奨）` / `Sub-Issue を追加` / `Sub-Issue を統合` / `分解をやり直す`。各選択後の処理は同 Termination Logic を参照。

---

### 3.3 Bulk Sub-Issue Creation

**Purpose**: Create the parent Issue and Sub-Issues in bulk and set up relationships.

#### Create the Parent Issue

Parent Issue body の正規 markdown 構造と placeholder definitions は [`references/bulk-create-pattern.md#parent-issue-body-structure`](./references/bulk-create-pattern.md#parent-issue-body-structure) を参照。`{概要}` / `{背景・目的}` / `{slug}` / `{count}` の source mapping も同節を参照。

First, create the parent Issue via the common script:

> **Note**: Each bash code block in Phase 3.3 runs as an independent process. The `trap` registered within each block is scoped to that process only and does not affect other blocks.

```bash
# Generate body content from Phase 3.1 spec and the canonical Parent Issue body structure
# (see references/bulk-create-pattern.md#parent-issue-body-structure for the moved structure)
# Note: Empty check is required because {parent_issue_body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{parent_issue_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{original_title}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "{priority}" \
  --arg complexity "XL" \
  --arg iter_mode "none" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "xl_decomposition", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
parent_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
parent_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
parent_project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
# project_id/item_id は XL 分解パスでは後続フェーズで使用しないため省略
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w" >&2; done
```

**Placeholder descriptions:**
- `{projects_enabled}`: `true` if `github.projects.enabled` is `true` in `rite-config.yml`, otherwise `false`
- `{project_number}`: From `github.projects.project_number` in `rite-config.yml`
- `{owner}`: From `github.projects.owner` in `rite-config.yml`
- `{priority}`: Priority value carried over from `create.md` Phase 0/1 (orchestrator → `create-decompose.md` context handoff). XL decomposition path does not invoke `create-register.md` Phase 3.1 Priority Estimation; the parent Issue inherits the orchestrator-level tentative priority and Sub-Issues inherit it from the parent

Sub-Issues API linkage (later in this Phase 3.3) で参照する `{repo}` / `{parent_issue_number}` / `{plugin_root}` 等の解決規則は [`references/bulk-create-pattern.md#placeholder-descriptions`](./references/bulk-create-pattern.md#placeholder-descriptions) を参照する (Bulk Creation 用に定義済みの placeholder list を Sub-Issues API linkage でも再利用)。

#### Bulk Creation of Sub-Issues

Pre-amble + Per-Sub-Issue body の bash literal / placeholder descriptions / Sub-Issue body structure / Error handling for partial failures / anti-pattern 例の正規定義は [`references/bulk-create-pattern.md`](./references/bulk-create-pattern.md) を参照。critical 警告 (下記 ⚠️ CRITICAL 段落) は本体に維持する — AC-1 enforcement boundary との因果関係を保つため、本体読込時に LLM が認識できる位置にある必要がある。

Bulk Creation は **2 つの部分** から構成され、両者は **a single Bash tool invocation** で実行されることが MUST 要件:

1. **Pre-amble** (1 回のみ実行): accumulator arrays (`SUB_ISSUE_NUMBERS` / `SUB_ISSUE_URLS`) を宣言する
2. **Per-Sub-Issue body** (Phase 3.2 分解 list の項目数 N 回実行): Sub-Issue を作成し accumulator に append する

> **⚠️ CRITICAL (AC-1 enforcement — single-Bash-invocation requirement)**:
> - Pre-amble + **all N copies of the Per-Sub-Issue body** + Sub-Issues API linkage (later in this Phase 3.3) を **one single Bash tool call** に連結する。各 Per-Sub-Issue body 複製は実行前に `{sub_issue_title}` / `{sub_issue_body}` / `{estimated_complexity}` を当該反復の実値で置換する。
> - **Do NOT split the iterations across multiple Bash tool invocations**。Bash 変数 (`SUB_ISSUE_NUMBERS` / `SUB_ISSUE_URLS` accumulator arrays を含む) は別 Bash tool 呼び出し境界で消失する。分割すると Sub-Issues API linkage が空配列を参照し、AC-1 enforcement が silent 違反される (per-call linkage failure は non-blocking)。Sub-Issues API linkage の空配列 fail-fast (`exit 1`) が最終防御層。
> - Pre-amble は結合 script の先頭に **exactly once** 配置する。各 Per-Sub-Issue body 内で配列を再宣言してはならない (蓄積状態がリセットされる)。
> - 各 successful create 後、Per-Sub-Issue body は `sub_issue_number` を `SUB_ISSUE_NUMBERS` に、`sub_issue_url` を `SUB_ISSUE_URLS` に append する。この bookkeeping により Sub-Issues API linkage が全 Sub-Issue を反復可能となる。
> - これは本コマンドにおける **silent-skip risk 最大の箇所**。bookkeeping 省略 / script 分割は **いかなる事情でも許容されない**。

具体的な bash literal (Pre-amble + Per-Sub-Issue body)、placeholder descriptions、Sub-Issue body structure、Error handling for partial failures、anti-pattern (split 禁止) の正規定義は [`references/bulk-create-pattern.md`](./references/bulk-create-pattern.md) を参照。本体には上記 critical 警告のみを残し、実装詳細は reference に集約する。

各 Sub-Issue 作成成功後の post-processing:

1. `sub_issue_url` / `sub_issue_number` を Tasklist update のため retain する
2. accumulator (`SUB_ISSUE_NUMBERS` / `SUB_ISSUE_URLS`) に append する (Sub-Issues API linkage が参照)
3. Per-call failure は non-blocking で継続、Completion Report で成功 / 失敗を集約報告

#### Add Tasklist to Parent Issue

After creating Sub-Issues, update the parent Issue body to add a Tasklist:

```bash
# 親 Issue の本文を更新
# Generate body content by merging existing body with new Tasklist (see "Tasklist format" below)
# Note: Empty check is required because {updated_body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{updated_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Updated body is empty" >&2
  exit 1
fi

gh issue edit {parent_issue_number} --body-file "$tmpfile"
```

**Tasklist format**:

```markdown
## Sub-Issues

- [ ] #{sub_issue_1_number} - {title}
- [ ] #{sub_issue_2_number} - {title}
- [ ] #{sub_issue_3_number} - {title}
...
```

#### Sub-Issues API Linkage (Mandatory)

After bulk Sub-Issue creation in this Phase 3.3, **always** establish the parent-child relationship at the API level using the [`link-sub-issue.sh` helper](../../references/graphql-helpers.md#addsubissue-helper). This ensures the GitHub `subIssues` relation is the single source of truth, while the body Tasklist (Add Tasklist to Parent Issue subsection above) and `Parent Issue: #N` body meta serve as human-readable backups.

**Execution**: For each `sub_issue_number` collected during the Bulk Creation step (the list referenced for Tasklist update above), execute the helper after the bulk-create loop completes.

> **⚠️ MANDATORY (single-Bash-invocation continuation of Bulk Creation)**: This block reads the `SUB_ISSUE_NUMBERS` bash array populated by the Bulk Creation Per-Sub-Issue body. Bash variables do **not** persist across separate Bash tool invocations. Therefore this block MUST be appended to **the same single Bash tool call** that contains the Bulk Creation Pre-amble + all Per-Sub-Issue body copies. Concretely, the structure of the combined script is:
>
> ```
> [Bulk Creation Pre-amble (once)]
> [Bulk Creation Per-Sub-Issue body (Sub-Issue #1)]
> [Bulk Creation Per-Sub-Issue body (Sub-Issue #2)]
> ...
> [Bulk Creation Per-Sub-Issue body (Sub-Issue #N)]
> [Sub-Issues API linkage block (once, below)]
> ```
>
> Do **not** issue a separate Bash tool call for Sub-Issues API linkage — the AC-1 empty-array guard (`exit 1` when `SUB_ISSUE_NUMBERS` is empty) will trip immediately because the array exists only in the previous shell process. (Add Tasklist to Parent Issue — the Tasklist update — can run as a separate Bash invocation either before or after this combined script, since it only needs the `sub_issue_number` / title pairs which Claude already has from the Bulk Creation results displayed in stdout.)

case ブロックの正規定義は [`references/sub-issue-link-handler.md` Variant B](../../references/sub-issue-link-handler.md#variant-b-counting-失敗カウンタあり) を参照。Behavioral guarantees / Error handling matrix の正規定義は [`references/graphql-helpers.md#addsubissue-helper`](../../references/graphql-helpers.md#addsubissue-helper) を参照。本体には MANDATORY guard と全件失敗時 ERROR レイヤのみを残す。

```bash
# 各 Sub-Issue について Sub-issues API で親に紐付ける
# SUB_ISSUE_NUMBERS は Bulk Creation で収集した sub_issue_number の配列

# === MANDATORY guard: 配列が空の場合は AC-1 違反として fail-fast ===
# Bulk Creation で配列蓄積を忘れると ${SUB_ISSUE_NUMBERS[@]} が空になり、linkage がサイレント no-op となる。
# feedback_e2e_no_stop_before_review に従い silent skip ではなく fail-fast。
if [ "${#SUB_ISSUE_NUMBERS[@]}" -eq 0 ]; then
  echo "ERROR: SUB_ISSUE_NUMBERS が空です。Bulk Creation のループ内で 'SUB_ISSUE_NUMBERS+=(\"\$sub_issue_number\")' が抜けている可能性があります。Sub-issues API linkage を実行できません (AC-1 違反)。" >&2
  exit 1
fi

# === Linkage loop: case ブロックは sub-issue-link-handler.md Variant B を inline 展開 ===
# Variant B は link_failures カウンタ付き。MUST NOT: 未知 status を `*)` ブランチで silent 通過させない。
# ⚠️ DRIFT 警告: 下記 case ブロックを修正する際は、必ず以下 2 ファイルも同期すること:
#   1. references/sub-issue-link-handler.md (Variant B 定義、link_failures 増分を含む全文)
#   2. commands/issue/parent-routing.md (Variant A 利用箇所、link_failures 増分を除いた部分が共通)
link_failures=0
for sub_number in "${SUB_ISSUE_NUMBERS[@]}"; do
  link_result=$(bash {plugin_root}/scripts/link-sub-issue.sh \
    "{owner}" "{repo}" "{parent_issue_number}" "$sub_number")
  link_status=$(printf '%s' "$link_result" | jq -r '.status')
  link_msg=$(printf '%s' "$link_result" | jq -r '.message')
  case "$link_status" in
    ok|already-linked) echo "✅ $link_msg" ;;
    failed)
      printf '%s' "$link_result" | jq -r '.warnings[]' | while read -r w; do echo "⚠️ $w" >&2; done
      echo "⚠️ Sub-issues API linkage failed for #$sub_number; body meta fallback in place" >&2
      link_failures=$((link_failures + 1)) ;;
    *) # MUST NOT: 未知 status を silent 通過させない
       echo "⚠️ Unexpected link status '$link_status' for #$sub_number (msg: $link_msg)" >&2
       link_failures=$((link_failures + 1)) ;;
  esac
done

# === 全件失敗時 ERROR レイヤ: AC-4/AC-5 に従い ERROR 警告 + 継続 ===
# 全 Sub-Issue で linkage 失敗 = 設定不備 ({repo} 未解決 / 権限不足 / API 未開放等) の可能性が高い。
# Tasklist + body meta が fallback として残るため後続 Projects Registration / Completion Report は実行する (parent-routing.md と統一)。
if [ "$link_failures" -eq "${#SUB_ISSUE_NUMBERS[@]}" ]; then
  echo "ERROR: 全 Sub-Issue (${#SUB_ISSUE_NUMBERS[@]} 件) で Sub-issues API linkage が失敗しました。" >&2
  echo "  考えられる原因: {owner}/{repo}/{parent_issue_number} プレースホルダーの未解決、token scope 不足、Sub-issues API が無効など。" >&2
  echo "  body メタ (Tasklist + Parent Issue: #N) は残っているため parent-child の追跡は可能。AC-4/AC-5 に従い継続。" >&2
elif [ "$link_failures" -gt 0 ]; then
  echo "⚠️ $link_failures/${#SUB_ISSUE_NUMBERS[@]} 件の Sub-Issue で API 紐付けに失敗しました（body メタは維持されます）" >&2
fi
```

#### Projects Registration

> **Note**: Projects registration (item-add + field setup) is handled internally by `create-issue-with-projects.sh` in Create the Parent Issue / Bulk Creation of Sub-Issues. This step only verifies the results and handles any failures.

**Verification**: Check `parent_project_reg` and each `sub_project_reg` from earlier Phase 3.3 substeps.

- All `"ok"` → Display success in Completion Report
- Any `"partial"` or `"failed"` → Display warning: `⚠️ 一部の Projects 登録に失敗しました。手動で登録してください。`
- `"skipped"` → Projects integration is disabled, no action needed

#### Completion Report

Report the creation results:

```
Issue の分解が完了しました

親 Issue: #{parent_number} - {parent_title}
設計ドキュメント: docs/designs/{slug}.md

Sub-Issues:
| # | タイトル | 複雑度 | URL | Projects | 状態 |
|---|---------|--------|-----|----------|------|
| #{number} | {title} | {complexity} | {url} | {project_reg} | 成功 / 失敗 |
| ... | ... | ... | ... | ... | ... |

成功: {success_count} 件 / 失敗: {failure_count} 件
合計: {count} 件の Sub-Issue を作成しました

Projects 設定:
- Status: Todo
- Priority: {priority}
- Complexity: XL（親）/ {各 Sub-Issue の複雑度}

次のステップ:
1. `/rite:issue:start #{first_sub_issue}` で最初の Sub-Issue から作業開始
2. `/rite:issue:list` で Sub-Issue の一覧を確認
```

---

### 3.4 Terminal Completion (Normal Path Only)

<!-- caller: this sub-skill is terminal on the Normal path. Phase 3.4 deactivates flow state and outputs the user-visible completion message (✅) + next steps as the last user-visible content, with [create:completed:{N}] embedded in a trailing HTML comment (grep-matchable but not user-visible). The orchestrator's 🚨 Mandatory After Delegation section MUST run in the SAME response turn as a defense-in-depth no-op (Step 1/2 skipped when marker present). DO NOT stop before the orchestrator's self-check completes. -->

> **Design decision**: This sub-skill handles flow-state deactivation, next-step output, and completion marker internally on the **Normal path** (sub-Issues created via Phase 3.3). On the **Delegation path** (cancelled and delegated to `create-register`), `create-register.md` handles its own Terminal Completion — do NOT execute this section.
>
> **Design decision**: The `[create:completed:{N}]` sentinel is emitted as an HTML comment (`<!-- [create:completed:{N}] -->`) so that the user-visible final line is the `✅` completion message + next steps, not the sentinel token. The string `[create:completed:N]` inside the HTML comment is still grep-matchable, and the HTML comment form weakens the LLM's turn-boundary heuristic that would otherwise treat a bare sentinel line as a natural stopping point. Same policy as `create-register.md` Phase 3.4.

**Condition**: Execute only on the **Normal path**.

#### Flow State Deactivation

After the Completion Report (in Phase 3.3), deactivate the flow state:

```bash
# --if-exists で flow state file 不在時は silent skip。
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_completed" \
  --next "none" --active false \
  --if-exists
```

#### Completion Message (User-facing)

> **Design decision**: The `[create:completed:{N}]` sentinel marker is primarily for hooks/scripts (grep-verified). Emit an explicit user-visible completion message followed by the next-steps block; place the sentinel as a trailing HTML comment so the user's visible final content is the `✅` message + next steps.

Output the user-facing completion message after the Phase 3.3 Completion Report and before the completion marker:

```
✅ Issue #{parent_issue_number} を分解して {count} 件の Sub-Issue を作成しました: {parent_issue_url}
```

Where `{parent_issue_number}` / `{parent_issue_url}` / `{count}` are from Phase 3.3 results.

#### Completion Marker (HTML comment form)

Output the completion marker as an **HTML comment on the final line** — invisible to the user in rendered views, but matchable by `grep -F '[create:completed:'` / `grep -E '\[create:completed:[0-9]+\]'`:

- **Decomposition completed**: `<!-- [create:completed:{first_sub_issue_number}] -->`

Where `{first_sub_issue_number}` is the first sub-Issue number (the recommended starting point from Phase 3.3 Completion Report's 次のステップ).

**Output rules**:
1. `<!-- [create:completed:{N}] -->` is the **absolute last line** of Phase 3.4's output — no plain text after it
2. The user-visible final content (last non-comment line) MUST be the next-steps block (`次のステップ: ...` from Phase 3.3 Completion Report) immediately preceded by the `✅` completion message
3. Do **NOT** output narrative text like `→ create.md に戻ります` — it is not actionable and creates a natural stopping point for the LLM
4. Do **NOT** emit the sentinel as a bare `[create:completed:{N}]` line (without HTML comment wrapping) — the bare form regresses to the user-visible terminal token
5. The orchestrator's 🚨 Mandatory After Delegation section serves as defense-in-depth only

**Concrete output example**:

```
✅ Issue #1234 を分解して 3 件の Sub-Issue を作成しました: https://github.com/.../issues/1234

次のステップ:
1. `/rite:issue:start #1235` で最初の Sub-Issue から作業開始
2. `/rite:issue:list` で Sub-Issue 一覧を確認

<!-- [create:completed:1235] -->
```

---

## Termination Logic

### Phase 3.1 Specification Document Termination

Phase 3.1 terminates based on the user's selection in the specification confirmation dialog (Specification Document Confirmation):

| User Selection | Next Phase |
|----------------|------------|
| 仕様書を承認 | Phase 3.2 (Sub-Issue Decomposition) |
| 仕様書を編集 | Re-edit → return to Specification Document Confirmation |
| キャンセル | Invoke `skill: "rite:issue:create-register"` (cancel decomposition, create as single Issue). See context carryover section in Phase 3.1 for details |

### Phase 3.2 Decomposition Result Termination

Phase 3.2 terminates based on the user's selection in the decomposition result confirmation dialog (Decomposition Result Confirmation):

| User Selection | Next Phase |
|----------------|------------|
| この分解で作成する（推奨） | Proceed to Phase 3.3 (Bulk Sub-Issue Creation) |
| Sub-Issue を追加 | Confirm the Sub-Issue content with the user, add to the list, then return to Decomposition Result Confirmation |
| Sub-Issue を統合 | Confirm which Sub-Issue numbers to merge, combine into one, then return to Decomposition Result Confirmation |
| 分解をやり直す | Return to Decomposition Algorithm. Change decomposition criteria and re-decompose. Confirm with the user "which criteria to use for re-decomposition" |

---

## 🚨 Caller Return Protocol

Completion occurs via one of the following paths:

- **Normal path** (sub-Issues created via Phase 3.3): This sub-skill is terminal. Issue creation workflow is **fully complete** — flow-state deactivated, next steps displayed, completion marker output. The caller (`create.md`) MAY execute its 🚨 Mandatory After Delegation as defense-in-depth (idempotent).
- **Delegation path** (cancelled and delegated to `create-register`): `create-register.md` is the terminal sub-skill. It handles its own Terminal Completion (Phase 3.4) including flow-state deactivation and `[create:completed:{N}]` marker.
