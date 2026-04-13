---
description: Issue 内容を分析して実装計画を生成
---

# Implementation Plan Generation Module

This module handles Issue content analysis and implementation plan generation.

## Phase 3: Implementation Plan Generation

> **Reference**: Apply the Phase 3 checklist from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).
> In particular, check `assumption_surfacing`, `confusion_management`, and `inline_planning`.

> **Relationship with `create.md` Phase 0.7**: If the Issue was created via `/rite:issue:create`, a specification document (high-level design: What/Why/Where) may exist in `docs/designs/`. This module generates the **detailed implementation plan** (How/Step-by-step) that builds on that specification. Check for a linked design doc in the Issue body before starting analysis — it provides pre-validated requirements and architectural decisions that reduce redundant exploration.

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before executing bash hook commands in this file.

### 3.0.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki/query.md) — `wiki-query-inject.sh` API

Before generating the implementation plan, inject relevant experiential knowledge from the Wiki to enrich the planning context.

**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_query: true` in `rite-config.yml`. Skip silently otherwise.

**Step 1**: Check Wiki configuration:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_query=""
if [[ -n "$wiki_section" ]]; then
  auto_query=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_query:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_query:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # #483: opt-out default
case "$auto_query" in true|yes|1) auto_query="true" ;; *) auto_query="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_query=$auto_query"
```

If `wiki_enabled=false` or `auto_query=false`, skip this section and proceed to Phase 3.1.

**Step 2**: Generate keywords from the Issue context and invoke the query:

Keywords are derived from: Issue title, labels, and change target file paths (identified from the Issue body).

```bash
# {plugin_root} はリテラル値で埋め込む
# {keywords} は Issue タイトル + ラベル + 変更対象ファイル名をカンマ区切りで生成
# wiki-query-inject.sh は常に exit 0（Wiki 無効/未初期化/マッチなしでも）
wiki_context=$(bash {plugin_root}/hooks/wiki-query-inject.sh \
  --keywords "{keywords}" \
  --format compact 2>/dev/null) || wiki_context=""
if [ -n "$wiki_context" ]; then
  echo "$wiki_context"
else
  echo "(Wiki から関連経験則は見つかりませんでした)"
fi
```

**Step 3**: If `wiki_context` is non-empty, retain it in conversation context and reference it during plan generation (Phase 3.2-3.3). The injected experiential knowledge may inform: file change patterns, common pitfalls in similar implementations, and verification criteria.

### 3.1 Issue Content Analysis

Leverage the quality score and extracted information validated in Phase 1 to perform analysis for implementation plan generation:

| Element | Extracted Content | Relationship with Phase 1 |
|---------|-------------------|---------------------------|
| **What** | What to do (from title/summary) | Validated in Phase 1.2 |
| **Why** | Why it's needed (from background/purpose) | Validated in Phase 1.2 |
| **Where** | Where to change (from change content/impact scope) | Validated in Phase 1.2, refined here |
| **Scope** | Impact scope (from impact scope/checklist) | Validated in Phase 1.2, refined here |

**Note**: Also include information supplemented as quality score C/D in Phase 1 in the analysis.

### 3.2 Identify Files to Change

Identify files that need changes based on Issue content:

1. File paths explicitly mentioned in Issue body
2. Related file detection through codebase exploration
3. File count estimation based on complexity

**Exploration methods** (using Claude Code tools):

| Tool | Usage | Example |
|------|-------|---------|
| Glob | File pattern search | `**/*.md`, `commands/**/*.md` |
| Grep | Keyword search | Related function names, class names, config keys |
| Read | File content review | Detailed review of candidate files |

**Note**: Use Claude Code's dedicated tools, not bash commands, to explore the codebase.

### 3.2.1 Reference Implementation Discovery

> **Reference**: Apply `reference_discovery` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).

After identifying files to change in 3.2, automatically discover reference implementations by searching for existing files with similar patterns. This follows the Oracle pattern: using existing correct implementations as guides for consistency.

**Discovery steps**:

1. **Same directory, same extension**: For each target file, search for other files in the same directory with the same extension
   - Tool: `Glob` with pattern `{target_directory}/*.{ext}`
   - Example: Target `commands/issue/implementation-plan.md` → search `commands/issue/*.md`

2. **Name pattern matching**: Identify naming patterns and search for similar files (execute when applicable — skip if Step 1 already found 3+ candidates)
   - Extract suffix patterns (e.g., `*-handler.ts`, `*-service.ts`, `*-plan.md`)
   - Tool: `Glob` with pattern `**/*-{suffix}.{ext}`
   - Example: Target `user-handler.ts` → search `**/*-handler.ts`

3. **Test-implementation correspondence**: Check for matching test/implementation file pairs (execute when applicable — skip for non-test projects or if 3+ candidates already found)
   - Pattern: `{name}.ts` ↔ `{name}.test.ts`, `{name}.spec.ts`
   - Pattern: `{name}.md` ↔ `docs/tests/{name}.test.md`

4. **Read reference files**: Use `Read` tool to examine each selected reference file and extract structural patterns (heading format, section organization, naming conventions, code style, etc.)
   - Read up to 3 selected files
   - Extract: section structure, formatting conventions, placeholder patterns, error handling patterns

**Early termination**: If 3 or more candidates are found in Step 1, proceed directly to Step 4 without executing Steps 2-3.

**Selection criteria** (when multiple candidates found):

| Priority | Criterion | Reason |
|----------|-----------|--------|
| 1 | Same directory files | Most likely to share conventions |
| 2 | Files with similar functionality (determined by file name semantics and directory context, e.g., both are CRUD operation commands) | Similar structure expected |
| 3 | Recently modified files (`Glob` tool returns results sorted by modification time; prefer files appearing earlier in results) | Reflect latest conventions |

Limit to **max 3 reference files** to avoid information overload.

**Record format**: See the "参考実装" section in the 3.3 template for the exact format. The record must include both the reference file paths and the structural patterns extracted in Step 4.

**When no references found**:

```markdown
### 参考実装
参考実装: なし（新規ディレクトリまたは初めてのファイルパターン）
→ プロジェクト全体の慣習に従ってください
```

### 3.2.2 Verification Criteria Guidelines

When generating the implementation plan (Phase 3.3), each step MUST include a `検証基準` (verification criteria) column. The criteria define what "done" means for each step and are mechanically verified by the Adaptive Re-evaluation checkpoint (5.1.0.5 in `implement.md`).

**Criteria must be tool-verifiable** — conditions that can be confirmed using Read, Grep, Glob, or Bash tools without subjective judgment:

| Criteria Type | Example | Verification Tool |
|--------------|---------|-------------------|
| File existence | `src/auth.ts` が存在する | Glob / Read |
| Function/export existence | `authMiddleware` がエクスポートされている | Grep (`export.*authMiddleware`) |
| Pattern presence | テーブルに `検証基準` 列が含まれる | Grep |
| Test passage | `npm test -- auth.test.ts` が pass | Bash |
| Config value | `rite-config.yml` に `verification` キーが存在する | Grep / Read |
| Line count / structure | セクションが 3 行以上ある | Read + count |

**Avoid non-verifiable criteria**:
- ❌ 「コードが読みやすい」（主観的）
- ❌ 「パフォーマンスが良い」（閾値なし）
- ❌ 「適切に実装されている」（曖昧）
- ✅ 「`handleError` 関数が `try-catch` で呼び出し元をラップしている」（Grep で確認可能）

### 3.2.3 Requirement Extraction

> **Reference**: Apply `assumption_surfacing` and `confusion_management` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).

**目的**: Issue 本文から **すべての** 要件（コード変更 + 非コードタスク）を網羅的に抽出し、Phase 3.3 のステップ生成にギャップなく引き継ぐ。これにより「ファイル変更リストのみがステップ化され、太字補足の非コードタスクが脱落する」事故を防ぐ。

**抽出対象**: Issue 本文の構造化セクションと自由記述テキストの両方:

| ソース | 抽出内容 |
|--------|---------|
| `4.1 Target Files` テーブル | 変更対象ファイルとその変更内容 |
| `4.4 Behavioral Requirements`（MUST / MUST NOT） | 振る舞い要件 |
| `5. Acceptance Criteria`（AC-N） | Given/When/Then の各受け入れ基準 |
| `## チェックリスト` / `## 8. Definition of Done` | DoD チェックリスト項目 |
| 自由記述テキスト（背景・スコープ等の段落） | 太字補足情報（`**xxx**: yyy`）含む補足要件 |

**Phase 3.6 との役割分担**: 3.2.3 は要件をテーブル化して Phase 3.3 のステップ生成に引き継ぐことが目的。Phase 3.6.1（既存）は Issue 本文のチェックリストを `- [ ]` / `- [x]` 状態で追跡することが目的。チェックリスト項目は両者で扱うが、3.2.3 では `requirement_items` の1要素として、3.6.1 では Issue 本文の状態追跡用として独立に再抽出される（重複ではなく目的が異なる）。

**非コードタスクの検出と分類**:

太字補足情報や自由記述に含まれる以下のようなタスクは、ファイル変更だけでは充足できない要件として **必ず** 検出・分類する:

- スクリーンショット撮影・差分検証（例: `**スクリーンショット**: Playwright で撮影し、LLM が目視検証`）
- ブラウザ操作・手動 E2E テスト
- アセット生成（画像・動画・PDF・GIF 等）
- 外部システム操作（GitHub Projects 設定、設定ファイル更新、CI 設定変更等）
- ユーザーへの確認依頼・レビュー依頼

**プロジェクトメモリ参照**:

`MEMORY.md` は **インデックスファイル** であり、フィードバック本体は `feedback_*.md` 等の別ファイルに格納されている（`/home/{user}/.claude/projects/{project_dir}/memory/` 配下）。`MEMORY.md` だけを読んでもリンク一覧しか取得できないため、以下の手順で参照すること:

1. **インデックス読み込み**: Read ツールで `MEMORY.md` を読み、本 Issue に関連する Feedback / Project エントリのファイル名を特定する
2. **実体ファイル読み込み**: 関連する `feedback_*.md` / `project_*.md` の実体を Read ツールで読み込み、制約やルールの本文を取得する
3. **計画への反映**: 取得した本文に基づき、計画に反映すべき事項を特定する

参照例:

- レビュー品質ルール（指摘ゼロまでループ、確信ある指摘のみ等） → `feedback_review_quality.md`, `feedback_review_zero_findings.md`
- 過去のインシデントを根拠にした強制ルール
- プロジェクト固有の制約・締め切り

**保持形式**: `requirement_items` を **Markdown テーブル** として会話コンテキストに保持する（JSON ではなく Markdown テーブル）。Phase 3.3 のステップ生成で全項目を参照できるようにする:

```markdown
| # | 要件 | 種別 | ソース | 対応ステップ |
|---|------|------|--------|-------------|
| R1 | `src/auth.ts` に `authMiddleware` を実装 | code_change | 4.1 Target Files | (Phase 3.3 で埋める) |
| R2 | スクリーンショット撮影と目視検証 | non_code_task | 太字補足（背景セクション） | (Phase 3.3 で埋める) |
| R3 | エラーハンドリングは try-catch で全呼び出し元をラップ | behavioral | 4.4 MUST | (Phase 3.3 で埋める) |
| R4 | AC-1: 不正なトークンを渡すと 401 を返す | acceptance | 5. AC-1 | (Phase 3.3 で埋める) |
| R5 | レビュー品質: 確信ある指摘のみ | memory_feedback | feedback_review_quality.md | (Phase 3.3 で埋める) |
```

**種別の値**:

| 種別 | 説明 |
|------|------|
| `code_change` | ファイル作成・編集・削除 |
| `non_code_task` | スクリーンショット撮影、ブラウザ操作、手動テスト、アセット生成等 |
| `behavioral` | MUST / MUST NOT で表現された振る舞い要件 |
| `acceptance` | Acceptance Criteria（Given/When/Then） |
| `memory_feedback` | プロジェクトメモリから引き継いだ制約 |

**ギャップ検出ルール**: Issue 本文を1段落ずつ走査し、抽出漏れがないかを自己確認する。特に「変更内容」「背景」セクションの太字補足は脱落しやすいため、Issue 本文文字列を段落単位で読みながら `**xxx**: yyy` 形式の太字パターンを目視で抽出すること。Issue 本文は GitHub API で取得した文字列として会話コンテキスト上にあり、ファイルとして存在しないため Grep ツールは使用不可。

### 3.3 Implementation Plan Generation

Generate an implementation plan in the following format:

**ステップ生成ルール（必須）**:

> **重要**: この4ルールを無視してテンプレートだけを埋めるのは禁止。Phase 3.2.3 で抽出した `requirement_items` を起点とし、全項目をステップに変換した上で以下のテンプレートに当てはめること。

1. **全要件カバレッジ**: Phase 3.2.3 で抽出した `requirement_items` の **全項目** に対応するステップを生成し、テーブルの `対応ステップ` 列を埋める。1件でも未カバーがあれば、対応ステップを追加するまで Phase 3.3 を完了させない。
2. **非コードタスクもステップ化**: `non_code_task` 種別の要件は「注意点・考慮事項」ではなく **実装ステップ** として依存グラフに含める。例: 「Playwright でスクリーンショット撮影 → LLM に目視検証依頼」を S{n} として配置し、検証基準（撮影ファイルの存在、差分検出 等）を持たせる。
3. **検証基準の必須化**: 各ステップの `検証基準` 列は 3.2.2 のガイドラインに従い、ツール検証可能な条件を記述する。主観的・曖昧な基準は不可。
4. **未カバー検出時のフィードバック**: 計画ドラフト生成後、`requirement_items` テーブルの `対応ステップ` 列を再確認し、空欄が残っていればステップを追加する。**Phase 3.3 の完了条件**: `requirement_items` テーブルの `対応ステップ` 列に空欄がないこと。**Phase 3.3.1 との関係**: Phase 3.3.1 は Phase 3.3 の完了を前提とした追加の独立検査であり、5観点（要件網羅性以外も含む）から計画を再評価する。両者は責務が異なるため省略不可。

**出力構造のルール**: Phase 3.3 の出力は以下のテンプレートに従う。`### 要件マッピング` セクション（`requirement_items` テーブル）と `### 自己レビュー結果` セクション（Phase 3.3.2 のサマリー）はテンプレート内のプレースホルダーとして配置済みで、それぞれの出力位置はテンプレートで一意に決まる。LLM は散文ルールではなく **このテンプレートを唯一の真実の源（single source of truth）として** 出力構造を決定すること。

```
## 実装計画

### 変更対象ファイル
| ファイル | 変更内容 |
|---------|---------|
| {file_path} | {change_description} |

### 参考実装
| 参考ファイル | 参考理由 |
|-------------|---------|
| {reference_file_path} | {reason} |

#### 参考にすべきパターン
- {pattern_1}
- {pattern_2}

### 実装ステップ（依存グラフ）

| Step | 内容 | depends_on | 並列グループ | 状態 | 検証基準 |
|------|------|------------|-------------|------|---------|
| S1 | {step_1} | — | A | ⬜ | {verification_criteria_1} |
| S2 | {step_2} | — | A | ⬜ | {verification_criteria_2} |
| S3 | {step_3} | S1 | B | ⬜ | {verification_criteria_3} |
| S4 | {step_4} | S1, S2 | C | ⬜ | {verification_criteria_4} |

> **depends_on**: そのステップの前提となるステップ ID（`—` は依存なし＝最初に実行可能）
> **並列グループ**: 同じグループのステップは並列実行可能（依存関係がないため）
> **状態**: `⬜` 未着手 / `✅` 完了 / `⚠️ 再分解` — コミット時に作業メモリコメントへ一括反映される（5.1.1.2 参照）
> **検証基準**: ステップ完了を確認するための具体的な条件。Adaptive Re-evaluation (5.1.0.5) でツールを使って機械的に検証される

### 要件マッピング
<!-- Phase 3.2.3 で抽出した requirement_items テーブルに `対応ステップ` 列を埋めて配置する。全要件→ステップの対応が視覚的に確認可能になる。 -->

| # | 要件 | 種別 | ソース | 対応ステップ |
|---|------|------|--------|-------------|
| R1 | {requirement_1} | {type} | {source} | {step_id} |
| R2 | {requirement_2} | {type} | {source} | {step_id} |

### 注意点・考慮事項
- {consideration_1}
- {consideration_2}

### 自己レビュー結果
<!-- Phase 3.3.1 のループ完了後、Phase 3.3.2 のサマリーをここに埋め込む。レビュー回数・初回指摘数・最終結果・検証観点を記録する。 -->

- レビュー回数: {n} 回
- 初回指摘数: {initial_findings_count} 件
- 最終結果: {final_result}
- 検証観点: 要件網羅性 / メモリ整合性 / 依存関係 / 検証基準品質 / スコープ適合性
```

**Note**: The "参考実装" section is populated from 3.2.1 discovery results. If no references were found, use the "no references" format from 3.2.1.

### 3.3.1 Multi-Perspective Self-Review

> **Reference**: Apply the review quality principles from `feedback_review_quality.md` and `feedback_review_zero_findings.md` in project memory.

**目的**: Phase 3.3 で生成した実装計画ドラフトを、5つの観点から自己レビューする。指摘ゼロまでループを抜けない。これにより「テンプレートは埋まったが要件が抜けている」「依存関係が壊れている」「検証基準が曖昧」といった構造的欠陥を Phase 3.4（ユーザー確認）の前に解消する。

**5つのレビュー観点**:

| # | 観点 | 検査内容 |
|---|------|---------|
| 1 | **要件網羅性** | Phase 3.2.3 の `requirement_items` 全項目に対応ステップが存在するか。`対応ステップ` 列に空欄がないか。非コードタスクが「注意点」ではなく実装ステップとして配置されているか。 |
| 2 | **メモリ整合性** | プロジェクトメモリ（`MEMORY.md` の Feedback / Project エントリ）の関連ルールが計画に反映されているか。例: 「レビュー指摘ゼロまでループ」「ファクトチェック必須」等が必要な場面で計画に含まれているか。 |
| 3 | **依存関係** | `depends_on` 列が正しいか。循環依存がないか。並列グループが論理的に正しい（同グループ内に依存関係がない）か。 |
| 4 | **検証基準品質** | 各ステップの `検証基準` 列が 3.2.2 のガイドラインに準拠し、ツール検証可能（Read/Grep/Glob/Bash）か。主観的・曖昧な基準が含まれていないか。 |
| 5 | **スコープ適合性** | 計画が Issue の `## 2. Scope` の `In Scope` に収まり、`Out of Scope` に侵入していないか。MUST NOT 制約に違反していないか。 |

**ループ条件（必須遵守）**:

```
1. 全5観点でレビュー実施
2. 確信ある指摘を1件以上検出 → 計画を修正 → 全5観点を再実施（部分レビュー禁止）
3. 全5観点で確信ある指摘がゼロ → ループ終了 → Phase 3.3.2 へ
```

**レビュー品質ガード**:

- **確信ある指摘のみカウント**: 推測（「もしかしたら〇〇かも」）や「念のため」の指摘はカウントしない。証拠（具体的な要件・ルール・行・列）を伴う指摘のみが有効。
- **回数上限なし**: 自己レビューループに回数制限を設けない。指摘ゼロが唯一の終了条件。
- **全観点の再実施**: 修正後は変更箇所のみの部分レビューではなく、必ず全5観点を最初から再実施する（修正が他観点に影響している可能性があるため）。
- **スコープ外の指摘は記録のみ**: スコープ外の改善余地は計画には反映せず、「決定事項・メモ」に「Issue 化候補」として記録する。

**指摘の記録形式**:

各レビュー実施時は、以下の形式で会話コンテキストに記録する:

```markdown
#### 自己レビュー サイクル {n}

| # | 観点 | 指摘内容 | 修正方針 |
|---|------|---------|---------|
| F1 | 要件網羅性 | R3 (Try-catch wrap) に対応ステップなし | S6 を追加: `handleError` を呼び出し元でラップ |
| F2 | 検証基準品質 | S2 の検証基準「正しく動作」が主観的 | Grep で `export.*authMiddleware` を確認する基準に変更 |
```

### 3.3.2 Self-Review Result Summary

Phase 3.3.1 のループ完了後、Phase 3.3.2 のサマリーを実装計画の `### 自己レビュー結果` プレースホルダー（Phase 3.3 のテンプレート末尾に配置済み）に埋め込む。これにより、計画の信頼性と網羅性が会話コンテキストとユーザーに可視化される。テンプレートのプレースホルダーへの埋め込みであり、別途末尾に追加するのではない（二重出力を防ぐ）。

**記録形式**:

```markdown
### 自己レビュー結果

- レビュー回数: {n} 回
- 初回指摘数: {initial_findings_count} 件
- 最終結果: {final_result}
- 検証観点: 要件網羅性 / メモリ整合性 / 依存関係 / 検証基準品質 / スコープ適合性
```

**フィールドの意味**:

| フィールド | 値 |
|-----------|-----|
| `レビュー回数` | Phase 3.3.1 のループを実施した回数（初回 + 修正後再実施の合計） |
| `初回指摘数` | サイクル1で検出された確信ある指摘の合計件数 |
| `最終結果` | Phase 3.3.1 のループが実際に終了した場合のみ「全5観点 pass（指摘ゼロ）」を記入する。ループを実施せずにこの文字列を出力することは禁止。最終サイクル番号 = レビュー回数となるよう一貫性を保つこと |

**Note**: このサマリーは Phase 3.3 のテンプレート末尾の `### 自己レビュー結果` プレースホルダーに埋め込まれ、実装計画の一部としてユーザーに提示される。

### 3.4 User Confirmation

Confirm the plan with `AskUserQuestion`:

```
上記の実装計画で進めますか？

オプション:
- 計画を承認（推奨）
- 計画を修正
- スキップ（計画なしで進める）
```

**Subsequent processing for each option**:

| Option | Subsequent Processing |
|--------|----------------------|
| **Approve plan** | -> Record in work memory in 3.5 -> Proceed to Phase 4 |
| **Modify plan** | Receive additional instructions from user and regenerate plan -> Return to 3.4 |
| **Skip** | Skip 3.5 -> Proceed directly to Phase 4 (plan is not recorded) |

**Note**: Implementation work itself starts after Phase 4 is complete. This phase only handles plan confirmation and recording.

### 3.5 Record in Work Memory

Record the approved plan in the work memory comment.

#### 3.5.1 Re-fetch Comment Body

Re-fetch the work memory comment body immediately before updating. This defends against context compaction that may have discarded the body from Phase 2.6:

```bash
comment_id=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty')
comment_body=$(gh api repos/{owner}/{repo}/issues/comments/${comment_id} --jq '.body')
```

#### 3.5.2 Selective Update

**Critical**: Do NOT reconstruct the entire comment body from context or memory. Use the re-fetched `comment_body` as the base and apply only the modifications listed below.

**Sections to UPDATE:**

| Section | Update Rule |
|---------|------------|
| `最終更新` (in セッション情報) | Replace with current timestamp |
| `コマンド` (in セッション情報) | Set to `rite:issue:start` |
| `フェーズ` (in セッション情報) | Set to `phase3` |
| `フェーズ詳細` (in セッション情報) | Set to `実装計画生成` |
| `次のステップ` | Set to `1. 実装計画に沿って作業開始` |

**Section to ADD/REPLACE:**

| Section | Content |
|---------|---------|
| `実装計画` | Insert the approved plan from Phase 3.3. Place after `### セッション情報` and before `### 進捗サマリー` |
| `計画逸脱ログ` | Add if not present: `_計画逸脱はありません_` |

**Sections to PRESERVE as-is (copy verbatim from existing body):**

- `Issue` / `開始` / `ブランチ` (in セッション情報)
- `進捗サマリー`
- `要確認事項`
- `変更ファイル`
- `決定事項・メモ`
- All other existing sections not listed in the UPDATE/ADD tables above

#### 3.5.3 Update the Comment

> **Reference**: Apply [Work Memory Update Safety Patterns](../../references/gh-cli-patterns.md#work-memory-update-safety-patterns) for all steps below.

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
tmpfile=$(mktemp)
backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
trap 'rm -f "$tmpfile"' EXIT

# 1. Backup before update
printf '%s' "$comment_body" > "$backup_file"
original_length=$(printf '%s' "$comment_body" | wc -c)

# 2. Write the selectively-updated body
printf '%s' "$updated_body" > "$tmpfile"

# 3. Empty body guard (10 bytes = minimum plausible work memory content)
if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
  echo "ERROR: Updated body is empty or too short. Aborting PATCH. Backup: $backup_file" >&2
  exit 1
fi

# 4. Header validation
if grep -q '📜 rite 作業メモリ' "$tmpfile"; then
  : # Header present, proceed
else
  echo "ERROR: Updated body missing work memory header. Restoring from backup." >&2
  cp "$backup_file" "$tmpfile"
  exit 1
fi

# 5. Body length comparison safety check (reject if updated body is less than 50% of original)
updated_length=$(wc -c < "$tmpfile")
if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
  echo "ERROR: Updated body is less than 50% of original (${updated_length}/${original_length}). Aborting PATCH. Backup: $backup_file" >&2
  exit 1
fi

# 6. Safe PATCH with error handling
jq -n --rawfile body "$tmpfile" '{"body": $body}' | gh api repos/{owner}/{repo}/issues/comments/${comment_id} \
  -X PATCH \
  --input -
patch_status=$?
if [[ "${patch_status:-1}" -ne 0 ]]; then
  echo "ERROR: PATCH failed (exit code: $patch_status). Backup saved at: $backup_file" >&2
  exit 1
fi
```

**Implementation note for Claude**: `$updated_body` is the `comment_body` from Phase 3.5.1 with **only** the changes specified in Phase 3.5.2 applied. The `実装計画` section is inserted (or replaced if already present). All other sections must be copied verbatim from the re-fetched body. **Do NOT reconstruct the body from memory — use the re-fetched text as the base.** `$comment_body` is the same re-fetched body used for backup.

#### 3.5.4 Local Work Memory Sync

After updating the Issue comment, sync to the local work memory file:

```bash
WM_SOURCE="plan" \
  WM_PHASE="phase3" \
  WM_PHASE_DETAIL="実装計画生成" \
  WM_NEXT_ACTION="実装計画に沿って作業開始" \
  WM_BODY_TEXT="Implementation plan recorded." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**Notes**:
- By explicitly retrieving the comment ID, the correct comment can be updated even if other comments are added in between
- If the user selects "Skip", skip this phase and proceed to Phase 4

### 3.5.1 Mid-Implementation Replanning (Triggered by Bottleneck Detection)

> **Reference**: [Bottleneck Detection Reference](../../references/bottleneck-detection.md) for thresholds and Oracle discovery protocol.

This section is executed **during Phase 5.1** (not during Phase 3) when the bottleneck detection in [5.1.0.5](./implement.md) triggers step re-decomposition. It defines how re-decomposed sub-steps are integrated back into the implementation plan and work memory.

**Trigger**: Invoked from `implement.md` 5.1.0.5 step 6 (Bottleneck detection) when a threshold is exceeded and the step is re-decomposed into sub-steps.

#### Plan Update Procedure

1. **Replace original step**: In the dependency graph, mark the original step `S{n}` as `re-decomposed` and insert sub-steps `S{n}.1`, `S{n}.2`, etc.
2. **Update dependencies**: Any step that previously depended on `S{n}` now depends on the **last** sub-step (e.g., `S{n}.3` if decomposed into 3 sub-steps)
3. **Retain parallel groups**: Sub-steps with no inter-dependencies can be assigned the same parallel group

#### Work Memory Update

Update the "実装計画" section in work memory to reflect the re-decomposition. This is done at the next bulk update point (commit time) along with other work memory updates, to avoid excessive API calls.

**Updated plan format in work memory**:

```markdown
### 実装計画（更新済み）

| Step | 内容 | depends_on | 並列グループ | 状態 | 検証基準 |
|------|------|------------|-------------|------|---------|
| S1 | {step_1} | — | A | ✅ | {criteria_1} |
| S2 | {step_2} | — | A | ✅ | {criteria_2} |
| ~~S3~~ | ~~{original_step_3}~~ | S1 | B | ⚠️ 再分解 | ~~{criteria_3}~~ |
| S3.1 | {sub_step_1} | S1 | B' | ⬜ | {sub_criteria_1} |
| S3.2 | {sub_step_2} | S3.1 | B' | ⬜ | {sub_criteria_2} |
| S4 | {step_4} | S3.2 | C | 🔒 | {criteria_4} |
```

**Note**: The re-decomposition is also recorded in the "ボトルネック検出ログ" section (see [bottleneck-detection.md](../../references/bottleneck-detection.md#work-memory-recording-format)).

### 3.6 Issue Body Checklist Tracking

If the Issue body has a checklist, record and track it in the work memory.

#### 3.6.1 Checklist Extraction

Extract the checklist from the Issue body (`body`) obtained in Phase 0.1:

**Extraction pattern:**

```
パターン: /^- \[[ xX]\] (.+)$/gm
```

**Note**: Tasklist-format Issue references (`- [ ] #XX`) are used for parent-child Issue detection in Phase 0.3, so they are **excluded** here. Only pure task checklists without Issue references are targeted.

**Exclusion pattern:**

```
パターン: /^- \[[ xX]\] #\d+/gm  # Issue 参照は除外
```

**Extraction example:**

```markdown
## チェックリスト

- [ ] 現在の CLAUDE.md の内容を評価
- [ ] 不要な情報を削除
- [ ] 必要な情報を追加
- [x] Best Practices のフォーマットに準拠
```

The following are extracted from the above:
- `[ ] 現在の CLAUDE.md の内容を評価`
- `[ ] 不要な情報を削除`
- `[ ] 必要な情報を追加`
- `[x] Best Practices のフォーマットに準拠`

#### 3.6.2 Checklist Retention

Retain the extracted checklist in conversation context:

```json
{
  "issue_checklist": {
    "total": 4,
    "completed": 1,
    "items": [
      { "text": "現在の CLAUDE.md の内容を評価", "completed": false },
      { "text": "不要な情報を削除", "completed": false },
      { "text": "必要な情報を追加", "completed": false },
      { "text": "Best Practices のフォーマットに準拠", "completed": true }
    ]
  }
}
```

**Retention purpose:**

1. **Phase 5 implementation completion**: Reflect completion state of relevant tasks in Issue body
2. **PR creation**: Warning display for incomplete tasks
3. **Cleanup**: Confirmation of all tasks complete

#### 3.6.3 Record in Work Memory

If a checklist exists, record it in the "Issue checklist" section of the work memory:

```markdown
### Issue チェックリスト
<!-- Issue 本文のチェックリストを追跡 -->

| # | タスク | 状態 |
|---|--------|------|
| 1 | 現在の CLAUDE.md の内容を評価 | ⬜ |
| 2 | 不要な情報を削除 | ⬜ |
| 3 | 必要な情報を追加 | ⬜ |
| 4 | Best Practices のフォーマットに準拠 | ✅ |
```

**State notation:**
- `⬜`: Incomplete (`- [ ]` in Issue body)
- `✅`: Complete (`- [x]` in Issue body)

#### 3.6.4 When No Checklist Exists

If the Issue body has no checklist, skip this section and do not record in the work memory.

---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0).

Before returning control to the caller, update `.rite-flow-state` to the post-plan phase. This ensures the stop-guard routes correctly even if the caller's 🚨 Mandatory After section is not executed immediately:

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase3_post_plan" \
  --next "rite:issue:implementation-plan completed. Proceed to Phase 4 (work start guidance). Do NOT stop." \
  --if-exists
```

After the flow-state update above, output the appropriate result pattern:

- **Plan approved**: `[plan:approved]`
- **Plan skipped**: `[plan:skipped]`

This pattern is consumed by the orchestrator (`start.md`) to determine the next action.

---

## 🚨 Caller Return Protocol

When this sub-skill completes (plan approved or skipped), control **MUST** return to the caller (`start.md`). The caller **MUST immediately** execute its 🚨 Mandatory After 3 section:

1. Proceed to Phase 4 (work start guidance)

**WARNING**: Implementation has NOT started yet — the plan is just a plan. Stopping here would abandon the workflow before any code changes are made.

**→ Return to `start.md` and proceed to Phase 4 now. Do NOT stop.**
