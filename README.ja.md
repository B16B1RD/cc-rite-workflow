# Claude Code Rite Workflow

> Claude Code 用汎用 Issue ドリブン開発ワークフロー

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v1.0.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## ⚠️ 破壊的変更 (v1.0.0)

**v1.0.0 — サイクル数ベースの review-fix 縮退を全廃 (#557)**: `review.loop.severity_gating_cycle_threshold`、`review.loop.scope_lock_cycle_threshold`、`safety.max_review_fix_loops` の 3 つの設定キーは無効化されました。review-fix ループの終了条件は **0 findings** または **4 つの品質シグナル** (fingerprint 循環 / root-cause 不明 fix / cross-validation 不一致 / reviewer self-degraded) のいずれかの発火のみとなりました。既存ユーザーは `rite-config.yml` から該当 3 キーを削除してください（`/rite:lint` が削除されるまで警告します）。詳細な移行ガイドは [CHANGELOG](CHANGELOG.ja.md#100---2026-04-17) を参照。

**v0.3 — Named subagent 形式の reviewer 呼び出し (#358)**: `/rite:pr:review` の reviewer 呼び出しを `general-purpose` から **named subagent** (`rite:{reviewer_type}-reviewer`) 形式に切り替えました。これにより reviewer の役割定義が system prompt レベルで強制され、各 reviewer の `model` / `tools` frontmatter が実効化されます。最も顕著な影響: 9 個の reviewer agent が `model: opus` に pin されているため、これまで sonnet で `/rite:pr:review` を実行していたユーザーは強制 opus upgrade となりコストが増加します。詳細な背景、ロールバック手順、opt-out 方法は [`docs/migration-guides/review-named-subagent.md`](docs/migration-guides/review-named-subagent.md) を参照してください。トラッキング: [#358](https://github.com/B16B1RD/cc-rite-workflow/issues/358)。

## なぜ "Rite" なのか

名前は英語の **rite**（儀式・作法）に由来しています。Issue を作り、ブランチを切り、実装し、レビューし、マージする — この一連の開発プラクティスを、チームが自然と身につける「お作法」として定着させたい。Rite Workflow はこれらのプラクティスを再現可能な儀式として組み込み、ソフトウェア開発の当たり前のやり方にします。

## 概要

**Claude Code Rite Workflow** は Claude Code 用プラグインで、Issue ドリブン開発ワークフローを提供します。言語やフレームワークに依存せず、あらゆるソフトウェア開発プロジェクトで利用できます。

### 特徴

- **汎用性**: 特定の技術スタックに依存しない
- **自動化**: プロジェクトタイプの自動検出・自動設定
- **カスタマイズ**: YAML による柔軟な設定
- **連携**: GitHub Projects、通知機能（Slack/Discord/Teams）
- **スマートレビュー**: 動的なマルチレビュアーコードレビュー（ドキュメント中心 PR を自動検出する **Doc-Heavy PR Mode** 対応）。Doc-Heavy PR と判定されると tech-writer reviewer が「文書-実装整合性」5 項目 (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) を Grep/Read/Glob で検証する。検証プロトコルの詳細は [`plugins/rite/commands/pr/references/internal-consistency.md`](plugins/rite/commands/pr/references/internal-consistency.md) を参照
- **外部レビュー統合**: `/rite:pr:fix` は PR URL / コメント URL 引数を受け付け、外部レビューツール（`/verified-review` 等）の出力を fix ループに直接投入可能
- **スプリント管理**: Iteration/スプリント管理（チーム実行対応）
- **TDD Light モード**: 受入条件からテストスケルトンを先行生成
- **Preflight チェック**: 全コマンド統一の事前検証
- **ローカル作業メモリ**: compact 耐性のある作業状態管理（ロック・再開対応）
- **Implementation Contract**: 明確な仕様記述のための構造化 Issue テンプレート
- **Experience Wiki**: LLM 駆動のプロジェクト経験則ナレッジベース。レビュー／修正結果をトピック別ページへ自動統合し、Issue 着手時に関連する経験則をコンテキストに自動注入（opt-out 方式）

## インストール

Rite Workflow は2段階でインストールします。まずマーケットプレイスを登録し、そこからプラグインをインストールします。

**ステップ 1**: マーケットプレイスを追加

```bash
/plugin marketplace add B16B1RD/cc-rite-workflow
```

**ステップ 2**: プラグインをインストール

```bash
/plugin install rite@rite-marketplace
```

**インストール確認**: `/rite:init` を実行してプラグインが動作することを確認してください。

## クイックスタート

```bash
/rite:init
```

このコマンドで以下が実行されます:
1. プロジェクトタイプの検出
2. GitHub Projects 連携の設定
3. Issue/PR テンプレートの生成
4. 設定ファイルの作成

## コマンド一覧

| コマンド | 説明 |
|---------|------|
| `/rite:init` | 初期セットアップウィザード |
| `/rite:getting-started` | 対話型オンボーディングガイド |
| `/rite:workflow` | ワークフロー案内 |
| `/rite:issue:list` | Issue 一覧表示 |
| `/rite:issue:create` | Issue 作成 |
| `/rite:issue:start` | 作業開始（一気通貫: ブランチ → 実装 → PR → レビュー） |
| `/rite:issue:update` | 作業メモリ更新 |
| `/rite:issue:close` | Issue 完了確認 |
| `/rite:issue:edit` | Issue の対話的編集 |
| `/rite:pr:create` | ドラフト PR 作成 |
| `/rite:pr:ready` | PR をレビュー待ちに変更 |
| `/rite:pr:review` | マルチレビュアーレビュー |
| `/rite:pr:fix` | レビュー指摘対応 |
| `/rite:pr:cleanup` | マージ後クリーンアップ |
| `/rite:investigate` | コード調査 |
| `/rite:lint` | プロジェクト lint 実行 |
| `/rite:template:reset` | テンプレートリセット |
| `/rite:sprint:list` | スプリント一覧表示（オプション） |
| `/rite:sprint:current` | 現在のスプリント詳細（オプション） |
| `/rite:sprint:plan` | スプリント計画（オプション） |
| `/rite:sprint:execute` | スプリント Issue を順次実行（オプション） |
| `/rite:sprint:team-execute` | worktree ベースの並列チーム実行（オプション） |
| `/rite:wiki:init` | Experience Wiki のブランチ・ディレクトリ初期化 |
| `/rite:wiki:query` | キーワードから関連する経験則ページを検索 |
| `/rite:wiki:ingest` | Raw Source（レビュー・修正・Issue）を Wiki ページへ統合 |
| `/rite:wiki:lint` | Wiki ページの矛盾・陳腐化・孤児・欠落概念 (`missing_concept`)・未登録 raw (`unregistered_raw`、informational — `n_warnings` 不加算)・壊れた相互参照をチェック |
| `/rite:resume` | 中断した作業を再開 |
| `/rite:skill:suggest` | コンテキストを分析して適用可能なスキルを提案 |

## ワークフロー

コマンド形式:
```
/rite:issue:create → /rite:issue:start (実装 → /rite:lint → /rite:pr:create → /rite:pr:review → /rite:pr:fix) → /rite:pr:ready → マージ → /rite:pr:cleanup
```

**補足:** `/rite:issue:start` はブランチ作成、実装、品質チェック、ドラフト PR 作成、セルフレビュー、レビュー修正までを一気通貫で処理します。詳細は [Phase 5: 一気通貫実行](docs/SPEC.ja.md#phase-5-一気通貫実行) を参照してください。

Status 遷移:
```
Todo → In Progress → In Review → Done
 ↑         ↑            ↑         ↑
作成時   作業開始     Ready設定   マージ後
```

## 設定

プロジェクトルートに `rite-config.yml` を作成:

```yaml
schema_version: 2

project:
  type: webapp  # generic | webapp | library | cli | documentation

github:
  projects:
    enabled: true

branch:
  base: "main"       # フィーチャーブランチの起点
  pattern: "{type}/issue-{number}-{slug}"

# Git Flow を使用する場合:
# branch:
#   base: "develop"    # develop から作業ブランチを作成

commit:
  contextual: true

# オプション: スプリント/イテレーション管理
iteration:
  enabled: false  # true で有効化
```

すべての設定オプションは[設定リファレンス](docs/CONFIGURATION.md)を参照してください。

## トラブルシューティング

| 問題 | 対処法 |
|------|--------|
| 長時間コマンド実行中に `Context limit reached` | `/clear` → `/rite:resume` で再開 |

## ドキュメント

- [仕様書](docs/SPEC.ja.md)
- [設定リファレンス](docs/CONFIGURATION.md)
- [Best Practices 対応表](docs/BEST_PRACTICES_ALIGNMENT.md)
- [English Documentation](README.md)

## 必要要件

- [GitHub CLI (gh)](https://cli.github.com/) - GitHub 操作に必要

## ライセンス

MIT License - 詳細は [LICENSE](LICENSE) を参照してください。

## コントリビューション

コントリビューションを歓迎します！ガイドラインは [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。

---

Made with 📜 rite
