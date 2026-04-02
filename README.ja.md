# Claude Code Rite Workflow

> Claude Code 用汎用 Issue ドリブン開発ワークフロー

[![Version](https://img.shields.io/badge/version-0.3.8-blue.svg)](https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.3.8)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## なぜ "Rite" なのか

名前は英語の **rite**（儀式・作法）に由来しています。Issue を作り、ブランチを切り、実装し、レビューし、マージする — この一連の開発プラクティスを、チームが自然と身につける「お作法」として定着させたい。Rite Workflow はこれらのプラクティスを再現可能な儀式として組み込み、ソフトウェア開発の当たり前のやり方にします。

## 概要

**Claude Code Rite Workflow** は Claude Code 用プラグインで、Issue ドリブン開発ワークフローを提供します。言語やフレームワークに依存せず、あらゆるソフトウェア開発プロジェクトで利用できます。

### 特徴

- **汎用性**: 特定の技術スタックに依存しない
- **自動化**: プロジェクトタイプの自動検出・自動設定
- **カスタマイズ**: YAML による柔軟な設定
- **連携**: GitHub Projects、通知機能（Slack/Discord/Teams）
- **スマートレビュー**: 動的なマルチレビュアーコードレビュー
- **スプリント管理**: Iteration/スプリント管理（チーム実行対応）
- **TDD Light モード**: 受入条件からテストスケルトンを先行生成
- **Preflight チェック**: 全コマンド統一の事前検証
- **ローカル作業メモリ**: compact 耐性のある作業状態管理（ロック・再開対応）
- **Implementation Contract**: 明確な仕様記述のための構造化 Issue テンプレート

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
| `/rite:lint` | プロジェクト lint 実行 |
| `/rite:template:reset` | テンプレートリセット |
| `/rite:sprint:list` | スプリント一覧表示（オプション） |
| `/rite:sprint:current` | 現在のスプリント詳細（オプション） |
| `/rite:sprint:plan` | スプリント計画（オプション） |
| `/rite:sprint:execute` | スプリント Issue を順次実行（オプション） |
| `/rite:sprint:team-execute` | worktree ベースの並列チーム実行（オプション） |
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
  release: "main"    # 本番デプロイ用リリースブランチ
  pattern: "{type}/issue-{number}-{slug}"

# Git Flow を使用する場合:
# branch:
#   base: "develop"    # develop から作業ブランチを作成
#   release: "main"    # main に本番リリース

commit:
  style: conventional

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
