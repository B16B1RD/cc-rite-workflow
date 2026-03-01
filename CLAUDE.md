# CLAUDE.md

Claude Code Rite Workflow - Claude Code 用 Issue ドリブン開発ワークフロープラグイン

## アーキテクチャ

```
.claude-plugin/       # プラグインメタデータ（marketplace.json）
plugins/rite/
├── commands/         # スキルから呼び出される実行手順書（Markdown）
│   ├── issue/        #   Issue 操作（start, create, list, edit, close, update）
│   ├── pr/           #   PR 操作（create, review, fix, ready, cleanup）
│   ├── sprint/       #   Sprint 操作（plan, list, current）
│   ├── skill/        #   スキル操作（suggest）
│   ├── template/     #   テンプレート操作（reset）
│   ├── init.md       #   初回セットアップ
│   ├── lint.md       #   品質チェック
│   ├── resume.md     #   作業再開
│   └── workflow.md   #   ワークフローガイド表示
├── skills/           # Claude Code が自動検出するスキル定義（SKILL.md）
│   ├── rite-workflow/  #   メインスキル + references/（コーディング原則、コンテキスト管理等）
│   └── reviewers/     #   レビュアースキル + 各レビュー基準
├── agents/           # PR レビュー用サブエージェント定義
├── templates/        # 完了報告・Issue・PR テンプレート
├── references/       # gh CLI パターン、GraphQL ヘルパー
├── hooks/            # セッション開始/終了、通知、pre-compact、stop-guard
└── i18n/             # 多言語対応（ja.yml, en.yml）
rite-config.yml        # プロジェクト固有設定（ブランチ戦略、Projects連携等）
```

**コンポーネント間の関係**: スキル（`skills/`）がエントリポイント → コマンド（`commands/`）を Skill ツール経由で実行 → コマンド内からエージェント（`agents/`）やリファレンス（`references/`）を参照

## 開発ルール

- **ブランチ**: `develop` ベース、`{type}/issue-{number}-{slug}` 命名
- **コミット**: Conventional Commits 形式（`feat`, `fix`, `docs`, `refactor`, `chore`）
- **PR**: `develop` に向けて作成

## テスト・検証

現時点でビルド・テスト・lint コマンドは未設定（`rite-config.yml` の `commands` セクション参照）。変更の検証は以下で実施:

- `/rite:lint` でプロジェクト設定に基づく品質チェック
- `/rite:pr:review` でセルフレビュー（マルチレビュアー方式）
- 手動: スキル・コマンドの変更は次回呼び出し時に反映されるため、実際に実行して動作確認

## ドッグフーディング注意事項

このリポジトリは Rite Workflow 自体を Rite Workflow で開発している。

- **`rite@rite-marketplace: false` を維持すること**: `~/.claude/settings.json` の `enabledPlugins` で `rite@rite-marketplace` が `true` になっていると、キャッシュされた古いマーケットプレイス版が優先ロードされ、ローカルの修正が一切反映されない（PR #591, Issue #809 で確認済み）
- **CLAUDE.md の変更は即座に影響する**: 編集内容は現在の Claude Code セッションで即座に参照される
- **skills/ や commands/ の変更は次回呼び出しから反映**: Skill ツール経由で呼び出されるたびに最新のファイル内容が読み込まれる
- **自己参照ループに注意**: ワークフロー仕様の変更中にそのワークフローを使って作業するため、変更前後で動作が変わる可能性がある
