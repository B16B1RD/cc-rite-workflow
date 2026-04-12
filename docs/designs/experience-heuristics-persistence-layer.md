# プロジェクトごとの経験則 Wiki 層の導入

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

rite-workflow に LLM Wiki パターン（Karpathy）に基づく **経験則の永続知識層** を追加する。各プロジェクトのリポジトリ内に、実装・レビュー・Fix の3領域における経験則を Markdown Wiki として蓄積・参照・メンテナンスする仕組みを導入する。

現在の rite には「規範（静的な手順書: `skills/`, `references/`）」と「作業中メモ（エフェメラル: `.rite-work-memory/`）」はあるが、「経験則（プロジェクトで学んだこと）」を蓄積する中間層が欠けている。この欠落層を LLM Wiki パターンで埋める。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

複数プロジェクトで Claude Code を運用する中で、**実装品質・レビュー品質・レビュー修正品質** において「同じ種類の過ち」が繰り返し発生する。表層は毎回異なるが、プロジェクト固有の構造的要因（ドメイン、コードベースの癖、依存関係、運用制約）と結びついたパターンが存在する。

Karpathy の LLM Wiki パターンは「知識は加工して永続化することで複利が効く」という思想を持ち、rite の「ハーネスは長く走らせるための運用環境」という思想と同じ方向を向いている。rite に Wiki 層を接続することで、ハーネスの射程を「1実行の安全な完走」から「プロジェクトの継続的な経験蓄積」に拡張する。

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

#### F1: 3層構造の導入

LLM Wiki パターンに基づく3層構造をプロジェクトリポジトリ内に導入する。

| 層 | 場所 | 所有者 | 性質 |
|---|---|---|---|
| **Raw Sources** | `.rite/wiki/raw/` | rite ワークフロー（自動生成） | 不変の一次データ（レビュー結果、Issue 振り返り等） |
| **Wiki** | `.rite/wiki/pages/` | LLM（自動生成・更新） | 読解・統合された加工済み知識ページ |
| **Schema** | `.rite/wiki/SCHEMA.md` | 人間 + LLM（共同管理） | 何を蓄積するかの規約 |

#### F2: Ingest サイクル（経験則の蓄積）

以下のタイミングで経験則を自動抽出・蓄積する:

| トリガー | 抽出元 | 抽出内容 |
|---------|--------|---------|
| PR レビュー完了時 | `/rite:pr:review` 結果 | 指摘パターン、頻出エラー、プロジェクト固有の癖 |
| Issue クローズ時 | `/rite:issue:close` 実行時 | 実装での学び、予想外の困難、有効だったアプローチ |
| レビュー Fix 完了時 | `/rite:pr:fix` 結果 | 修正パターン、過剰反応の傾向、効果的な修正戦略 |
| 手動実行 | `/rite:wiki:ingest` コマンド | ユーザーが明示的に指定した知見 |

Ingest 時の処理フロー:
1. Raw Source を `.rite/wiki/raw/` に保存（不変）
2. LLM が Raw Source を読解し、既存 Wiki ページとの関連を分析
3. 新規ページ作成 or 既存ページ更新
4. `index.md` を更新
5. `log.md` にエントリを追記
6. Lint（矛盾チェック）を自動実行

#### F3: Query サイクル（経験則の参照）

rite ワークフロー実行時に関連経験則を自動参照し、コンテキストに注入する:

| 参照タイミング | 参照先 | 注入先 |
|-------------|--------|--------|
| `/rite:issue:start` 実行時 | 類似 Issue の経験則 | 実装計画のコンテキスト |
| `/rite:pr:review` 実行時 | 対象ファイル/領域の経験則 | レビュアーのコンテキスト |
| `/rite:pr:fix` 実行時 | 類似指摘の修正経験則 | Fix のコンテキスト |
| `/rite:issue:implement` 実行時 | 類似実装の経験則 | 実装のコンテキスト |

品質優先: 関連する経験則は積極的に注入し、コンテキストコストよりも参照品質を優先する。

#### F4: Lint サイクル（Wiki の品質維持）

| 実行方法 | タイミング | 検出対象 |
|---------|----------|---------|
| 自動 | Ingest 時 | 新規ページと既存ページの矛盾 |
| 手動 | `/rite:wiki:lint` コマンド | 矛盾、陳腐化、孤児ページ、欠落概念、壊れた相互参照 |

#### F5: インデックスとログ

| ファイル | 役割 | 更新タイミング |
|---------|------|-------------|
| `.rite/wiki/index.md` | 全 Wiki ページのカタログ（リンク + 一行サマリー + メタデータ） | 毎回の Ingest |
| `.rite/wiki/log.md` | 活動の時系列記録（append-only） | 毎回の Ingest/Query/Lint |

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

| 要件 | 方針 |
|------|------|
| **参照品質** | コンテキストウィンドウコストよりも品質を優先。関連経験則は積極的に注入する |
| **Git 管理** | Wiki は別ブランチ or 別リポジトリで管理し、PR diff との分離を確保する |
| **スケーラビリティ** | index.md ベースの検索で対応（小〜中規模）。将来的にベクトル検索を追加可能な設計 |
| **既存ワークフローへの影響** | 既存コマンドの動作を変更しない。Wiki 参照はアドオンとして注入する |

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

| 決定事項 | 選択 | 根拠 |
|---------|------|------|
| 知識層パターン | LLM Wiki（Karpathy） | 3層構造 + Ingest/Query/Lint サイクルが rite のワークフローと親和性が高い |
| ファイル形式 | Markdown + YAML frontmatter | 人間が直接読み書き可能 + メタデータによる構造化検索の両立 |
| スコープ | プロジェクトごと（リポジトリ内） | プロジェクト横断は将来スコープ |
| 蓄積対象 | 全3領域（実装・レビュー・Fix） | 初期から全領域をカバーし、経験則の相互参照を可能にする |
| トレードオフ | 品質 > コンテキストコスト | 経験則の参照漏れによる品質低下の方がコンテキスト消費より損失が大きい |

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

```
plugins/rite/
├── commands/wiki/           # Wiki 操作コマンド
│   ├── init.md              #   Wiki 初期化
│   ├── ingest.md            #   経験則の蓄積
│   ├── query.md             #   経験則の参照
│   └── lint.md              #   Wiki の品質チェック
├── skills/rite-workflow/     # 既存スキル（Wiki 参照フックを追加）
├── hooks/                    # 既存フック（Ingest トリガーを追加）
│   ├── wiki-ingest-trigger.sh  # Ingest トリガーフック
│   └── wiki-query-inject.sh    # Query 注入フック
├── references/
│   └── wiki-patterns.md      # Wiki 操作の共通パターン
└── templates/wiki/           # Wiki ページテンプレート
    ├── page-template.md      #   知識ページのテンプレート
    ├── schema-template.md    #   Schema の初期テンプレート
    ├── index-template.md     #   インデックス初期テンプレート
    └── log-template.md       #   活動ログ初期テンプレート

.rite/wiki/                   # プロジェクト固有の Wiki データ（Git 別ブランチ管理）
├── SCHEMA.md                 # Schema: 蓄積規約
├── index.md                  # 全ページのカタログ
├── log.md                    # 活動ログ（append-only）
├── raw/                      # Raw Sources（不変の一次データ）
│   ├── reviews/              #   レビュー結果
│   ├── retrospectives/       #   Issue 振り返り
│   └── fixes/                #   Fix 結果
└── pages/                    # Wiki ページ（LLM 所有）
    ├── patterns/             #   繰り返しパターン
    ├── heuristics/           #   経験則
    └── anti-patterns/        #   アンチパターン
```

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

```
[rite ワークフロー実行]
    │
    ├─── Ingest トリガー ──→ [Raw Source 保存] ──→ [LLM 読解・統合] ──→ [Wiki ページ更新]
    │                                                                        │
    │                                                                   [index.md 更新]
    │                                                                        │
    │                                                                   [log.md 追記]
    │                                                                        │
    │                                                                   [自動 Lint]
    │
    └─── Query フック ──→ [index.md 検索] ──→ [関連ページ取得] ──→ [コンテキスト注入]
```

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

| 領域 | 変更内容 |
|------|---------|
| `plugins/rite/commands/wiki/` | 新規: init.md, ingest.md, query.md, lint.md |
| `plugins/rite/skills/` | 新規: wiki スキル定義（SKILL.md） |
| `plugins/rite/hooks/` | 新規: wiki-ingest-trigger.sh, wiki-query-inject.sh |
| `plugins/rite/templates/wiki/` | 新規: ページテンプレート、Schema テンプレート |
| `plugins/rite/references/` | 新規: wiki-patterns.md |
| `plugins/rite/commands/pr/review.md` | 修正: Ingest トリガー + Query 注入の統合 |
| `plugins/rite/commands/issue/start.md` | 修正: Query 注入の統合 |
| `plugins/rite/commands/issue/close.md` | 修正: Ingest トリガーの統合 |
| `plugins/rite/commands/pr/fix.md` | 修正: Ingest トリガー + Query 注入の統合 |
| `rite-config.yml` | 修正: Wiki 設定セクションの追加 |
| `.gitignore` | 修正: `.rite/wiki/` の管理方針（別ブランチの場合は不要） |

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

| カテゴリ | 考慮事項 |
|---------|---------|
| **コンテキスト圧力** | Wiki 参照時に大量のページを注入するとコンテキストを圧迫する。index.md による事前フィルタリングで関連度の高いページのみ注入する |
| **Wiki の肥大化** | Schema による蓄積規約が不明確だと低品質な経験則が蓄積される。Lint サイクルで定期的に品質を維持する |
| **Git ブランチ管理** | Wiki ブランチと開発ブランチの同期タイミング、コンフリクト解決戦略が必要 |
| **初期状態** | 新規プロジェクトや Wiki 未初期化時のフォールバック動作を定義する |
| **後方互換性** | Wiki 機能は opt-in。`rite-config.yml` の `wiki.enabled: false`（デフォルト）で既存動作に影響しない |

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

| 項目 | 理由 |
|------|------|
| プロジェクト横断の経験則共有 | 将来スコープ。まずプロジェクト内で価値を実証する |
| ベクトルストア / 外部 DB 統合 | index.md ベース検索で十分。スケール問題が顕在化してから検討 |
| GUI / Web UI による Wiki 閲覧 | CLI + Markdown で十分。Obsidian 等の外部ツールで閲覧可能 |
| Claude Code auto-memory との統合 | 別メカニズム（`~/.claude/` 配下）。混同を避ける |
| リアルタイム Wiki 更新通知 | Lint で検出すれば十分 |
