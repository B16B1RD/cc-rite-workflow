# rite workflow レビュアー品質向上（pr-review-toolkit 参考）

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

rite workflow の PR レビュアーシステムの品質を向上させる。具体的には、agent 定義ファイルの自己完結型再構築、cross-file impact check の導入、確信度スコアリングによる内部フィルタリング、新規 reviewer 2種（error-handling, type-design）の追加、および review.md Phase 4.5 テンプレートへの `{agent_identity}` プレースホルダー追加を行う。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

PR #285 のレビューで品質差が明確に出た:

- **rite workflow**: 1 LOW（use_context7 の stale 変更）のみ検出。CRITICAL（safety 分類矛盾）、cross-file 不整合（commit.style）を見逃し
- **pr-review-toolkit (verified-review)**: 8件検出。1 Critical（cross-file 不整合）、2 Important（split i18n、orphaned キー）含む

### Root Cause

| # | Root Cause | 影響 |
|---|-----------|------|
| RC1 | agent 定義が薄い（~28行のスタブ）— 「skill ファイルを読め」と言うだけで検出プロセスが agent 自体にない | agent が Task tool で起動されたとき、何をどう調べるかの指針がない |
| RC2 | 体系的な検出ワークフローがない — チェックリストはあるが「何を探し、どう分析するか」のプロセスがない | 検出が網羅的でなく、見つけやすい問題だけ報告する傾向 |
| RC3 | cross-file 参照チェックが設計に含まれない | 依存関係の破壊を検出できない |
| RC4 | agent にアイデンティティ・マインドセットがない | レビューの深さと姿勢が不足 |

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

1. **agent 定義の自己完結型再構築（D1）**: 各 agent ファイルを ~28行 → 60-100行に拡充。Identity + Core Principles + Detection Process + Confidence Calibration をインラインで記述
2. **cross-file impact check（D2）**: `_reviewer-base.md` に汎用原則として追加。変更されたキー/関数/設定が他ファイルで参照されていないか Grep で確認を必須ステップに
3. **確信度スコアリング（D3）**: 0-100 の確信度を agent の行動指針として追加。80以上のみ指摘事項テーブルに含め、60-79 は推奨事項に記載。出力テーブル列構造は変更しない
4. **新規 reviewer 追加（D4）**: error-handling-reviewer（silent-failure-hunter 相当）と type-design-reviewer（type-design-analyzer 相当）を新規作成
5. **`{agent_identity}` プレースホルダー（D7）**: review.md Phase 4.5 テンプレートに追加。agent の Identity + Core Principles + Detection Process + Confidence Calibration を sub-agent prompt に埋め込む
6. **WebSearch/WebFetch ツール追加（D6）**: security-reviewer と dependencies-reviewer に CVE チェック、ライセンス確認用の外部検索ツールを追加
7. **config 追加**: `review.confidence_threshold: 80` を `rite-config.yml` に追加

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

1. **fix.md 互換性**: テーブル列構造 `| 重要度 | ファイル:行 | 内容 | 推奨対応 |` は変更不可（fix.md L240 パーサーとの互換性維持）
2. **コンテキスト消費**: agent 本文は 40-70行程度。diff + checklist に比べれば小さく、Large scale PR でも review-context-optimization.md の既存最適化で対処可能
3. **「全指摘は必須修正」ポリシー維持（D5）**: 確信度フィルタで低品質指摘の流入を防止。assessment-rules.md, fix ループ, start.md の変更不要

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

| # | 決定 | 理由 |
|---|------|------|
| D1 | agent ファイルを自己完結型に再構築（60-100行） | RC1, RC2, RC4 を直接解決 |
| D2 | `_reviewer-base.md` に cross-file impact check を汎用原則として追加 | RC3 を全 reviewer で解決 |
| D3 | 確信度スコア（0-100）は内部フィルタのみ、出力テーブル列は変更しない | fix.md L240 パーサー互換性維持 |
| D4 | 新規 reviewer 2種: error-handling, type-design | pr-review-toolkit の最も効果的な 2 agent |
| D5 | 「全指摘は必須修正」ポリシーは維持 | 確信度フィルタで低品質指摘の流入を防止 |
| D6 | security, dependencies に WebSearch/WebFetch ツール追加 | CVE チェック、ライセンス確認に必要 |
| D7 | Phase 4.5 テンプレートに `{agent_identity}` プレースホルダー追加 | agent 拡充内容を sub-agent に確実に到達させる |

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

| コンポーネント | ファイル | 役割 |
|---------------|---------|------|
| Reviewer Base | `agents/_reviewer-base.md` | 全 reviewer 共通の Mindset + Cross-File Check + 確信度フィルタ + 出力フォーマット |
| Agent 定義 (既存11種) | `agents/{type}-reviewer.md` | 各ドメイン固有の Identity + Principles + Detection Process + Calibration |
| Agent 定義 (新規2種) | `agents/error-handling-reviewer.md`, `agents/type-design-reviewer.md` | エラーハンドリング専門 / 型設計専門 |
| Skill 定義 (新規2種) | `skills/reviewers/error-handling.md`, `skills/reviewers/type-design.md` | チェックリスト + Activation 条件 |
| Review コマンド | `commands/pr/review.md` | Phase 4.5 テンプレートに `{agent_identity}` を追加 |
| Config | `rite-config.yml` | `review.confidence_threshold` 設定 |
| リファレンス | `references/finding-examples.md` 等 | 確信度キャリブレーション例等 |

### Agent 定義ファイルの新構造

```
---
name / description / model / tools
---
# {Reviewer Name}

{Identity statement: 2-3文}

## Core Principles
{3-5 の非妥協ルール}

## Detection Process
### Step 1-N: {体系的検出ワークフロー}
（最後の Step は必ず Cross-File Impact Check）

## Confidence Calibration
{ドメイン固有のスコアリング指針 + 具体例 2-3個}

## Detailed Checklist
Read `plugins/rite/skills/reviewers/{type}.md` for the full checklist.

## Output Format
Read `plugins/rite/agents/_reviewer-base.md` for format specification.
{ドメイン固有の出力例}
```

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

```
review.md Phase 4.3: agent ファイルを Read
  → {agent_identity} を抽出（YAML frontmatter + Output Format/Checklist セクションを除いた本文）
  → Phase 4.5 テンプレートに埋め込み
  → Task tool で sub-agent に渡される
  → sub-agent は Identity + Detection Process に従い体系的にレビュー
  → 確信度 80 以上のみ指摘事項テーブルに出力
```

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

**P0（前提条件 — 最初に実装）:**
- `plugins/rite/commands/pr/review.md`: Phase 4.5 テンプレートに `{agent_identity}` プレースホルダー追加 + Phase 4.3 での抽出ロジック追加 + Phase 4.5.1 verification テンプレートも同様に更新
- `plugins/rite/agents/_reviewer-base.md`: Reviewer Mindset + Cross-File Impact Check + Confidence Scoring 追加（36行 → ~70行）
- `plugins/rite/agents/code-quality-reviewer.md`: 自己完結型再構築（28行 → ~85行）
- `plugins/rite/agents/prompt-engineer-reviewer.md`: 自己完結型再構築（28行 → ~85行）
- `rite-config.yml`: `review.confidence_threshold: 80` 追加

**P1（主要 agent）:**
- `plugins/rite/agents/security-reviewer.md`: 再構築 + WebSearch/WebFetch ツール追加
- `plugins/rite/agents/test-reviewer.md`: 再構築

**P2（残り agent + 新規）:**
- `plugins/rite/agents/api-reviewer.md`: 再構築
- `plugins/rite/agents/database-reviewer.md`: 再構築
- `plugins/rite/agents/dependencies-reviewer.md`: 再構築 + WebSearch/WebFetch ツール追加
- `plugins/rite/agents/devops-reviewer.md`: 再構築
- `plugins/rite/agents/frontend-reviewer.md`: 再構築
- `plugins/rite/agents/performance-reviewer.md`: 再構築
- `plugins/rite/agents/tech-writer-reviewer.md`: 再構築
- `plugins/rite/agents/error-handling-reviewer.md`: 新規作成
- `plugins/rite/agents/type-design-reviewer.md`: 新規作成
- `plugins/rite/skills/reviewers/error-handling.md`: 新規作成
- `plugins/rite/skills/reviewers/type-design.md`: 新規作成
- `plugins/rite/skills/reviewers/SKILL.md`: 2 reviewer 追加
- `plugins/rite/references/finding-examples.md`: 確信度キャリブレーション例追加
- `plugins/rite/references/reviewer-fallbacks.md`: フォールバック追加

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

1. **実行順序の依存関係**: review.md Phase 4.5 の `{agent_identity}` がないと、拡充した agent 内容が sub-agent prompt に到達しない。review.md を最初に更新すること
2. **fix.md パーサー互換性**: テーブル列 `| 重要度 | ファイル:行 | 内容 | 推奨対応 |` を変更すると fix.md L240 のパーサーが壊れる
3. **確信度閾値のチューニング**: デフォルト 80 で運用開始し、false positive/negative のバランスを見て調整
4. **Phase 4.5.1 テンプレート**: verification mode テンプレートにも `{agent_identity}` を追加する必要がある
5. **`{agent_identity}` と既存プレースホルダーの役割分担**: `{agent_identity}` = マインドセット + 原則 + 検出プロセス + 確信度基準、`{skill_profile}` = 専門領域説明、`{checklist}` = チェック項目。3つは相互補完的で重複しない

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

1. assessment-rules.md の変更（「全指摘は必須修正」ポリシー維持）
2. fix.md の変更（テーブル列構造維持によりパーサー変更不要）
3. start.md の変更
4. 出力テーブルへの確信度列追加（内部フィルタのみ）
5. sprint-teammate.md の変更（reviewer agent とは別の agent）
