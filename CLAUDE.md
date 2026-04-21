# CLAUDE.md

Claude Code Rite Workflow - Claude Code 用 Issue ドリブン開発ワークフロープラグイン

## アーキテクチャ

```
.claude-plugin/                    # マーケットプレイスメタデータ（marketplace.json）
plugins/rite/.claude-plugin/       # プラグイン固有メタデータ（plugin.json）
plugins/rite/
├── commands/         # スキルから呼び出される実行手順書（Markdown）
│   ├── issue/        #   メイン (list, create, start, update, close, edit, recall) +
│   │                 #   サブスキル (create-{interview,decompose,register}, implement,
│   │                 #   implementation-plan, completion-report, branch-setup,
│   │                 #   parent-routing, child-issue-selection, work-memory-init)
│   ├── pr/           #   メイン (create, ready, review, fix, cleanup) +
│   │                 #   references/ (fact-check, internal-consistency, fix-relaxation-rules,
│   │                 #   assessment-rules, reviewer-fallbacks, bash-trap-patterns 等)
│   ├── sprint/       #   Sprint 操作（list, current, plan, execute, team-execute）
│   ├── wiki/         #   Experience Wiki 操作（init, query, ingest, lint）+ references/
│   ├── skill/        #   /rite:skill:suggest
│   ├── template/     #   /rite:template:reset
│   └── init.md / getting-started.md / investigate.md / lint.md / resume.md / workflow.md
├── skills/           # Claude Code が自動検出するスキル定義（SKILL.md）
│   ├── rite-workflow/  #   メインスキル + references/（コーディング原則、コンテキスト管理）
│   ├── reviewers/      #   レビュアースキル + 13 種別の基準ファイル + references/
│   ├── investigate/    #   コード調査スキル
│   └── wiki/           #   Experience Wiki スキル（opt-out）
├── agents/           # PR レビュー用サブエージェント定義
│                     # _reviewer-base.md（共通原則）+ 13 reviewer agent + sprint-teammate
├── templates/        # config/（rite-config.yml 最小デフォルト）、project-types/、
│                     # issue/, pr/, review/, wiki/ の各フォーマット
├── references/       # gh CLI パターン、GraphQL、severity-levels、investigation-protocol、
│                     # wiki-patterns、workflow-incident-emit-protocol、review-result-schema 等
├── scripts/          # Projects 統合 Issue 作成、Sub-Issue リンク、レビュー結果抽出・計測 等
├── hooks/            # Claude Code ライフサイクルフック（session / compact / stop-guard /
│   │                 # preflight / pre-tool-bash-guard / post-tool-wm-sync /
│   │                 # phase-transition-whitelist / verify-terminal-output /
│   │                 # wiki-ingest-trigger / wiki-query-inject / workflow-incident-emit /
│   │                 # session-ownership / hook-preamble 等）+ hooks.json
│   ├── scripts/      #   Wiki commit / worktree / backlink / gitignore-health check 等のヘルパー
│   └── tests/        #   hook レベルの自動テストスイート
└── i18n/             # 多言語対応（ja.yml / en.yml の legacy + ja/, en/ 配下の分割ファイル）
rite-config.yml        # プロジェクト固有設定（ブランチ戦略、Projects連携、Wiki、review loop 等）
```

**コンポーネント間の関係**: スキル（`skills/`）がエントリポイント → コマンド（`commands/`）を Skill ツール経由で実行 → コマンド内からエージェント（`agents/`）やリファレンス（`references/` / `commands/*/references/`）を参照。hooks/ は Claude Code のライフサイクルから独立に発火し、orchestrator とコンテキスト注入・sentinel emit で連携する。ディレクトリ・ファイルの完全な一覧は `docs/SPEC.md` の Plugin Structure 節を参照。

## 開発ルール

- **ブランチ**: `develop` ベース、`{type}/issue-{number}-{slug}` 命名
- **コミット**: Conventional Commits 形式（`feat`, `fix`, `docs`, `refactor`, `chore`）
- **PR**: `develop` に向けて作成

## テスト・検証

現時点でビルド・テスト・lint コマンドは未設定（`rite-config.yml` の `commands` セクション参照）。変更の検証は以下で実施:

- `/rite:lint` でプロジェクト設定に基づく品質チェック
- `/rite:pr:review` でセルフレビュー（マルチレビュアー方式）
- 手動: スキル・コマンドの変更は次回呼び出し時に反映されるため、実際に実行して動作確認

## メモリ機能

このプロジェクトでは Claude Code のメモリ機能（`~/.claude/projects/*/memory/`）を使用しない。ワークフローの方針は `rite-config.yml`、`commands/`、`skills/` で表現すること。メモリファイルの新規作成・更新は行わないこと。

## ドッグフーディング注意事項

このリポジトリは Rite Workflow 自体を Rite Workflow で開発している。

- **`rite@rite-marketplace: false` を維持すること**: `~/.claude/settings.json` の `enabledPlugins` で `rite@rite-marketplace` が `true` になっていると、キャッシュされた古いマーケットプレイス版が優先ロードされ、ローカルの修正が一切反映されない（PR #591, Issue #809 で確認済み）
- **CLAUDE.md の変更は即座に影響する**: 編集内容は現在の Claude Code セッションで即座に参照される
- **skills/ や commands/ の変更は次回呼び出しから反映**: Skill ツール経由で呼び出されるたびに最新のファイル内容が読み込まれる
- **自己参照ループに注意**: ワークフロー仕様の変更中にそのワークフローを使って作業するため、変更前後で動作が変わる可能性がある
