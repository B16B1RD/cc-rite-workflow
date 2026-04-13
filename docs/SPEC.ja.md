# Claude Code Rite Workflow 仕様書

> 汎用 Issue ドリブン開発ワークフロー Claude Code プラグイン

## 概要

**Claude Code Rite Workflow** は、Issue ドリブン開発ワークフローを提供する汎用 Claude Code プラグインです。
言語・フレームワークに依存せず、あらゆるソフトウェア開発プロジェクトで利用できます。

### 設計原則

- **Rite**: 一貫性と再現性を保証する構造化されたプロセス
- **汎用性**: 特定の技術スタックに依存しない
- **自動化**: 可能な限り自動検出・自動設定
- **カスタマイズ性**: 設定ファイルによる柔軟な調整

### 命名の由来

コマンドプレフィックス `rite` は以下の理由で採用:

1. **意味**: rite（儀式・プロセス）- 一貫性と再現性を保証する構造化されたワークフロー
2. **実用性**: 短く（4文字）、タイプしやすく、コマンドプレフィックスとして識別しやすい
3. **商標**: 一般的な英単語のため商標リスクが低い

---

## 目次

1. [コマンド一覧](#コマンド一覧)
2. [ワークフロー全体図](#ワークフロー全体図)
3. [プラグイン構造](#プラグイン構造)
4. [設定ファイル仕様](#設定ファイル仕様)
5. [各コマンド仕様](#各コマンド仕様)
6. [Iteration/スプリント管理（オプション）](#iterationスプリント管理オプション)
7. [フック仕様](#フック仕様)
8. [機能](#機能)
9. [通知連携](#通知連携)
10. [ビルド・テスト・リント自動検出](#ビルドテストリント自動検出)
11. [動的レビュアー生成](#動的レビュアー生成)
12. [Workflow Incident Detection](#workflow-incident-detection)
13. [エラーハンドリング](#エラーハンドリング)
14. [マイグレーション](#マイグレーション)
15. [多言語対応](#多言語対応)
16. [依存関係](#依存関係)
17. [配布方法](#配布方法)
18. [プロジェクト種別](#プロジェクト種別)

---

## コマンド一覧

| コマンド | 説明 | 引数 |
|---------|------|------|
| `/rite:init` | 初回セットアップウィザード | なし |
| `/rite:getting-started` | 対話型オンボーディングガイド | なし |
| `/rite:workflow` | ワークフロー全体の案内 | なし |
| `/rite:investigate` | 構造化コード調査 | `<トピックまたは質問>` |
| `/rite:issue:list` | Issue 一覧表示 | `[フィルタ条件]` |
| `/rite:issue:create` | 新規 Issue 作成 | `<タイトルまたは説明>` |
| `/rite:issue:start` | 作業開始（一気通貫: ブランチ → 実装 → PR） | `<Issue 番号>` |
| `/rite:issue:update` | 作業メモリ更新 | `[メモ]` |
| `/rite:issue:close` | Issue 完了確認 | `<Issue 番号>` |
| `/rite:issue:edit` | 既存 Issue の内容を対話的に修正 | `<Issue 番号>` |
| `/rite:pr:create` | ドラフト PR 作成 | `[PR タイトル]` |
| `/rite:pr:ready` | Ready for review に変更 | `[PR 番号]` |
| `/rite:pr:review` | マルチレビュアーレビュー | `[PR 番号]` |
| `/rite:pr:fix` | レビュー指摘対応 | `[PR 番号]` |
| `/rite:pr:cleanup` | マージ後クリーンアップ | `[ブランチ名]` |
| `/rite:lint` | 品質チェック実行 | `[ファイルパス]` |
| `/rite:template:reset` | テンプレート再生成 | `[--force]` |
| `/rite:sprint:list` | Sprint/Iteration 一覧表示 | `[--all\|--current\|--past]` |
| `/rite:sprint:current` | 現在のスプリント詳細表示 | なし |
| `/rite:sprint:plan` | スプリント計画実行 | `[current\|next\|"Sprint名"]` |
| `/rite:sprint:execute` | Sprint 内の Todo Issue を連続実行 | `[Sprint名]` |
| `/rite:sprint:team-execute` | Sprint 内の Todo Issue を並列チーム実行 | `[Sprint名]` |
| `/rite:wiki:init` | Experience Wiki の初期化（ブランチ・ディレクトリ・テンプレート） | なし |
| `/rite:wiki:query` | キーワードで Wiki ページを検索し経験則をコンテキストに注入 | `<キーワード>` |
| `/rite:wiki:ingest` | Raw Source から経験則を抽出し Wiki ページを更新 | `[source]` |
| `/rite:wiki:lint` | Wiki ページの矛盾・陳腐化・孤児・壊れた相互参照をチェック | `[--auto] [--stale-days <N>]` |
| `/rite:resume` | 中断した作業を再開 | `[issue番号]` |
| `/rite:skill:suggest` | コンテキストを分析して適用可能なスキルを提案 | `[--verbose\|--filter]` |

---

## ワークフロー全体図

```
/rite:init (初回セットアップ)
    │
    ▼
/rite:issue:list (Issue 確認)
    │
    ▼
/rite:issue:create (新規 Issue 作成)
    │                         Status: Todo
    ▼
/rite:issue:start (作業開始)
    │                         Status: In Progress
    │
    ├── ブランチ作成
    ├── 実装計画生成
    ├── 実装作業
    ├── /rite:lint (品質チェック)
    ├── /rite:pr:create (ドラフト PR 作成)
    ├── /rite:pr:review (セルフレビュー)
    ▼
/rite:pr:fix (レビュー指摘対応) ←────┐
    │                              │
    ▼                              │
/rite:pr:ready (Ready for review)   │
    │                         Status: In Review
    │                              │
    └── (修正依頼時) ──────────────┘
    ▼
PR マージ
    │
    ▼
/rite:pr:cleanup (マージ後クリーンアップ)
    │                         Status: Done
    ▼
Issue 自動クローズ
```

**補足:** `/rite:issue:start` は、ブランチ作成からレビュー修正までを一気通貫で処理します。「実装を開始する」を選択すると、実装、品質チェック、ドラフト PR 作成、セルフレビュー、レビュー修正まで自動的に進行します。詳細は [Phase 5: 一気通貫実行](#phase-5-一気通貫実行) を参照してください。

**Status 遷移:**
```
Todo → In Progress → In Review → Done
```

---

## プラグイン構造

```
rite-workflow/
├── .claude-plugin/
│   └── plugin.json          # プラグインメタデータ
├── commands/
│   ├── init.md              # /rite:init
│   ├── getting-started.md   # /rite:getting-started
│   ├── workflow.md          # /rite:workflow
│   ├── issue/
│   │   ├── list.md          # /rite:issue:list
│   │   ├── create.md        # /rite:issue:create
│   │   ├── start.md         # /rite:issue:start
│   │   ├── update.md        # /rite:issue:update
│   │   ├── close.md         # /rite:issue:close
│   │   └── completion-report.md  # 完了報告フォーマット
│   ├── pr/
│   │   ├── create.md        # /rite:pr:create
│   │   ├── ready.md         # /rite:pr:ready
│   │   ├── review.md        # /rite:pr:review
│   │   ├── fix.md           # /rite:pr:fix
│   │   ├── cleanup.md       # /rite:pr:cleanup
│   │   └── references/
│   │       ├── assessment-rules.md        # レビュー評価ルール
│   │       ├── archive-procedures.md      # アーカイブ手続き
│   │       ├── review-context-optimization.md  # レビューコンテキスト最適化
│   │       ├── reviewer-fallbacks.md      # レビュアーフォールバックプロファイル
│   │       ├── change-intelligence.md     # 変更インテリジェンス
│   │       └── fix-relaxation-rules.md    # 修正緩和ルール
│   ├── lint.md              # /rite:lint
│   ├── resume.md            # /rite:resume
│   ├── skill/
│   │   └── suggest.md       # /rite:skill:suggest
│   ├── sprint/
│   │   ├── list.md          # /rite:sprint:list
│   │   ├── current.md       # /rite:sprint:current
│   │   ├── plan.md          # /rite:sprint:plan
│   │   ├── execute.md       # /rite:sprint:execute
│   │   └── team-execute.md  # /rite:sprint:team-execute
│   └── template/
│       └── reset.md         # /rite:template:reset
├── agents/
│   ├── security-reviewer.md        # セキュリティ脆弱性検出
│   ├── performance-reviewer.md     # パフォーマンス問題検出
│   ├── code-quality-reviewer.md    # コード品質レビュー
│   ├── api-reviewer.md             # API 設計レビュー
│   ├── database-reviewer.md        # データベーススキーマ/クエリレビュー
│   ├── devops-reviewer.md          # インフラ/CI-CD レビュー
│   ├── frontend-reviewer.md        # UI/アクセシビリティレビュー
│   ├── test-reviewer.md            # テスト品質レビュー
│   ├── dependencies-reviewer.md    # 依存関係セキュリティレビュー
│   ├── prompt-engineer-reviewer.md # スキル/コマンド/エージェント定義レビュー
│   ├── tech-writer-reviewer.md     # ドキュメントレビュー
│   ├── error-handling-reviewer.md  # エラーハンドリングレビュー
│   ├── type-design-reviewer.md     # 型設計レビュー
│   └── sprint-teammate.md          # Sprint チームメンバー
├── skills/
│   ├── rite-workflow/
│   │   ├── SKILL.md         # 自動適用スキル
│   │   └── references/      # コーディング原則、コンテキスト管理
│   └── reviewers/
│       └── SKILL.md         # レビュアースキル + 各レビュー基準
├── hooks/
│   ├── session-start.sh
│   ├── session-end.sh
│   ├── pre-compact.sh
│   ├── stop-guard.sh
│   ├── preflight-check.sh
│   ├── post-compact-guard.sh
│   ├── pre-tool-bash-guard.sh
│   ├── post-tool-wm-sync.sh
│   ├── local-wm-update.sh
│   ├── work-memory-lock.sh
│   ├── work-memory-update.sh
│   ├── work-memory-parse.py
│   ├── cleanup-work-memory.sh
│   ├── state-path-resolve.sh
│   ├── flow-state-update.sh
│   ├── issue-body-safe-update.sh
│   └── notification.sh
├── templates/
│   ├── completion-report.md  # 完了報告フォーマット定義
│   ├── project-types/
│   │   ├── generic.yml
│   │   ├── webapp.yml
│   │   ├── library.yml
│   │   ├── cli.yml
│   │   └── documentation.yml
│   ├── issue/
│   │   └── default.md
│   └── pr/
│       ├── generic.md
│       ├── webapp.md
│       ├── library.md
│       ├── cli.md
│       └── documentation.md
├── scripts/
│   └── create-issue-with-projects.sh  # Issue 作成 + Projects 連携
├── references/
│   ├── gh-cli-patterns.md
│   ├── graphql-helpers.md
│   └── ...                   # その他リファレンス
├── i18n/
│   ├── ja.yml              # 日本語（deprecated、後方互換性のため保持）
│   ├── en.yml              # 英語（deprecated、後方互換性のため保持）
│   ├── ja/                 # 日本語分割ファイル
│   │   ├── common.yml
│   │   ├── issue.yml
│   │   ├── pr.yml
│   │   └── other.yml
│   └── en/                 # 英語分割ファイル
│       ├── common.yml
│       ├── issue.yml
│       ├── pr.yml
│       └── other.yml
└── README.md
```

### plugin.json

プラグインメタデータファイルの形式:

```json
{
  "name": "rite",
  "version": "0.3.10",
  "description": "Universal Issue-driven development workflow for Claude Code",
  "author": { "name": "B16B1RD" },
  "license": "MIT"
}
```

| フィールド | 必須 | 説明 |
|-----------|------|------|
| `name` | はい | プラグイン名（コマンドプレフィックスとして使用） |
| `version` | はい | セマンティックバージョン |
| `description` | はい | 短い説明文 |
| `author` | はい | `name` フィールドを持つ作者オブジェクト |
| `license` | いいえ | ライセンス識別子 |

### コマンドファイル形式

`commands/` 内の各コマンドファイルには YAML フロントマターが必須:

```markdown
---
description: コマンドの短い説明
context: fork  # オプション: 独立したコンテキストで実行
---

# /rite:command-name

コマンドのドキュメント...
```

| フィールド | 必須 | 説明 |
|-----------|------|------|
| `description` | はい | コマンド検出に使用される短い説明 |
| `context` | いいえ | `fork` を設定するとメイン会話コンテキスト不要で実行 |

**context: fork の使用:**

状態を変更せず情報を表示するコマンドは、コンテキスト効率のために `context: fork` を使用:

| コマンド | context: fork | 理由 |
|---------|---------------|------|
| `/rite:issue:list` | ✅ | 情報表示のみ |
| `/rite:sprint:list` | ✅ | 情報表示のみ |
| `/rite:sprint:current` | ✅ | 情報表示のみ |
| `/rite:skill:suggest` | ✅ | 独立した分析 |
| その他 | ❌ | ユーザー対話または状態変更が必要 |

### スキルファイル形式

スキルファイル（`skills/*/SKILL.md`）は自動適用のために YAML フロントマターを使用:

```markdown
---
name: skill-name
description: |
  スキルの目的を説明する複数行の記述。
  自動適用の条件を含める。
---

# スキル名

スキルのドキュメント...
```

| フィールド | 必須 | 説明 |
|-----------|------|------|
| `name` | はい | 一意のスキル識別子 |
| `description` | はい | 適用条件を含む詳細な説明 |

**スキル分類:**

| 分類 | 目的 | 例 |
|------|------|-----|
| Reference Contents | 常に参照可能な知識 | `rite-workflow`（ワークフロールール） |
| Task Contents | 能動的に実行するタスク | `reviewers`（レビュー基準） |

### エージェントファイル形式

エージェントファイル（`agents/*.md`）は専門タスク用のサブエージェントを定義:

```markdown
---
name: agent-name
description: 短い目的の説明
model: opus  # opus | sonnet | haiku (optional — 省略時は親セッションから継承)
---

# エージェント名

エージェントのドキュメント...
```

| フィールド | 必須 | 説明 |
|-----------|------|------|
| `name` | はい | 一意のエージェント識別子 |
| `description` | はい | Task ツール用の短い説明 |
| `model` | いいえ | モデル選択（デフォルト: 親セッションから継承） |
| `tools` | いいえ | 利用可能なツールのリスト（デフォルト: 親セッションの全ツールを継承。省略で全ツール有効） |

**`tools` フィールドに関する注記**: rite plugin のレビュアー agent は現状 `subagent_type: general-purpose` 経由で呼び出されているため、frontmatter の `tools` 値にかかわらず親セッションの全ツールにアクセスできる。将来 named subagent 呼び出しを導入する際に silent なツール制限が発生するのを防ぐため、全レビュアー agent で `tools` フィールドを省略している。

**現在のエージェント:**

| エージェント | モデル | 目的 |
|-------------|--------|------|
| `security-reviewer` | opus | セキュリティ脆弱性、認証、データ処理 |
| `performance-reviewer` | inherit | N+1 クエリ、メモリリーク、アルゴリズム効率 |
| `code-quality-reviewer` | inherit | 重複、命名、エラーハンドリング、構造 |
| `api-reviewer` | opus | API 設計、REST 規約、インターフェース契約 |
| `database-reviewer` | opus | スキーマ設計、クエリ、マイグレーション、データ操作 |
| `devops-reviewer` | opus | インフラストラクチャ、CI/CD パイプライン、デプロイ設定 |
| `frontend-reviewer` | opus | UI コンポーネント、スタイリング、アクセシビリティ、クライアントサイドコード |
| `test-reviewer` | opus | テスト品質、カバレッジ、テスト戦略 |
| `dependencies-reviewer` | opus | パッケージ依存関係、バージョン、サプライチェーンセキュリティ |
| `prompt-engineer-reviewer` | opus | Claude Code のスキル、コマンド、およびエージェント定義 |
| `tech-writer-reviewer` | opus | ドキュメントの明確さ、正確さ、完全性 |
| `error-handling-reviewer` | inherit | エラーハンドリングパターン、サイレント障害、復旧ロジック |
| `type-design-reviewer` | inherit | 型設計、カプセル化、不変条件の表現 |

---

## 設定ファイル仕様

### rite-config.yml

プロジェクトルートまたは `.claude/` ディレクトリに配置。
YAML 形式を採用（可読性が高くコメント記述可能）。

```yaml
# rite-workflow 設定ファイル
schema_version: 2

# プロジェクト基本設定
project:
  type: webapp  # generic | webapp | library | cli | documentation

# GitHub Projects 連携
github:
  projects:
    enabled: true
    project_number: null  # Project 番号（null = リポジトリから自動検出）
    owner: null           # Project オーナー（null = リポジトリオーナーを使用）
    # フィールド構成（完全カスタマイズ可能）
    fields:
      status:
        enabled: true
        options:
          - { name: "Todo", default: true }
          - { name: "In Progress" }
          - { name: "In Review" }
          - { name: "Done" }
      priority:
        enabled: true
        options:
          - { name: "High" }
          - { name: "Medium", default: true }
          - { name: "Low" }
      complexity:
        enabled: true
        options:
          - { name: "XS" }
          - { name: "S" }
          - { name: "M", default: true }
          - { name: "L" }
          - { name: "XL" }
      # カスタムフィールド（プロジェクト固有）
      # GitHub Projects の Single Select フィールド名と一致する任意のフィールド名を使用可能
      # フィールド名の比較は大文字小文字を区別しない（case-insensitive）
      work_type:
        enabled: true
        options:
          - { name: "Feature" }
          - { name: "Bug Fix" }
          - { name: "Documentation" }
          - { name: "Refactor" }
          - { name: "Chore" }
      category:
        enabled: true
        options:
          - { name: "Frontend" }
          - { name: "Backend" }
          - { name: "Infrastructure" }
          - { name: "Other" }

# ブランチ命名規則（完全カスタマイズ）
branch:
  # フィーチャーブランチを切る元（PR のデフォルトマージ先）
  base: "main"      # デフォルト: main（Git Flow の場合は "develop"）
  pattern: "{type}/issue-{number}-{slug}"
  # 利用可能な変数: {type}, {number}, {slug}, {date}, {user}

# コミットメッセージ
commit:
  contextual: true    # コミット本文に Contextual Commits のアクション行を含める

# ビルド・テスト・リント（自動検出、または手動指定）
commands:
  build: null  # 自動検出
  test: null   # 自動検出
  lint: null   # 自動検出

# レビュー設定
review:
  # 最小レビュアー数（マッチするレビュアーがいない場合のフォールバック）
  min_reviewers: 1
  # レビュー判断基準（レビュアー自動選択に使用）
  criteria:
    - file_types       # ファイル種類による判断
    - content_analysis # 内容解析による判断
  # 注: レビューは常に各レビュアーロールに対して並列サブエージェントを使用

# 通知設定
notifications:
  slack:
    enabled: false
    webhook_url: null
  discord:
    enabled: false
    webhook_url: null
  teams:
    enabled: false
    webhook_url: null

# Workflow incident 自動 Issue 登録 (#366)
# workflow blocker (Skill ロード失敗 / hook 異常終了 / 手動 fallback 採用) を自動検出し、
# silent loss を防ぐために Issue として登録します。
# 詳細は "Workflow Incident Detection" セクションを参照してください。
workflow_incident:
  enabled: true              # default-on; false で opt-out (AC-8)

# 言語設定（auto で自動検出）
language: auto  # auto | ja | en
```

---

## 各コマンド仕様

### /rite:init

**説明:** プロジェクトへの rite ワークフロー初回セットアップ

**処理フロー:**

#### Phase 1: 環境チェック
1. gh CLI のインストール確認
2. GitHub 認証状態の確認
3. リポジトリ情報の取得

#### Phase 2: プロジェクト種別の判定
1. ファイル構成から自動推定
   - `package.json` + フロントエンドフレームワーク → webapp
   - `package.json` + `main`/`exports` → library
   - `pyproject.toml` + `[project.scripts]` → cli
   - SSG 設定ファイル → documentation
   - その他 → generic
2. ユーザーに確認・選択（AskUserQuestion）

#### Phase 3: GitHub Projects 設定
1. 既存 Projects の検出
2. 選択肢を提示:
   - 既存 Projects と連携
   - 新規 Projects を作成
3. フィールドの自動設定

#### Phase 4: テンプレート生成
1. `.github/ISSUE_TEMPLATE/` の確認
   - 既存があれば認識
   - なければ自動生成
2. `rite-config.yml` の生成

#### Phase 5: 完了報告
1. 設定サマリーの表示
2. 次のステップの案内

---

### /rite:issue:list

**説明:** GitHub Issue の一覧を表示

**引数:** `[フィルタ条件]`（省略可）

**フィルタ条件:**

| フィルタ | 説明 |
|---------|------|
| `open` | オープンな Issue |
| `closed` | クローズした Issue |
| `<label>` | 指定ラベルの Issue |
| `#123` | 特定の Issue 詳細 |

---

### /rite:issue:create

**説明:** 新規 Issue を作成し、GitHub Projects に追加

**引数:** `<Issue のタイトルまたは作業内容の説明>`（必須）

#### Phase 0: 入力分析・補完

1. ユーザー入力から以下を抽出:
   - **What:** 何をするか
   - **Why:** なぜ必要か
   - **Where:** どこを変更するか
   - **Scope:** 影響範囲
   - **Constraints:** 制約条件

2. 曖昧な表現を検出

3. 類似 Issue 検索で背景情報を収集

4. 必要に応じて `AskUserQuestion` で明確化

5. 深堀りインタビュー（Phase 0.5）で実装詳細を確認

#### Phase 0.6-0.9: タスク分解（条件付き）

**トリガー条件:**
- 暫定複雑度が XL
- かつ「〜システムを作る」「〜プラットフォーム」「〜基盤を構築」等の包括的表現を含む
  - 単なる「〜機能を追加」「〜を修正」は対象外

**分解フロー:**

1. **Phase 0.6**: 分解トリガー判定
   - 条件を満たす場合、ユーザーに分解を提案

2. **Phase 0.7**: 仕様書生成
   - 深堀りインタビュー結果を基に設計ドキュメントを生成
   - `docs/designs/{slug}.md` に保存

3. **Phase 0.8**: Sub-Issue 分解
   - 仕様書から Sub-Issue 候補を抽出
   - 依存関係を分析し、実装順序を提案

4. **Phase 0.9**: Sub-Issue 一括作成
   - 親 Issue と Sub-Issue を作成
   - Tasklist 形式で親子関係を設定
   - GitHub Sub-Issues API（beta）が利用可能な場合は親子関係を設定

**Sub-Issue の粒度:**
- 各 Sub-Issue は 1 Issue = 1 PR 相当のサイズ
- 推定複雑度: S〜L（XL にならないよう分割）
- 独立して完結できる

#### Phase 1: 分類・推定

**複雑度推定基準:**

| 複雑度 | 判断基準 |
|--------|----------|
| XS | 1行変更、誤字修正 |
| S | 単一ファイルの内容更新 |
| M | 複数ファイル（5ファイル以下） |
| L | 複数ファイル（10ファイル以上）、判断を伴う |
| XL | 大規模変更、設計判断 |

#### Phase 2: 確認・作成

1. `gh issue create` で Issue 作成
2. `gh project item-add` で Projects に追加
3. フィールド設定（Status/優先度/複雑度/作業種別）

---

### /rite:issue:start

**説明:** Issue の作業を一気通貫で開始（ブランチ作成 → 実装 → PR 作成）

**引数:** `<Issue 番号>`（必須）

**ワークフロー:** このコマンドは以下の開発フロー全体を処理します:
1. ブランチ作成と準備
2. 実装計画生成
3. 実装作業
4. 品質チェック（`/rite:lint`）
5. ドラフト PR 作成（`/rite:pr:create`）
6. セルフレビュー（`/rite:pr:review`）

**「自動」の意味:** 本コマンドでの「自動」とは、ユーザーが手動でコマンドを入力せずに Phase 5 で Skill ツールを介して順次実行されることを指します。

#### Phase 0: Epic/Sub-issues 判定

GitHub 標準機能を活用:
- Milestone 機能を認識
- Sub-issues（beta）機能がある場合は認識
- 子 Issue の一覧を提示し、ユーザーに選択を促す

**親 Issue ステータス連動:**

子 Issue で作業する場合、親 Issue のステータスが自動的に連動します:

| トリガー | 親 Issue のステータス更新 |
|---------|--------------------------|
| 最初の子 Issue が In Progress に | 親 Issue → In Progress |
| すべての子 Issue が Done に | 親 Issue → Done |
| 一部完了、一部未着手 | 親 Issue は In Progress のまま維持 |

これにより、親 Issue が子 Issue 全体の進捗を正確に反映するようになります。

#### Phase 1: Issue 品質検証

**品質スコア基準:**

| スコア | 基準 |
|--------|------|
| A | すべての項目が明確 |
| B | 主要項目が明確、一部推測可能 |
| C | 基本情報のみ、補完が必要 |
| D | 情報不足、作業開始前に補完必須 |

スコアが C/D の場合:
1. 不足情報を自動補完を試みる
2. 補完できない場合は `AskUserQuestion` で確認

#### Phase 1.5: 親 Issue ルーティング

対象 Issue が親（Epic）Issue かどうかを以下で検出:
1. `trackedIssues` API（GraphQL）
2. 本文のタスクリスト（`- [ ] #XX`）
3. ラベル（`epic`/`parent`/`umbrella`）

親 Issue の場合、ルーティングロジックが適切なアクションを決定: 親 Issue を直接作業、子 Issue を選択、またはサブ Issue に分解。

#### Phase 1.6: 子 Issue 選択

親 Issue が検出された場合、以下に基づいて最適な子 Issue を自動選択:
- 優先度と依存関係の順序
- 現在の状態（完了済み/作業中の子をスキップ）
- 続行前にユーザー確認

#### Phase 2: 作業準備

1. ブランチ名生成（設定のパターンに従う）
2. 既存ブランチ確認（`branch.recognized_patterns` 設定による認識パターンを含む）
3. `git checkout -b` でブランチ作成
4. GitHub Projects Status を「In Progress」に更新
5. 現在の Iteration に割り当て（`iteration.enabled: true` かつ `iteration.auto_assign: true` の場合）
6. 作業メモリコメントを初期化

##### Phase 2.2.1: 認識ブランチパターン

rite-config.yml に `branch.recognized_patterns` が設定されている場合、Issue 番号を含まない既存ブランチをパターンマッチで検出します。マッチした場合、既存ブランチを使用するか標準パターンで新規作成するかを選択できます。

##### Phase 2.5: Iteration 割り当て（オプション）

rite-config.yml で `iteration.enabled: true` かつ `iteration.auto_assign: true` の場合、GitHub Projects の現在アクティブな Iteration/Sprint に Issue を自動割り当てします。

**作業メモリコメント形式:**

Issue に専用コメントを1つ追加し、以降はそのコメントを更新:

```markdown
## 📜 rite 作業メモリ

### セッション情報
- **開始**: 2025-01-03T10:00:00+09:00
- **ブランチ**: feat/issue-123-add-feature
- **最終更新**: 2025-01-03T10:00:00+09:00
- **コマンド**: rite:issue:start
- **フェーズ**: phase2
- **フェーズ詳細**: ブランチ作成・準備

### 進捗
- [ ] タスク1
- [ ] タスク2

### 要確認事項
<!-- 作業中に発生した確認事項を蓄積。セッション終了時にまとめて確認 -->
_確認事項はありません_

### 変更ファイル
<!-- 自動更新 -->

### 決定事項・メモ
<!-- 重要な判断や発見 -->

### 計画逸脱ログ
<!-- 実装中に計画から逸脱した場合に記録 -->
_計画逸脱はありません_

### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->
_ボトルネック検出はありません_

### レビュー対応履歴
<!-- レビュー対応時に自動記録 -->
_レビュー対応はありません_

### 次のステップ
1. ...
```

**フェーズ情報について:**

作業メモリのセッション情報セクションには、現在の作業状態を示すフェーズ情報が記録されます。この情報は `/rite:resume` による作業再開時に使用されます。

| フェーズ | フェーズ詳細 |
|---------|------------|
| `phase0` | Epic/Sub-Issues 判定 |
| `phase1` | 品質検証 |
| `phase1_5_parent` | 親 Issue ルーティング |
| `phase1_6_child` | 子 Issue 選択 |
| `phase2` | ブランチ作成・準備 |
| `phase2_branch` | ブランチ作成中 |
| `phase2_work_memory` | 作業メモリ初期化 |
| `phase3` | 実装計画生成 |
| `phase4` | 作業開始準備 |
| `phase5_implementation` | 実装作業中 |
| `phase5_lint` | 品質チェック中 |
| `phase5_pr` | PR 作成中 |
| `phase5_review` | レビュー中 |
| `phase5_fix` | レビュー修正中 |
| `phase5_post_ready` | Ready 処理後 |
| `completed` | 完了 |

#### Phase 3: 実装計画生成

1. Issue 内容を分析し、変更対象ファイルを特定
2. 実装計画を生成
3. ユーザー確認: 承認 / 修正 / スキップ
4. Issue 本文のチェックリストを抽出・追跡（存在する場合）

**Issue 本文のチェックリスト追跡:**

Issue 本文にチェックリスト（`- [ ] タスク` 形式）がある場合、作業メモリに記録して追跡します:

- **抽出対象**: `- [ ]` または `- [x]` で始まるタスク行
- **除外対象**: Tasklist 形式の Issue 参照（`- [ ] #123`）は親子 Issue 管理用として除外
- **用途**: 実装完了時の自動更新、PR 作成時の未完了確認

実装完了後（Phase 5.1）、該当するチェック項目は Issue 本文で自動的に完了状態（`[x]`）に更新されます。

#### Phase 4: 案内と続行確認

準備完了後、ユーザーが選択:
- **実装を開始する（推奨）**: Phase 5 へ進み、実装から PR 作成・レビューまで一気通貫で実行
- **後で作業する**: ここで中断し、後で `/rite:issue:start` で再開

#### Phase 5: 一気通貫実行

「実装を開始する」選択時に開始。以下のステップを**中断なく連続して実行**:

**フロー継続の原則:** 各ステップ完了後は、ユーザー確認を待たずに次のステップに進む（明示的に確認が必要な箇所を除く）。

| ステップ | 内容 | 呼び出しコマンド |
|---------|------|-----------------|
| 5.1 | 実装作業（コミット・プッシュ含む） | - |
| 5.2 | 品質チェック | `/rite:lint` |
| 5.3 | ドラフト PR 作成 | `/rite:pr:create` |
| 5.4 | セルフレビュー | `/rite:pr:review` |
| 5.5 | レビュー結果に応じた継続 | `/rite:pr:fix`（必要時） |
| 5.6 | 完了報告 | - |

**5.2 品質チェック結果による分岐:**

| 結果 | 後続処理 |
|------|----------|
| 成功 | → 5.3 へ |
| 警告のみ | → 5.3 へ |
| エラーあり | エラー修正 → 5.2 再実行 |
| スキップ | → 5.3 へ（PR に記録） |

**5.5 レビュー結果による分岐:**

| 結果 | 後続処理 |
|------|----------|
| マージ可 | `/rite:pr:ready` 実行を確認 → 5.6 へ |
| 条件付きマージ可 | `/rite:pr:fix` で修正 → 5.4 に戻る |
| 修正必要 | `/rite:pr:fix` で修正 → 5.4 に戻る |

**レビュー・修正サイクルの継続:** `/rite:pr:review` → `/rite:pr:fix` → `/rite:pr:review` のサイクルは、総合評価が「マージ可」（blocking 指摘が 0 件）になるまで自動的に継続する。各ループ間でユーザー確認は行わず自動継続。ループは全指摘が解決されるまで継続し、反復回数による強制終了や段階的緩和は行わない。

**検証モード** (`review.loop.verification_mode`、デフォルト: `false`): 明示的に有効化すると、サイクル 2 以降、フルレビューに加えて前回指摘の修正検証と差分に対するリグレッションチェックを補足的に実施する。未変更コードに対する新規の MEDIUM/LOW 指摘は、non-blocking の「安定性懸念」として報告される。デフォルトの `false` では毎回フルレビューを実施し、レビュー品質を最大化する。

**「マージ可」の定義:** blocking 指摘が 0 件。

### 作業メモリの自動更新

以下のコマンド実行時に作業メモリが自動的に更新されます:

| コマンド | 自動更新内容 |
|---------|-------------|
| `/rite:issue:start` | 作業メモリの初期化、実装計画の記録 |
| `/rite:pr:create` | 変更ファイル、コミット履歴、PR 情報の記録 |
| `/rite:pr:fix` | レビュー対応履歴の記録 |
| `/rite:pr:cleanup` | 完了情報の記録 |
| `/rite:lint` | 品質チェック結果の記録（条件付き: Issue ブランチのみ） |

**手動更新:**

`/rite:issue:update` は以下の場合に手動更新として利用可能:
- 重要な設計判断の記録
- 補足情報の追加
- 特定のタイミングでの進捗更新
- 次のセッションへの引き継ぎ準備

### 中断と再開

「後で作業する」選択時や作業が中断された場合:
- ブランチと作業メモリは保持される
- 作業メモリにフェーズ情報（`コマンド`、`フェーズ`、`フェーズ詳細`）が記録される
- `/rite:resume` で中断したフェーズから作業を再開

**再開方法:**

```
/rite:resume
```

または Issue 番号を指定:

```
/rite:resume <issue_number>
```

**セッション開始時の自動検出:**

フィーチャーブランチ上でセッションを開始した場合、作業メモリのフェーズ情報を自動検出し、中断された作業がある場合は通知されます。

**PR が既に存在する場合:**
- 既存ブランチ検出後に PR の存在を確認
- PR がある場合は `/rite:pr:fix` でレビュー対応を続行するか選択

**補足:** `/rite:pr:create` は単独でも使用可能:
- 中断からの再開時
- 既存ブランチからの PR 作成
- Issue なしでの PR 作成

---

### /rite:issue:update

**説明:** Issue の作業メモリコメントを手動で更新

**引数:** `[更新内容のメモ]`（省略可）

**用途:**

| 用途 | 説明 |
|------|------|
| 決定事項の記録 | 重要な設計判断や方針決定をメモしたいとき |
| 補足情報の追加 | 自動更新では記録されない追加情報を残したいとき |
| 進捗の手動更新 | 特定のタイミングで進捗状況を記録したいとき |
| セッション引き継ぎ | セッション終了前に状況を整理したいとき |

**記録内容:**
- 決定事項・メモ（「何をしたか」だけでなく「なぜか」も）
- 補足情報
- 次のステップ

---

### /rite:issue:close

**説明:** Issue の完了状態を確認

**引数:** `<Issue 番号>`（必須）

**確認事項:**
1. Issue 状態確認（open/closed）
2. 紐づく PR の状態確認
3. 自動クローズの可否判定
4. 必要なアクション案内

---

### /rite:pr:create

**説明:** ドラフト PR を作成

**引数:** `[PR タイトル]`（省略時は自動生成）

**処理手順:**

1. 現在のブランチと変更内容を確認
2. 関連 Issue を特定（ブランチ名から推測）
3. Issue の作業メモリから作業履歴を取得
4. Issue 本文の未完了チェック項目を確認
5. 自動検証実行:
   - ビルド（自動検出されたコマンド）
   - リント（自動検出されたコマンド）
6. PR タイトル生成（Conventional Commits 形式推奨）
7. PR 本文作成（プロジェクト種別に応じたテンプレート）
8. ドラフト PR として作成
9. Issue の作業メモリを最終更新

**未完了チェック項目の確認:**

Issue 本文にチェックリストがある場合、未完了の項目（`- [ ]`）を検出し警告を表示します:

- 未完了項目がある場合、PR 作成前に確認を求める
- 意図的に未完了のまま進める場合は、PR 本文の「Known Issues」セクションに記録

---

### /rite:pr:ready

**説明:** PR を Ready for review に変更

**引数:** `[PR 番号またはブランチ名]`（省略時は現在のブランチ）

**処理手順:**
1. 現在の PR を特定
2. `gh pr ready` で Ready for review に変更
3. 関連 Issue の Status を「In Review」に更新
4. PR URL を報告

---

### /rite:pr:review

**説明:** PR の動的マルチレビュアーレビュー

**引数:** `[PR 番号またはブランチ名]`（省略時は現在のブランチ）

#### 並列サブエージェントレビュー

`/rite:pr:review` は Claude Code の Task ツールを使用して、各レビュアーロールに対して並列サブエージェントを生成します:

```
/rite:pr:review 開始
  ↓
変更ファイル一覧を取得
  ↓
ファイルを分析し、適切なレビュアーを選択
  ↓
サブエージェントを並列実行（Task ツール）
  ├─ security-reviewer: セキュリティ観点
  ├─ performance-reviewer: パフォーマンス観点
  ├─ code-quality-reviewer: コード品質観点
  ├─ api-reviewer: API 設計観点
  ├─ database-reviewer: データベース観点
  ├─ devops-reviewer: DevOps 観点
  ├─ frontend-reviewer: フロントエンド観点
  ├─ test-reviewer: テスト品質観点
  ├─ dependencies-reviewer: 依存関係観点
  ├─ prompt-engineer-reviewer: プロンプト品質観点
  ├─ tech-writer-reviewer: ドキュメント観点
  ├─ error-handling-reviewer: エラーハンドリング観点
  └─ type-design-reviewer: 型設計観点
  ↓
各サブエージェントの結果を収集
  ↓
結果を統合して総合評価
  ↓
レビュー結果を出力
```

**メリット:**
- コンテキスト効率の改善（各サブエージェントが専門領域に集中）
- 並列実行によるレビュー高速化
- 専門知識の分離
- 変更ファイルに基づくレビュアーの自動選択

**レビュアー選択:**

レビュアーはファイルパターンと内容分析に基づいて自動的に選択されます。すべての PR ですべてのレビュアーが呼び出されるわけではなく、関連するレビュアーのみが選択されます。

**フォールバック:** サブエージェントが失敗またはタイムアウトした場合、残りのサブエージェントでレビューを継続し、サマリーに失敗を記録します。

詳細は「[動的レビュアー生成](#動的レビュアー生成)」セクションを参照。

---

### /rite:pr:fix

**説明:** PR のレビュー指摘に対応

**引数:** `[PR 番号]`（省略時は現在のブランチの PR）

#### Phase 1: レビューコメントの取得・整理

1. PR を特定（引数または現在のブランチから）
2. GitHub API でレビューコメントを取得
3. コメントを分類:
   - **要修正**: `CHANGES_REQUESTED` レビューまたは未解決スレッド
   - **提案・質問**: 改善提案や未回答の質問
   - **解決済み**: 既に解決されたスレッド
4. 未解決コメントの一覧を整理して表示

#### Phase 2: 対応の支援

未解決の各コメントについて:

1. コメント詳細を表示（ファイル、行、内容、レビュアー）
2. 対応方針をユーザーに確認:
   - コードを修正する
   - 説明・返信のみ（修正不要）
   - スキップ（後で対応）
3. コード修正の場合:
   - 対象ファイルを読み込み
   - コメントに基づく修正を提案
   - Edit ツールで修正を適用
4. 必要に応じてレビュアーへの返信を作成

#### Phase 3: 修正コミット

1. すべての変更を確認
2. 対応したコメントに基づいてコミットメッセージを生成
3. 適切なメッセージでコミット
4. 必要に応じてリモートにプッシュ

#### Phase 4: 対応完了の報告

1. 対応済みスレッドを解決済みにマーク（オプション、GraphQL mutation）
2. PR にサマリーコメントを投稿（オプション）
3. 作業メモリに対応履歴を更新
4. 完了サマリーと次のステップを表示

---

### /rite:pr:cleanup

**説明:** PR マージ後のクリーンアップ作業を自動化

**引数:** `[ブランチ名]`（省略時は現在のブランチ）

#### Phase 1: 状態確認

1. 現在のブランチを確認
2. 関連 PR を検索しマージ状態を確認
3. PR 本文またはブランチ名から関連 Issue を特定
4. Issue 本文のチェックリスト完了状況を確認

**PR がマージされていない場合:**
- データ損失の警告を表示
- オプション: キャンセル（推奨）または強制クリーンアップ

**チェックリスト完了確認:**

Issue 本文にチェックリストがある場合、未完了項目の有無を確認します:

- すべて完了済み: そのままクリーンアップを続行
- 未完了項目あり: 警告を表示し、対応を確認
  - 残りの項目を完了としてマーク（自動更新）
  - 未完了のままクリーンアップ続行
  - クリーンアップを中断

#### Phase 2: クリーンアップ実行

1. main ブランチに切り替え
2. 最新の main を pull
3. ローカルブランチを削除（`git branch -d`）
4. リモートブランチが存在する場合は削除（`git push origin --delete`）

**未コミットの変更がある場合:**
- 変更をスタッシュしてクリーンアップ続行を提案

#### Phase 3: Projects Status 更新

1. `rite-config.yml` から Project 設定を取得
2. Issue の Project アイテムを検索
3. Status を "Done" に更新
4. 作業メモリコメントに完了記録を追加

#### Phase 4: 完了報告

```
クリーンアップが完了しました

PR: #{pr_number} - {pr_title}
関連 Issue: #{issue_number}
Status: Done

実行した処理:
- [x] main ブランチに切り替え
- [x] 最新の main を pull
- [x] ローカルブランチ {branch_name} を削除
- [x] リモートブランチを削除
- [x] Projects Status を Done に更新
- [x] 作業メモリを最終更新

次のステップ:
1. `/rite:issue:list` で次の Issue を確認
2. `/rite:issue:start <issue_number>` で新しい作業を開始
```

---

### /rite:lint

**説明:** 品質チェックを実行

**引数:** `[ファイルパスまたはディレクトリ]`（省略時は変更ファイル）

**処理:**
1. 自動検出されたリントコマンドを実行
2. 結果をフォーマットして表示
3. エラーがあれば修正案を提示

---

### /rite:template:reset

**説明:** テンプレートを再生成

**引数:** `[--force]`（既存ファイルを強制上書き）

**対象:**
- `.github/ISSUE_TEMPLATE/`
- PR テンプレート
- `rite-config.yml`（オプション）

---

## Iteration/スプリント管理（オプション）

GitHub Projects の Iteration フィールドを使用したスプリント管理機能。

### 概要

- **オプション機能**: デフォルトで無効（`iteration.enabled: false`）
- **手動セットアップ**: Iteration フィールドは GitHub Web UI で手動作成が必要（gh CLI 非対応）
- **graceful degradation**: Iteration が無効でも他の機能に影響なし

### 機能有効化による変化

| 観点 | Iteration 無効時 | Iteration 有効時 |
|------|-----------------|-----------------|
| Issue 作成 | Status/Priority/Complexity 設定 | + Sprint 割り当てオプション |
| Issue 作業開始 | ブランチ作成、Status 更新 | + 現在 Sprint への自動割り当て |
| Issue 一覧 | Status/Priority でフィルタ | + Sprint/Backlog フィルタ |
| 利用可能コマンド | 12 コアコマンド | + 3 Sprint コマンド |
| 計画方式 | アドホック | Sprint ベース計画 |
| 進捗可視化 | Status 別のみ | + Sprint 別進捗 |

### 設定

```yaml
# rite-config.yml
iteration:
  enabled: false          # true で有効化
  field_name: "Sprint"    # Iteration フィールド名
  auto_assign: true       # issue:start 時に自動割り当て
  show_in_list: true      # issue:list に Iteration 列を表示
```

### Sprint コマンド

| コマンド | 説明 |
|---------|------|
| `/rite:sprint:list` | 全 Iteration の一覧表示 |
| `/rite:sprint:current` | 現在のスプリント詳細 |
| `/rite:sprint:plan` | スプリント計画（バックログから Issue を割り当て） |

### Iteration 対応の既存コマンド

| コマンド | Iteration 関連機能 |
|---------|-------------------|
| `/rite:init` | Iteration フィールド検出・設定ガイド |
| `/rite:issue:start` | 現在のイテレーションへ自動割り当て |
| `/rite:issue:create` | 作成時の Iteration 割り当てオプション |
| `/rite:issue:list` | `--sprint current`, `--backlog` フィルタ |

### 現在のイテレーション判定

```
1. 今日の日付を取得
2. 各イテレーションについて:
   - endDate = startDate + duration (days)
   - startDate <= 今日 < endDate → 「現在」
3. 該当なし → 次のイテレーション（または null）
```

### 技術的制約

- **Iteration フィールドの自動作成**: 不可（gh CLI は ITERATION データ型に非対応）
- **Iteration フィールドの操作**: GraphQL API 経由で可能

---

## フック仕様

### 対応フックタイプ

| タイプ | タイミング | 用途 |
|--------|-----------|------|
| SessionStart | セッション開始時 | 作業メモリの読み込み、中断作業の検出 |
| PreCompact | コンパクト前 | 作業メモリの保存、compact 状態の記録 |
| PostCompact | コンパクト後 | 作業メモリの復元、compact 状態のクリーンアップ |
| SessionEnd | セッション終了時 | 最終状態の保存 |
| Stop | 停止試行時（イベント駆動） | ワークフロー中の早期停止を防止 |
| PreToolUse | ツール実行前 | compact 後のツール使用ブロック、危険なコマンドパターンの検出 |
| PostToolUse | ツール実行後 | ローカル作業メモリの自動復旧 |

> **注:** `notification.sh` は Claude Code のフックタイプではなく、コマンド内から直接呼び出されるユーティリティスクリプトである。PR 作成・Ready 変更・Issue クローズなどのイベント時にコマンドスクリプトが `notification.sh` を呼び出して外部通知を送信する。詳細は[通知連携](#通知連携)セクションを参照。

### フック実行順序

```
SessionStart
    ↓
PreToolUse → ツール実行 → PostToolUse
    ↓
PreCompact（コンパクト時）
    ↓
SessionEnd
```

> **注:** Stop フックはイベント駆動であり、上記フローの任意のタイミングで発火する可能性がある。rite ワークフローがアクティブな場合はブロックする。
>
> **注:** PreToolUse と PostToolUse は Claude Code のツール呼び出しごとに発火する。PreCommand/PostCommand は廃止され、代わりにコマンド実行前の Preflight チェックシステムに統合された。

### Stop Guard（`stop-guard.sh`）

アクティブな rite ワークフローセッション中に Claude が停止するのを防止する。

**動作:**

1. 作業ディレクトリの `.rite-flow-state` を読み取る（ファイルが存在しない場合は停止を許可）
2. `active` が `true` でなければ停止を許可する
3. 最終更新が 1 時間以内の場合、停止をブロックする
4. ワークフローが古くなっている場合（最終更新から 1 時間超過）、停止を許可する（放棄されたとみなす）

**タイムスタンプのパース（クロスプラットフォーム対応）:**

`updated_at`（ISO 8601 形式）のパースにフォールバックチェーンを使用し、macOS/Linux 両環境をサポートする:

| 優先度 | 方法 | プラットフォーム | 備考 |
|--------|------|----------------|------|
| 1 | `date -d`（GNU） | Linux | `+09:00` 形式のタイムゾーンを直接パース |
| 2 | `date -j -f`（BSD） | macOS | `sed` で `+09:00` → `+0900` に変換後パース |
| 3 | `echo 0`（フォールバック） | 全環境 | `STATE_TS=0` となり `AGE ≈ 現在のエポック秒`（>> 3600）で停止を許可 |

**ブロック時のレスポンス:**

停止をブロックする場合、exit code 2 で終了し、継続メッセージを stderr に出力する。Claude Code は exit 2 を「停止阻止 + stderr をアシスタントにフィード」と解釈する:

```
rite workflow active (phase: <phase>). CONTINUE: <next_action>. If context limit reached, use /clear then /rite:resume to recover.
```

**エラーカウントによる自動解除:**

Stop Guard は停止をブロックするたびに `.rite-flow-state` の `error_count` をインクリメントする。`error_count` が閾値（デフォルト: 5）に達すると、ワークフローがエラーループに陥っていると判断し、停止を許可する。`error_count` は次のワークフロー開始時（`.rite-flow-state` 再生成時）にリセットされる。

**デバッグログ:**

`RITE_DEBUG=1` 環境変数を設定すると `.rite-flow-debug.log` にデバッグログを出力する。未設定時はゼロオーバーヘッド。

### Preflight Check（`preflight-check.sh`）

すべての `/rite:*` コマンド実行前に呼び出される事前検証スクリプト。compact 後のブロック状態を検出し、コマンド実行を制御する。

**動作:**

1. `.rite-compact-state` を読み取る（ファイルが存在しない場合は許可）
2. `compact_state` が `normal` または `resuming` の場合は許可
3. コマンドが `/rite:resume` の場合は常に許可
4. その他のコマンドはブロック（exit 1）

**Exit コード:**

| コード | 意味 |
|--------|------|
| 0 | 許可（コマンド実行を続行） |
| 1 | ブロック（コマンドを実行しない） |

**使用例:**

```bash
bash plugins/rite/hooks/preflight-check.sh --command-id "/rite:issue:start" --cwd "$PWD"
```

### Post-Compact Guard（`post-compact-guard.sh`）

PreToolUse フックとして登録。コンパクト発生後、ユーザーが `/clear` → `/rite:resume` を実行するまで**すべてのツール使用をブロック**する。

**動作:**

1. `.rite-compact-state` を読み取る
2. `.rite-flow-state` でワークフローがアクティブか確認
3. ワークフローが非アクティブの場合、`.rite-compact-state` をクリーンアップ（自己修復）
4. `compact_state` が `blocked` の場合、ツール使用を deny し、LLM に停止を指示

**自己修復機構:**

ワークフローが終了しているにもかかわらず `.rite-compact-state` が残存している場合（クラッシュなど）、自動的にクリーンアップして通常動作に復帰する。

### Pre-Tool Bash Guard（`pre-tool-bash-guard.sh`）

PreToolUse フックとして登録。LLM が繰り返し生成する既知の誤ったBashコマンドパターンを実行前にブロックする。

**ブロック対象パターン:**

| パターン | 理由 | 代替コマンド |
|----------|------|-------------|
| `gh pr diff --stat` | `--stat` フラグは未サポート | `gh pr view {n} --json files --jq '.files[]'` |
| `gh pr diff -- <path>` | ファイルフィルタは未サポート | `gh pr diff {n} \| awk` でフィルタ |
| `!= null`（jq/awk 内） | bash のヒストリ展開が `!` を解釈 | `select(.field)` または `select(.field == null \| not)` |

**Heredoc 安全性:**

コミットメッセージや PR 説明文などの heredoc 内のテキストによる誤検出を防ぐため、`<<` 以前のコマンド部分のみを検査する。

### Post-Tool WM Sync（`post-tool-wm-sync.sh`）

PostToolUse フックとして登録。アクティブなワークフロー中にローカル作業メモリファイルが欠落している場合、自動的に作成する。

**動作:**

1. Bash ツール使用後に発火（再帰ガード付き）
2. `.rite-flow-state` からアクティブなワークフローと Issue 番号を取得
3. `.rite-work-memory/issue-{n}.md` が存在しない場合のみ、自動作成

**用途:** compact 後の `/rite:resume` やセッション再開時に、ローカル作業メモリの自動復旧を保証する。

### Local WM Update（`local-wm-update.sh`）

ローカル作業メモリファイルの更新を行うスタンドアロンラッパースクリプト。`BASH_SOURCE` によるプラグインルートの自動解決を行う。

**使用例:**

```bash
WM_SOURCE="implement" WM_PHASE="phase5_lint" \
  WM_PHASE_DETAIL="Quality check prep" \
  WM_NEXT_ACTION="Run rite:lint" \
  WM_BODY_TEXT="Post-implementation." \
  WM_ISSUE_NUMBER="866" \
  bash plugins/rite/hooks/local-wm-update.sh
```

**環境変数:**

| 変数 | 必須 | 説明 |
|------|------|------|
| `WM_SOURCE` | はい | 更新元の識別子（`init`, `implement`, `lint` 等） |
| `WM_PHASE` | はい | 現在のフェーズ（`phase2`, `phase5_lint` 等） |
| `WM_PHASE_DETAIL` | はい | フェーズの詳細説明 |
| `WM_NEXT_ACTION` | はい | 次のアクション |
| `WM_BODY_TEXT` | はい | 更新内容のテキスト |
| `WM_ISSUE_NUMBER` | はい | Issue 番号 |

### Work Memory Lock（`work-memory-lock.sh`）

`mkdir` ベースのロック/アンロック機能を提供する共有ライブラリスクリプト。他のスクリプトから `source` して使用する。

**提供する関数:**

| 関数 | 説明 |
|------|------|
| `acquire_wm_lock <lockdir> [timeout]` | ロック取得（タイムアウト付き、デフォルト: 50反復 × 100ms = 5秒） |
| `release_wm_lock <lockdir>` | ロック解放 |
| `is_wm_locked <lockdir>` | ロック状態確認 |

**Stale ロック検出:**

ロックの `mtime` が閾値（デフォルト: 120秒）を超えた場合、PID ファイルでプロセスの生存を確認し、プロセスが終了していればロックを自動解放する。

---

## 機能

### TDD Light モード

受入基準からテストスケルトンを自動生成し、実装前にテスト構造を準備する軽量 TDD モード。

**設定:**

```yaml
# rite-config.yml
tdd:
  mode: "off"        # off | light（デフォルト: off）
  tag_prefix: "AC"   # テストマーカーのタグプレフィックス
  run_baseline: true  # スケルトン生成前にベースラインテストを実行
  max_skeletons: 20   # Issue あたりの最大スケルトン数
```

**動作フロー:**

1. Issue の受入基準を分析
2. 各基準にハッシュタグ（`AC[a1b2c3d4]`）を付与
3. テストスケルトンを生成（`skip` / `pending` / `todo` マーカー付き）
4. 実装作業でスケルトンを順次埋めていく

### Preflight チェックシステム

すべての `/rite:*` コマンド実行前に統一的な事前検証を行うシステム。compact 後の不正な状態でのコマンド実行を防止する。

**仕組み:**

- 各コマンドの先頭で `preflight-check.sh` を呼び出し
- `.rite-compact-state` ファイルで compact 状態を管理
- `blocked` 状態では `/rite:resume` 以外のすべてのコマンドをブロック
- `/clear` → `/rite:resume` で正常状態に復帰

### ローカル作業メモリ + Compact 耐性

Issue コメントのバックアップに加え、ローカルファイルシステムに作業メモリを保持する仕組み。コンテキスト compaction への耐性を確保する。

**アーキテクチャ:**

| コンポーネント | 役割 | 場所 |
|--------------|------|------|
| ローカル作業メモリ（SoT） | 真実のソース | `.rite-work-memory/issue-{n}.md` |
| Issue コメント（バックアップ） | セッション間のバックアップ | GitHub Issue コメント |
| フロー状態 | ワークフロー制御 | `.rite-flow-state` |
| Compact 状態 | compact 後の状態管理 | `.rite-compact-state` |

**ローカル作業メモリの特徴:**

- `mkdir` ベースの排他ロックで同時アクセスを制御
- PostToolUse フックによる自動復旧
- compact 後も `.rite-flow-state` から状態を復元可能

### Implementation Contract Issue フォーマット

`/rite:issue:create` で生成される Issue に、実装契約（Implementation Contract）セクションを含めるフォーマット。仕様書からの高レベル設計と、実装計画の詳細ステップを分離する。

**構造:**

- **Phase 0.7（仕様書生成）**: What/Why/Where の高レベル設計を `docs/designs/` に生成
- **Phase 3（実装計画）**: How の詳細ステップを依存グラフとして生成
- Issue body のチェックリストで進捗を追跡

### 複雑度ベース質問フィルタリング

`/rite:issue:create` の深堀りインタビュー（Phase 0.5）で、Issue の複雑度に応じて質問数を動的に調整する仕組み。

**フィルタリングルール:**

| 複雑度 | 質問数 | 対象 |
|--------|--------|------|
| XS-S | 最小限（1-2問） | What/Why のみ |
| M | 標準（3-4問） | What/Why/Where/Scope |
| L-XL | 詳細（5問以上） | 全項目 + 分解提案 |

### シェルスクリプトテスト基盤

Hook スクリプトの品質を保証するためのテストフレームワーク。`plugins/rite/hooks/tests/` に配置。

**テスト対象:**

| スクリプト | テスト内容 |
|-----------|-----------|
| `stop-guard.sh` | 各フェーズでの停止ブロック/許可判定 |
| `preflight-check.sh` | compact 状態別のコマンドブロック |
| `post-compact-guard.sh` | ツール使用ブロック、自己修復 |
| `pre-tool-bash-guard.sh` | 危険パターンの検出、heredoc 安全性 |

**実行方法:**

```bash
bash plugins/rite/hooks/tests/run-tests.sh
```

---

## 通知連携

### Slack

```yaml
notifications:
  slack:
    enabled: true
    webhook_url: "https://hooks.slack.com/services/..."
```

### Discord

```yaml
notifications:
  discord:
    enabled: true
    webhook_url: "https://discord.com/api/webhooks/..."
```

### Microsoft Teams

```yaml
notifications:
  teams:
    enabled: true
    webhook_url: "https://outlook.office.com/webhook/..."
```

### 通知イベント一覧

| イベント | 説明 |
|---------|------|
| `pr_created` | PR 作成時 |
| `pr_ready` | Ready for review 時 |
| `issue_closed` | Issue クローズ時 |

---

## ビルド・テスト・リント自動検出

### 検出優先順位

1. **rite-config.yml での明示的指定**
2. **package.json の scripts**
   - `build`, `test`, `lint` を検出
3. **Makefile のターゲット**
4. **標準的なファイル構成からの推測**

### 言語/フレームワーク別検出

| ファイル | 言語/FW | ビルド | テスト | リント |
|----------|---------|--------|--------|--------|
| `package.json` | Node.js | `npm run build` | `npm test` | `npm run lint` |
| `pyproject.toml` | Python | `python -m build` | `pytest` | `ruff check` |
| `Cargo.toml` | Rust | `cargo build` | `cargo test` | `cargo clippy` |
| `go.mod` | Go | `go build` | `go test` | `golangci-lint` |
| `pom.xml` | Java | `mvn package` | `mvn test` | `mvn checkstyle:check` |

### コマンド未検出時のフォールバック動作

build/test/lint コマンドが検出できない場合、処理を終了せず対話的に選択肢を提示:

**`AskUserQuestion` で提示される選択肢:**

| 選択肢 | 説明 |
|--------|------|
| **スキップして続行（推奨）** | コマンドをスキップし、次のステップに進む。PR 本文の「Known Issues」にスキップを記録 |
| **コマンドを指定** | 実行するコマンドを手動で入力 |
| **中断** | 処理を中断し、設定方法を案内 |

**スキップ時の挙動:**
- スキップ情報は会話コンテキストに記録される
- `/rite:pr:create` 呼び出し時、「Known Issues」セクションにスキップしたコマンドが記載される
- 一気通貫フロー（`/rite:issue:start`）は中断されず続行

**コマンド指定時の挙動:**
- 指定されたコマンドは現在の実行でのみ使用
- `rite-config.yml` への自動保存は行われない
- 恒久的な設定には `/rite:init` または手動編集を案内

---

## 動的レビュアー生成

### 概要

PR の変更内容を分析し、適切なレビュアーを動的に生成してレビューを実行。

### レビュアー選定ロジック

#### Step 1: ファイル種類による判断

| ファイルパターン | 推奨レビュアー |
|-----------------|----------------|
| `**/security/**`, `auth*`, `crypto*` | セキュリティ専門家 |
| `.github/**`, `Dockerfile`, `*.yml` (CI) | DevOps 専門家 |
| `**/*.md`, `docs/**` | テクニカルライター |
| `**/*.test.*`, `**/*.spec.*` | テスト専門家 |
| `**/api/**`, `**/routes/**` | API 設計専門家 |

#### Step 2: 内容解析による判断

diff 内容を LLM が解析し、以下を判断:
- 変更の複雑度
- 必要な専門知識
- 潜在的なリスク領域

#### Step 3: レビュアー数の動的決定

| 条件 | レビュアー数 |
|------|-------------|
| 単一ファイル、10行以下 | 1人 |
| 複数ファイル、100行以下 | 2-3人 |
| 大規模変更、セキュリティ関連 | 4-5人 |

### 動的生成されるレビュアープロファイル例

- **セキュリティ専門家**: 脆弱性、認証、暗号化
- **パフォーマンス専門家**: 最適化、メモリ使用量
- **アクセシビリティ専門家**: WCAG 準拠、スクリーンリーダー対応
- **テクニカルライター**: ドキュメント品質、一貫性
- **アーキテクト**: 設計パターン、依存関係
- **DevOps 専門家**: CI/CD、インフラ、デプロイ

### レビュー結果形式

```markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: マージ可 / 条件付きマージ可 / 修正必要

### 各レビュアーの評価

#### セキュリティ専門家
- **評価**: 可
- **コメント**: 認証ロジックに問題なし

#### パフォーマンス専門家
- **評価**: 条件付き
- **コメント**: N+1 クエリの可能性あり（L45-52）

...
```

---

## Workflow Incident Detection

### 概要 (#366)

rite workflow は `/rite:issue:start` の一気通貫実行中に発生する **workflow blocker** (Skill ロード失敗 / hook 異常終了 / 手動 fallback 採用) を自動検出し、Issue として登録することで silent loss を防ぎます。これは PR #363 で実証された通り、Skill loader bug (#365) のような workflow blocker が発生しても手動 Edit fallback で workflow を継続した瞬間に incident の追跡が消える問題への対策です。

### 検出スコープ

| Type | トリガー | ソース |
|------|---------|--------|
| `skill_load_failure` | Skill tool のロード失敗 (例: Markdown parser bash 解釈エラー) | Orchestrator post-condition check (期待される結果パターン欠如) |
| `hook_abnormal_exit` | hook script が non-zero exit code または stderr ERROR を返す | Skill 内部 failure path (file 修正エラー、work memory PATCH 失敗 等) |
| `manual_fallback_adopted` | ユーザーが orchestrator の `AskUserQuestion` で「手動 Edit fallback」を選択 | Orchestrator fallback prompts (Phase 5.2 lint:aborted, Phase 5.3 pr:create-failed, Phase 5.4.4 fix:error, Phase 5.5 ready:error) |

### Sentinel フォーマット

`root_cause_hint` は**任意**フィールドであり、空の場合は sentinel 行から完全に省略されます:

```
[CONTEXT] WORKFLOW_INCIDENT=1; type=<type>; details=<details>; (root_cause_hint=<hint>; )?iteration_id=<pr>-<epoch>
```

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|-----|------|
| `type` | enum | 必須 | `skill_load_failure` / `hook_abnormal_exit` / `manual_fallback_adopted` のいずれか |
| `details` | string | 必須 | 1 行の incident description (semicolon は comma に置換、改行は除去) |
| `root_cause_hint` | string | 任意 | 原因仮説 (空の場合は sentinel から省略) |
| `iteration_id` | string | 必須 | `{pr_number}-{epoch_seconds}` 形式の追跡 ID |

Sentinel は `plugins/rite/hooks/workflow-incident-emit.sh` から emit されます。検出は `/rite:issue:start` Phase 5.4.4.1 で context grep により行われます。

### 検出ロジック

1. **Sentinel 検出**: Phase 5.4.4.1 で Phase 5 の各 Skill invocation 後に context grep で `[CONTEXT] WORKFLOW_INCIDENT=1` 行を検索
2. **フィールド解析**: `type`, `details`, `root_cause_hint`, `iteration_id` を抽出
3. **重複制御**: context-local の `workflow_incident_processed_types` set で session 内処理済み type を追跡。再発時は silent log のみで再提示しない
4. **ユーザー確認**: `AskUserQuestion` で incident 詳細を提示し、「Issue として登録 (推奨) / skip」の選択を取得
5. **Issue 作成**: ユーザー承認時に `plugins/rite/scripts/create-issue-with-projects.sh` を `Status: Todo / Priority: High / Complexity: S / source: workflow_incident` で呼び出し
6. **Non-blocking エラーハンドリング**: Issue 作成失敗時も workflow は中断せず、incident は `workflow_incident_skipped` リストに retain され Phase 5.6 で報告

### 設定

```yaml
workflow_incident:
  enabled: true              # default-on; false で完全無効化
```

`workflow_incident:` セクションが未記載の場合はデフォルト値 (`enabled: true`) が適用されます。

現状の実装は常に non-blocking（登録失敗時も workflow を中断しない）で、session 内の同 type incident は1件に集約されます。

### Acceptance Criteria マッピング

| AC | 振る舞い | 実装場所 |
|----|---------|---------|
| AC-1 | Skill load failure 検出 | `start.md` Phase 5.4.4.1 context grep + skill 内部 sentinel emit |
| AC-2 | ユーザー承認時の Issue 作成 | `create-issue-with-projects.sh` 呼び出し (`Priority: High / Complexity: S`) |
| AC-3 | skip 経路 retain | `workflow_incident_skipped` リスト + Phase 5.6 報告セクション |
| AC-4 | 同 type 重複制御 | `workflow_incident_processed_types` context-local set |
| AC-5 | hook 異常終了の検出 | `workflow-incident-emit.sh --type hook_abnormal_exit` (skill failure path から) |
| AC-6 | 手動 fallback 採用検出 | Orchestrator fallback prompt option が `--type manual_fallback_adopted` を emit |
| AC-7 | default-on | Phase 5.0 Step 6 で config 読み込み (未記載時は `true`) |
| AC-8 | opt-out | `workflow_incident.enabled: false` で Phase 5.4.4.1 を完全 skip |
| AC-9 | Phase 7 との非干渉 | 独立 codepath; `create-issue-with-projects.sh` のみ共有 |
| AC-10 | 登録失敗時 non-blocking | `non_blocking_projects: true` + stderr warning + workflow 続行 |

### Phase 7 との関係

Phase 7 (review recommendation からの自動 Issue 作成) と Phase 5.4.4.1 (Workflow Incident Detection) は **独立した codepath** であり、`create-issue-with-projects.sh` のみを共通ヘルパーとして共有します。両者は同じ `/rite:issue:start` フロー内で同時実行され、それぞれ独立した Issue を作成します。ロジックの融合はありません。

| Phase | 目的 | source フィールド |
|-------|------|------------------|
| Phase 7 | reviewer の「別 Issue として作成」推奨から Issue 作成 | `pr_review` |
| Phase 5.4.4.1 | workflow blocker から Issue 作成 (sentinel 検出) | `workflow_incident` |

## Experience Wiki

### 概要

Experience Wiki は LLM 駆動のプロジェクト経験則ナレッジベースで、通常はレビュアーの頭の中や Issue/PR コメントに散在する「痛い目に合って学んだこと」を永続化します。LLM Wiki パターン（Karpathy 提唱）に基づきます。設計の全体像は `docs/designs/experience-heuristics-persistence-layer.md` を参照してください。

Wiki はデフォルトで **opt-out**（`wiki.enabled: true`）です。設定は `rite-config.yml` の `wiki:` セクションで行います — 詳細は [設定リファレンス → wiki](CONFIGURATION.md#wiki) を参照。

### アーキテクチャ

Wiki データは専用ブランチ（デフォルト: `wiki`）または作業ブランチ上にインラインで保存され、`wiki.branch_strategy` で制御されます。各 Wiki ページはトピック別の Markdown ファイル（例: `review-quality.md`, `fix-cycle-convergence.md`）で、Raw Source（レビューコメント、修正結果、Issue ディスカッション）から差分で構築されます。重複や類似経験則は ingest パイプライン内で統合されます。

### コマンド

| コマンド | 目的 |
|---------|------|
| `/rite:wiki:init` | 初回セットアップ: Wiki ブランチ作成（`branch_strategy: "separate_branch"` 時）、ディレクトリ構造生成、ページテンプレート展開 |
| `/rite:wiki:ingest` | Raw Source（レビュー結果、修正結果、クローズ済み Issue）を解析し Wiki ページを更新または新規作成。手動呼び出しまたは `wiki-ingest-trigger.sh` フックから自動起動 |
| `/rite:wiki:query` | キーワードで Wiki ページを検索し、マッチした経験則をコンテキストに注入。手動呼び出しまたは Issue 着手・レビュー・修正・実装フェーズで `wiki-query-inject.sh` フックから自動起動 |
| `/rite:wiki:lint` | Wiki ページの矛盾、陳腐化、孤児（相互参照が無いページ）、欠落した相互参照、壊れたリンクをチェック。CI 用の `--auto` モードをサポート |

### 自動フック連携

`wiki.auto_ingest` / `wiki.auto_query` / `wiki.auto_lint` が有効な場合、以下のフックがユーザー操作なしで発火します。

| フック | トリガ | アクション |
|--------|-------|-----------|
| `wiki-query-inject.sh` | Phase 2.6（work memory 初期化）、Phase 5.1（実装）、Phase 5.4.1（レビュー）、Phase 5.4.4（修正） | 現在の Issue タイトル/本文に対して `/rite:wiki:query` を実行し、マッチした経験則を注入 |
| `wiki-ingest-trigger.sh` | Phase 5.4.3（レビュー後）、Phase 5.4.6（修正後）、Issue クローズ時 | 新しい Raw Source に対して `/rite:wiki:ingest` を実行 |
| `wiki-ingest-trigger.sh` → `/rite:wiki:lint --auto` | ingest 成功直後（`auto_lint: true` 時） | Wiki の整合性を検証し、警告を非ブロッキングで表示 |

### Workflow Incident Detection との関係

両機能とも運用上の学びを永続化しますが、対象スコープが異なります。

| 対象 | 永続化先 |
|------|---------|
| **反復する品質・プロセス経験則**（例: 「review-fix ループで LOW 指摘をスキップしてはならない」「dotenv でなく dotenvx を使う」） | `/rite:wiki:ingest` による Wiki ページ |
| **一回きりのプラットフォーム欠陥**（例: 「イテレーション Y で hook X が異常終了した」） | `workflow_incident` 自動登録による Issue (#366) |

両者はコードパスを共有しません。

## エラーハンドリング

### 自動リトライ

| エラー種別 | リトライ回数 | 間隔 |
|-----------|-------------|------|
| GitHub API 一時エラー (5xx) | 3回 | 指数バックオフ |
| ネットワークエラー | 3回 | 5秒 |
| レートリミット (429) | 待機後1回 | API 指定時間 |

### 手動回復案内

永続的エラー時は以下を提供:

1. **エラーの詳細説明**
2. **考えられる原因**（複数ある場合はリスト）
3. **回復手順**（ステップバイステップ）
4. **関連ドキュメントへのリンク**

### 一般的なエラーと対処

| エラー | 原因 | 対処 |
|--------|------|------|
| `gh: command not found` | gh CLI 未インストール | `/rite:init` で案内 |
| `authentication required` | GitHub 未認証 | `gh auth login` を案内 |
| `branch already exists` | ブランチ競合 | 別名を提案 |
| `Context limit reached` | 長時間フローがコンテキストウィンドウを超過 | `/clear` → `/rite:resume` |

### Context Limit からの復旧

`/rite:issue:start` などの長時間実行コマンド（一気通貫フロー: ブランチ作成 → 実装 → PR 作成 → レビュー）は、Claude Code のコンテキストウィンドウを超過して `Context limit reached` で中断する場合があります。

**復旧手順:**

1. `/clear` を実行してコンテキストをリセット
2. `/rite:resume` を実行して中断箇所から再開

**仕組み:**

- 作業メモリ（Issue コメント）と `.rite-flow-state` にワークフロー状態が永続化されている
- Git 成果物（ブランチ、コミット、PR）はすべて保持される — 何も失われない
- `/rite:resume` が永続化された状態を読み取り、適切なフェーズから再開する

**保持されるもの:**

| 成果物 | 保存先 | Context limit 後も保持 |
|--------|--------|------------------------|
| ブランチ | Git | はい |
| コミット | Git | はい |
| ドラフト PR | GitHub | はい |
| 作業メモリ | Issue コメント | はい |
| フロー状態 | `.rite-flow-state` | はい |

### API エラーハンドリング

#### リトライ戦略

| エラー種別 | 対応 |
|-----------|------|
| ネットワークエラー | 最大 3 回リトライ（指数バックオフ: 2秒, 4秒, 8秒） |
| レート制限 (403/429) | `Retry-After` ヘッダーに従い待機後リトライ |
| 認証エラー (401) | エラー表示、`gh auth login` 案内 |
| Not Found (404) | エラー表示、設定確認案内 |
| サーバーエラー (5xx) | 最大 2 回リトライ（3秒間隔） |

#### フォールバック戦略

| 状況 | フォールバック動作 |
|------|-------------------|
| Project API 失敗 | Issue 作成のみ実行、Projects 操作はスキップ |
| Iteration API 失敗 | 警告表示、Iteration 操作はスキップ |
| フィールド更新失敗 | 警告表示、次の操作を継続 |
| Status 更新失敗 | 手動更新方法を案内 |

#### エラーメッセージ形式

```
エラー: {エラー概要}

原因: {考えられる原因}

対処:
1. {対処手順1}
2. {対処手順2}

詳細: {技術的な詳細（デバッグ用）}
```

---

## マイグレーション

### 既存プロジェクトへの導入

**ハイブリッド方式:**

- 既存 Issue は参照のみ可能（`/rite:issue:list` で表示）
- 編集・更新は新規作成した Issue のみ
- 既存 Projects がある場合は自動連携

### バージョンアップ

**自動マイグレーション:**

1. 設定ファイル形式の自動変換
2. Projects フィールド構成の更新
3. 破壊的変更時はバックアップ作成

```yaml
# マイグレーション例（v1.0 → v2.0）
# 自動的に新形式に変換され、元ファイルは .bak として保存
```

---

## 多言語対応

### 言語自動検出

1. ユーザーの入力言語を検出（直近の入力から判断）
2. システムロケールを参照
3. 設定ファイルの `language` 設定

### 対応言語

- 日本語 (ja)
- 英語 (en)

### 言語ファイル構成

言語ファイルは言語とドメインごとに分割されたディレクトリ構造を使用:

```
plugins/rite/i18n/
├── en.yml              # 英語（deprecated、後方互換性のため保持）
├── ja.yml              # 日本語（deprecated、後方互換性のため保持）
├── en/
│   ├── common.yml      # 共通メッセージ（コマンド間で共有）
│   ├── issue.yml       # Issue 関連メッセージ
│   ├── pr.yml          # PR 関連メッセージ
│   └── other.yml       # その他メッセージ（init, resume, lint 等）
└── ja/
    ├── common.yml      # 共通メッセージ
    ├── issue.yml       # Issue 関連メッセージ
    ├── pr.yml          # PR 関連メッセージ
    └── other.yml       # その他メッセージ（init, resume, lint 等）
```

各ドメインファイルにはコマンドコンテキストごとにグループ化されたキーが含まれます（例: `# rite:init`, `# rite:resume`）。メッセージはコマンド内で `{i18n:key_name}` プレースホルダー構文で参照されます。

---

## 依存関係

### 必須

| ツール | 用途 | インストール確認 |
|--------|------|-----------------|
| gh CLI | GitHub API 操作 | `gh --version` |

### オプション

| ツール | 用途 |
|--------|------|
| プロジェクト固有のビルドツール | ビルド・テスト・リント |

---

## 配布方法

Claude Code プラグインシステムを通じて配布:

```bash
# マーケットプレイスを追加
/plugin marketplace add B16B1RD/cc-rite-workflow

# プラグインをインストール
/plugin install rite@rite-marketplace
```

---

## プロジェクト種別

### 対応種別

| 種別 | 説明 | 特徴 |
|------|------|------|
| `generic` | 汎用 | 基本的なフィールド構成 |
| `webapp` | Web アプリケーション | フロント/バック/DB 区分 |
| `library` | OSS ライブラリ | 破壊的変更・CHANGELOG 重視 |
| `cli` | CLI ツール | コマンド変更・互換性重視 |
| `documentation` | ドキュメント | ビルド・リンク確認重視 |

### 種別別 PR テンプレート

#### generic

```markdown
## 概要
<!-- 1-2文の説明 -->

## 変更内容
- 変更点

## チェック項目
- [ ] テスト済み
- [ ] ドキュメント更新済み

Closes #XXX
```

#### webapp

```markdown
## 概要

## 変更内容
- [ ] フロントエンド
- [ ] バックエンド
- [ ] データベース

## スクリーンショット
<!-- 該当する場合 -->

## テスト計画
- [ ] ユニットテスト
- [ ] E2E テスト
- [ ] 手動テスト

## パフォーマンス影響
<!-- 該当する場合 -->

Closes #XXX
```

#### library

```markdown
## 概要

## 変更内容

## 破壊的変更
- [ ] なし
- [ ] あり（詳細: ）

## マイグレーションガイド
<!-- 破壊的変更がある場合 -->

## テスト
- [ ] ユニットテスト
- [ ] 統合テスト

## ドキュメント
- [ ] API ドキュメント更新
- [ ] README 更新
- [ ] CHANGELOG 更新

Closes #XXX
```

#### cli

```markdown
## 概要

## 変更内容

## コマンド変更
- [ ] 新規コマンド追加
- [ ] 既存コマンド変更
- [ ] オプション追加/変更

## 互換性
- [ ] 後方互換性あり
- [ ] 破壊的変更あり

## ヘルプ/マニュアル
- [ ] --help 更新
- [ ] man ページ更新

Closes #XXX
```

#### documentation

```markdown
## 概要

## 変更内容
- [ ] 新規ドキュメント
- [ ] 既存ドキュメント更新
- [ ] 構成変更

## チェック項目
- [ ] ビルド成功
- [ ] リンク確認
- [ ] スペルチェック
- [ ] スタイルガイド準拠

## プレビュー
<!-- プレビュー URL 等 -->

Closes #XXX
```

---

## 今後の拡張予定

1. **AI コードレビュー強化**
   - より詳細なセキュリティ分析
   - パフォーマンス最適化提案

2. **CI/CD 連携**
   - GitHub Actions との統合
   - 自動デプロイトリガー

3. **メトリクス・ダッシュボード**
   - 開発速度の可視化
   - Issue 解決時間の分析

---

## 参考資料

- [Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices)
- [Best Practices 対応表](BEST_PRACTICES_ALIGNMENT.md) - rite workflow のベストプラクティス準拠状況
- [Claude Code Plugins Reference](https://code.claude.com/docs/en/plugins-reference)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
- [Conventional Commits](https://www.conventionalcommits.org/)
