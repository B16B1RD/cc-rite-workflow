---
name: reviewers
description: |
  rite workflow のレビュアー選定コーディネータ: 変更ファイルパターンから起動すべき専門 reviewer
  agent（Security / Application / DevOps / Test / Dependencies / Prompt Engineer /
  Tech Writer / Code Quality / Error Handling）の選定テーブルと横断ルールを提供する。
  /rite:pr-review から Read でのみ参照される（ユーザー直接起動も Skill ツール invoke もされない）。
  汎用の「コードレビュー」ヘルパーではなく、その語では auto-activate しない。
user-invocable: false
disable-model-invocation: true
---

# Reviewer Skills - Main Coordinator

**Structure**: `SKILL.md` は reviewer 群の coordinator（選定ロジック + 横断テーブル）。各 reviewer は `agents/{reviewer_type}-reviewer.md` の named subagent。8 specialist は heavyweight 構造、`application-reviewer.md` は lens-based（persona + first-suspect lenses + output contract）。

## Invocation

`/rite:pr-review` 実行中に `Read` でロードされる。auto-activate しない。

## Available Reviewers

この表は reviewer file patterns の **SoT**（`pr-review` ステップ 2）。`Agent` 列は spawn する named subagent。追加手順は CONTRIBUTING.md "Adding a New Reviewer"。`agents/` ⇔ Type Identifiers は `reviewer-registry-drift-check.sh` が検査する。
rationale: references/rationale.md#missing-row-gap

| Reviewer | Agent | File Patterns (Primary) |
|----------|------------|-------------------------|
| Security Expert | `security-reviewer.md` | `**/security/**`, `**/auth/**`, `auth*`, `crypto*`, `**/middleware/auth*` |
| Application Expert | `application-reviewer.md` | `**/api/**`, `**/routes/**`, `**/handlers/**`, `**/controllers/**`, `**/services/**`, `openapi.*`, `swagger.*`, `**/*.css`, `**/*.scss`, `**/styles/**`, `**/components/**`, `*.jsx`, `*.tsx`, `*.vue`, `**/*.sh`, `**/hooks/**`, `**/db/**`, `**/models/**`, `**/migrations/**`, `**/*.sql`, `prisma/**`, `drizzle/**`; `**/*.ts`, `**/*.rs`, `**/*.go` with `interface`, `type`, `enum`, `class`, `struct` |
| DevOps Expert | `devops-reviewer.md` | `.github/**`, `Dockerfile*`, `docker-compose*`, `*.yml` (CI), `Makefile` |
| Test Expert | `test-reviewer.md` | `**/*.test.*`, `**/*.spec.*`, `**/test/**`, `**/__tests__/**`, `jest.config.*`, `vitest.config.*`, `cypress/**`, `playwright/**` |
| Dependencies Expert | `dependencies-reviewer.md` | `package.json`, `*lock*`, `requirements.txt`, `Pipfile`, `go.mod`, `Cargo.toml` |
| Prompt Engineer | `prompt-engineer-reviewer.md` | `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, and corresponding `.mdx` (`commands/**/*.mdx`, `skills/**/*.mdx`, `agents/**/*.mdx`) |
| Technical Writer | `tech-writer-reviewer.md` | `**/*.md` (excluding `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`), `**/*.mdx` (excluding `commands/**/*.mdx`, `skills/**/*.mdx`, `agents/**/*.mdx`), `docs/**`, `documentation/**`, `**/README*`, `CHANGELOG*`, `CONTRIBUTING*`, `*.rst`, `*.adoc`, `i18n/**/*.md`, `i18n/**/*.mdx` (excluding `plugins/rite/i18n/**` — rite plugin's own translations are dogfooding artifacts) |
| Error Handling Expert | `error-handling-reviewer.md` | Files containing `try`, `catch`, `throw`, `Error`, `reject`, `fallback` keywords (JS/TS); `set -e`, `pipefail`, `trap`, `|| true`, `|| :`, `2>/dev/null` keywords (Bash); `**/*.sh` |

**Note**: Technical Writer 行の File Patterns は `doc_file_patterns` の **SoT**。`pr-review` ステップ 1.2.7 はこの行を読む。
rationale: references/rationale.md#doc-file-patterns-sot

**Code Quality co-reviewer rule**:

1. **Code block co-reviewer**: Prompt Engineer 対象の `.md` に fenced code（` ```bash ` / ` ```sh ` / ` ```yaml ` 等）があるとき、Code Quality を追加する
2. **Sole reviewer guard**: Phase 2.3 後に reviewer がちょうど 1 人なら Code Quality を追加する。2+ 人、または Code Quality 自身が sole（fallback）のときは発火しない
rationale: references/rationale.md#code-quality-co-reviewer

**Emoji usage policy**: Emojis are used only for the following visibility purposes. Individual reviewer Findings output must not use emojis:
- Unified report header (`📜 rite レビュー結果`)
- Work memory identifier (`📜 rite 作業メモリ`)
- Important warning display (`⚠️ 矛盾する指摘を検出`)

**Language policy**: Section headings use English; descriptions and notes use Japanese. Pattern descriptions in tables may use Japanese for brevity.

## Finding Quality Policy

Finding Quality Policy の SoT は [`agents/_reviewer-base.md`](../../agents/_reviewer-base.md)。`{shared_reviewer_principles}` として `pr-review` ステップ 4.5 が注入する。各 reviewer の checklist は `agents/{reviewer_type}-reviewer.md`。
rationale: references/rationale.md#finding-quality-location

> **Reference**: See [Finding Examples](./references/finding-examples.md) for concrete Few-shot examples of good findings, findings that should NOT be reported, and borderline judgment cases.

## Reviewer Type Identifiers

Mapping of reviewer identifiers (`reviewer_type`) to display names. Update this table when adding new reviewers (full procedure: CONTRIBUTING.md "Adding a New Reviewer"; row/slug consistency is machine-checked by `reviewer-registry-drift-check.sh`).

| reviewer_type | 日本語表示名 | Agent |
|---------------|-------------|------------|
| security | セキュリティ専門家 | `security-reviewer.md` |
| application | アプリケーション専門家 | `application-reviewer.md` |
| devops | DevOps 専門家 | `devops-reviewer.md` |
| test | テスト専門家 | `test-reviewer.md` |
| dependencies | 依存関係専門家 | `dependencies-reviewer.md` |
| prompt-engineer | プロンプトエンジニア | `prompt-engineer-reviewer.md` |
| tech-writer | テクニカルライター | `tech-writer-reviewer.md` |
| code-quality | コード品質専門家 | `code-quality-reviewer.md` |
| error-handling | エラーハンドリング専門家 | `error-handling-reviewer.md` |

**Note**: この表が SoT。`pr-review` も参照する。`code-quality` は no-match fallback、fenced-code co-reviewer、sole reviewer guard（上記規則）。

## Legacy Reviewer Type Aliases

api / frontend / performance / database / type-design の 5 reviewer は `application` に統合された。旧 reviewer_type が入力として現れた場合（rite-config.yml の設定値、過去のレビュー結果 JSON の `reviewer` フィールド、ユーザーの手動指定など）は、**silent skip せず** WARNING を表示して統合先 type で代替実行する:

| Legacy reviewer_type | 統合先 |
|---------------------|--------|
| `api` | `application` |
| `frontend` | `application` |
| `performance` | `application` |
| `database` | `application` |
| `type-design` | `application` |

表示形式: `WARNING: reviewer type '{legacy_type}' は 'application' に統合されました。application-reviewer で代替実行します`（対応表は CHANGELOG の移行表を参照）。

## Reviewer Selection Algorithm

### Phase 1: File Pattern Matching

```text
For each changed file:
  1. Match against all reviewer patterns
  2. Collect matching reviewers
  3. Track file count per reviewer
```

**"changed file" の定義は review cycle で変わる**（`skills/pr-review/SKILL.md` ステップ 1.2.4 の `REVIEW_CYCLE_SCOPE` marker が決める。パターン表そのものは変わらない — 変わるのは表に照合させる入力だけ）:

| `REVIEW_CYCLE_SCOPE` | Phase 1 の "changed file" |
|---|---|
| `full`（cycle 1 / fail-safe） | PR 全体の変更ファイル |
| `incremental`（cycle 2+） | 前回レビュー起点からの fix diff (`git diff --name-only {cycle_base_sha}..HEAD`) |

`incremental` では、Phase 1 の結果に**前サイクルで blocking を出した reviewer を `selection_type: mandatory` として合流**させる（Phase 5 が落とさないことを保証しているのは `mandatory` のみのため）。設計根拠: [`cycle-scope.md`](../pr-review/references/cycle-scope.md)。
rationale: references/rationale.md#incremental-mandatory-merge

### Phase 2: Content Analysis (Optional)

```text
Analyze diff content for:
  - Security keywords (representative): password, token, secret, auth, crypto, hash, encrypt, decrypt, credential, api_key, private_key, cert
  - Performance keywords (representative): cache, async, await, promise, worker
  - Data keywords (representative): query, migration, schema, index, transaction
  - Error handling keywords (representative): try, catch, throw, Error, reject, fallback, finally (JS/TS); set -e, pipefail, trap, || true, || :, 2>/dev/null (Bash)
  - Type design keywords (representative): interface, type, enum, class, struct, readonly, generic
```

**Note**: The above are representative keyword examples. The authoritative keyword list is defined in `skills/pr-review/SKILL.md` ステップ 2.3 ("Security keyword detection" section), and the authoritative file patterns are the Available Reviewers table above.

### Phase 3: Select All Matching Reviewers

```text
Select all reviewers that:
  1. Match file patterns from Phase 1
  2. Match content keywords from Phase 2 (if enabled)

No prioritization by file count.
All matching reviewers are selected.
(Phase 5 narrows this set down to max_reviewers when the count exceeds the cap.)
```

### Phase 4: Apply Minimum Limit

```text
Apply constraints from rite-config.yml:
  - min_reviewers: Minimum reviewers to select

Special rules:
  - Security reviewer inclusion depends on rite-config.yml security_reviewer settings (see skills/pr-review/SKILL.md ステップ 3.2)
  - If no reviewers match, use code-quality reviewer as fallback (min_reviewers)
```

**Note**: For detailed mandatory selection conditions for Security Expert, see [`skills/pr-review/SKILL.md` ステップ 3.2 (Reviewer Selection)](../../skills/pr-review/SKILL.md#32-reviewer-selection).

### Phase 5: Apply Maximum Limit (Cost Control)

本 Phase は Phase 4 の **後** に適用する。cap が minimum floor や `mandatory` を破らない。
rationale: references/rationale.md#phase5-cap

```text
Apply constraints from rite-config.yml:
  - max_reviewers: Maximum reviewers to spawn (default: 6)

Relevance ordering (used only when narrowing is required):
  1. matched file count per reviewer (from Phase 1 "Track file count per reviewer") — higher is more relevant
  2. tie-break by selection_type: mandatory > recommended > detected > normal
       (`normal` = a reviewer selected purely by pattern/content match, with no mandatory/recommended/detected
        promotion; the three named types are defined in `skills/pr-review/SKILL.md` ステップ 3.2 Selection Type table)
  3. final tie-break by Available Reviewers table order (higher row = higher priority)

Cap logic:
  - selected count <= effective_max  -> keep all (no narrowing, no omission display)
  - selected count >  effective_max  -> sort by the relevance ordering above, keep the top effective_max, drop the rest
      * NEVER drop a reviewer whose selection_type is `mandatory` (Security Expert when `mandatory: true`,
        a Doc-Heavy-promoted tech-writer, or a fenced-block-triggered code-quality co-reviewer — see ステップ 2.2.1 / 3.2).
        If a mandatory reviewer would fall outside the top N, drop the next-lowest non-mandatory reviewer instead.
      * If the mandatory reviewer count alone already exceeds effective_max, keep ALL mandatory reviewers
        (intentionally exceed the cap) and drop non-mandatory reviewers down to zero. Never drop a mandatory
        reviewer to satisfy the cap — the cost cap yields to the mandatory guarantee, not the other way around.
      * NEVER reduce below the effective floor = max(min_reviewers, sole_reviewer_guard_floor). The Phase 4
        min_reviewers floor wins, AND the ステップ 2.3 sole-reviewer guard's floor wins: when that guard raised
        the set to 2 to avoid a single-reviewer blind spot, the cap keeps at least 2. A `max_reviewers` below
        that floor is clamped up to it (the guard's blind-spot protection is not overridable by the cost cap) —
        emit the ステップ 3.2.1 WARNING so the clamp is not silent.
  - MUST display each dropped reviewer's name and matched file count (silent capping is prohibited)

effective_max resolution (config validation):
  - max_reviewers unset            -> default 6
  - max_reviewers non-numeric      -> WARNING, fall back to default 6
  - max_reviewers < min_reviewers  -> WARNING, min_reviewers takes priority (effective_max = min_reviewers)
  - otherwise                      -> effective_max = max_reviewers
  - complexity lane bound          -> when COMPLEXITY_LANE == light (Issue Complexity XS / S, resolved by
        `skills/pr-review/SKILL.md` ステップ 1.3.2), take the tighter of the two:
        effective_max = min(effective_max, complexity_max) where complexity_max = 3.
        Applied BEFORE the final clamp, so the floors below still win. When COMPLEXITY_LANE is
        `full` (M / L / XL) or the lane could not be resolved, this line is a no-op and the
        resolution is byte-identical to the pre-lane behavior.
  - final clamp (all paths)        -> effective_max = max(effective_max, min_reviewers)
        (guarantees effective_max >= min_reviewers even for the unset/non-numeric paths when min_reviewers > 6)

When matched count <= effective_max (e.g. the default 6 with fewer matches), the selection is
identical to the pre-cap behavior (backward compatible).
```

rationale: references/rationale.md#complexity-lane-bound
値 3・境界 `{XS, S}`・新 floor を置かない理由: [complexity-lane.md](../pr-review/references/complexity-lane.md#reviewer-上限を-phase-5-に置く理由)。

The dropped-reviewer list and the pre-spawn summary are rendered by `skills/pr-review/SKILL.md` ステップ 3.2.1 (cap application) / ステップ 3.3 (Confirm Reviewers).

## Selection Result Retention

reviewer 一覧とファイル件数だけ返す。JSON は出さない。Phase 2 完了時に選定結果を記憶し、Phase 4 で Task `prompt`（`pr-review` ステップ 4.5）へ埋め込む。大規模 PR のコンテキスト管理は [context-management.md](./references/context-management.md)。profile は named-subagent system prompt（`agents/{reviewer_type}-reviewer.md`）。ステップ 4.5 の user prompt は per-review 入力のみ。

## Generator-Critic Pattern Integration

- **Generator** = `pr-review` **ステップ 4**
- **Critic** = `pr-review` **ステップ 5**
rationale: references/rationale.md#generator-critic

## Cross-Validation Logic

Logic to validate and integrate results from multiple reviewers.

See [references/cross-validation.md](./references/cross-validation.md) for details.

### Quick Reference

- Multiple reviewers flag same file/line → severity +1
- Contradiction between reviewers → request user judgment
- All reviewers pass → high-confidence approval

## Output Aggregation

For review result output format, see [references/output-format.md](./references/output-format.md).

### Quick Reference

**Individual Reports:** Each reviewer generates Domain-Specific Analysis + Findings table + Summary

**Unified Report:** Coordinator integrates Overall Assessment + Reviewer Consensus + Cross-Validated Findings

**Findings table format (common):**

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| {level}  | {scope} | {location}| {WHAT + WHY} | {FIX + EXAMPLE} |

The `Scope` column accepts `current-pr` / `follow-up` / `nit-noted` (schema 1.1.0+). See [_reviewer-base.md Scope Assignment Flowchart](../../agents/_reviewer-base.md#scope-assignment-flowchart) for assignment rules and the [Severity × Scope Matrix](../../references/severity-levels.md#severity--scope-matrix) for forbidden combinations.

## Error Handling

### Reviewer Subagent Resolution Failure

```
If `rite:{reviewer_type}-reviewer` cannot be resolved (named subagent missing):
  1. Log warning
  2. Skip that reviewer
  3. Continue with remaining reviewers
```

### Reviewer Timeout

**Note**: Task tool timeout is managed internally by Claude Code. Users cannot directly specify a `timeout` parameter.

```
If reviewer task exceeds internal timeout:
  1. Task tool returns an error
  2. Mark the reviewer as "incomplete"
  3. Continue with other reviewers' results
  4. Note "{reviewer_type}: タイムアウト" in unified report
```

### No Reviewers Match

When no file patterns match, use code-quality reviewer as fallback. Security Expert inclusion follows `rite-config.yml` settings (see `skills/pr-review/SKILL.md` ステップ 3.2).

```text
If no file patterns match:
  1. Use code-quality reviewer as fallback (min_reviewers)
  2. Apply Security Expert selection rules from rite-config.yml (see skills/pr-review/SKILL.md ステップ 3.2)
  3. Warn user about limited review scope
  4. Suggest manual reviewer selection if needed
```
