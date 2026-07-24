# Claude Code Rite Workflow

> Claude Code のための汎用 Issue ドリブン開発ワークフロー

[![Version](https://img.shields.io/badge/version-0.9.2-blue.svg)](https://github.com/asakaguchi/cc-rite-workflow/releases/tag/v0.9.2)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

[English](README.md) | **日本語**

## Demo

Issue から PR まで、開発を“儀式”に変える — 約125秒で分かる紹介動画（日本語字幕）。

https://github.com/user-attachments/assets/82ba8e65-0c07-4346-9964-5a482a1f4df5

## なぜ "Rite" なのか

名前は英単語の **rite**（「儀式」「式典」の意）に由来します。Issue ドリブン開発 — Issue を立て、ブランチを切り、実装し、レビューし、マージする — は、どのチームも当たり前の習慣として身につけるべき一連の実践です。Rite Workflow はこれらの実践を繰り返し可能な「儀式」として組み込み、ソフトウェア開発の自然な流儀になるようにします。

## 概要

**Claude Code Rite Workflow** は、Issue ドリブン開発のワークフローを提供する Claude Code プラグインです。言語やフレームワークを問わず、あらゆるソフトウェア開発プロジェクトで動作します。

### 特徴

- **汎用 (Universal)**: 特定の技術スタックに依存しない
- **自動化 (Automated)**: 自動検出・自動設定
- **カスタマイズ可能 (Customizable)**: YAML による柔軟な設定
- **統合 (Integrated)**: GitHub Projects 連携
- **スマートレビュー (Smart Reviews)**: ドキュメント中心の PR に対しドキュメント–実装整合を検証する Doc-Heavy PR Mode を備えた動的マルチレビュアーコードレビュー。検証プロトコルは [`plugins/rite/skills/pr-review/references/internal-consistency.md`](plugins/rite/skills/pr-review/references/internal-consistency.md) を参照
- **外部レビュー連携 (External Review Integration)**: `/rite:fix` は PR URL またはコメント URL を引数に取れるため、外部レビューツールの出力をそのまま fix ループに流し込めます
- **イテレーション追跡 (Iteration Tracking)**: 任意の GitHub Projects Iteration フィールド連携（`/rite:open` 時に自動割当、`/rite:issue-list` の `--sprint` / `--backlog` フィルタ）
- **ローカル作業メモリ (Local Work Memory)**: lock / 再開サポート付きの compact 耐性のある作業状態管理
- **Implementation Contract**: 仕様を明確にする構造化 Issue テンプレート形式
- **仮定の表面化 (Assumption Surfacing)**: `/rite:issue-create` はモデルが暗黙に補った仮定を Implementation Contract に固定される前に表面化して解決し、リポジトリや Wiki から導出できない事項だけをユーザーに質問します。詳細なプロトコルは [docs/SPEC.md](docs/SPEC.md)（Phase 1.5）を参照
- **Experience Wiki**: レビュー/修正の結果を自動取り込みし、各 Issue の冒頭で関連する経験則を注入する LLM 駆動のプロジェクト知識ベース（opt-out 可）。[OKF v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog) 準拠バンドルとして保存されます。詳細は [`plugins/rite/references/wiki-patterns.md`](plugins/rite/references/wiki-patterns.md) を参照
- **sandbox 対応 (Sandbox-aware)**: `/rite:setup` が既知の sandbox 環境制約を失敗が発生する前に事前検出し、対応する回避策を提示します

## インストール

Rite Workflow は 3 ステップでインストールします。マーケットプレイスを登録し、プラグインをインストールし、最後にプラグインを再読み込みして新しいコマンドを有効化します。

**ステップ 1**: マーケットプレイスを追加

```bash
/plugin marketplace add asakaguchi/cc-rite-workflow
```

**ステップ 2**: プラグインをインストール

```bash
/plugin install rite@rite-marketplace
```

**ステップ 3**: プラグインを再読み込み

```bash
/reload-plugins
```

`/reload-plugins` の実行後も `/rite:` コマンドが認識されない場合は、Claude Code を再起動してください。

**インストール確認**: `/rite:setup` を実行してプラグインが動作することを確認します。

## アンインストール

プラグインを削除するには:

```bash
/plugin uninstall rite@rite-marketplace
```

これによりプラグイン本体は削除されますが、プロジェクト内に生成された成果物は残ります。大半は残しても無害ですが、完全な一覧と削除手順は以下の通りです:

| 成果物 | 場所 | 残すと害があるか | 削除方法 |
|--------|------|-------------------|---------|
| `rite-config.yml` | リポジトリに commit 済み | なし | `git rm rite-config.yml && git commit -m "chore: remove rite-config.yml"` |
| `.gitignore` の追記行 | commit 済み（`/rite:setup` が追加した `.rite-work-memory/`、`.rite/sessions/` 等の行） | なし | 追加された行を手動削除 |
| リモート `wiki` ブランチ | GitHub リモート（Wiki 自動初期化で作成） | なし | `git push origin --delete <ブランチ名>`（`<ブランチ名>` は `rite-config.yml` の `wiki.branch_name`、デフォルトは `wiki`） |
| ローカル生成物（gitignore 済み） | `.rite-work-memory/`, `.rite-flow-state*`, `.rite-compact-state*`, `.rite-flow-debug.log`, `.rite-session-id` 等 | なし（未 commit） | `rm -rf .rite-work-memory .rite-flow-state* .rite-compact-state* .rite-flow-debug.log .rite-session-id .rite-guidance-shown .rite-plugin-root .rite-initialized-version .rite-settings-hooks-cleaned` |
| `.rite/` 配下の内部ディレクトリ（gitignore 済み、live な git worktree を含む場合あり） | `.rite/wiki-worktree/`（Wiki `separate_branch` 戦略）、`.rite/worktrees/issue-*`（`multi_session` 有効時のセッション worktree） | 生の `rm -rf` で削除すると git worktree メタデータが孤立し未コミット差分を失う可能性があり、害あり | まず `git worktree list` で確認し、該当パスが登録されていれば `git worktree remove <path>`（未コミット差分がないか確認の上）→ `git worktree prune` を実行してから、残りの `.rite/` を `rm -rf .rite` で削除する |
| レガシー hook 登録 | `.claude/settings.local.json`（`hooks.json` によるネイティブ管理以前のインストールのみ） | なし（ただしプラグイン削除後にエラーになる場合あり） | command パスが rite プラグインの `hooks/` ディレクトリを指す hook エントリを削除 |

いずれも再インストールを妨げたり他のツールに影響したりしないため、都合の良いタイミングで削除してください。

## クイックスタート

```bash
/rite:setup
```

これにより以下が実行されます:
1. プロジェクトタイプを検出
2. GitHub Projects 連携をセットアップ
3. Issue/PR テンプレートを生成
4. 設定ファイルを作成

## コマンド

| コマンド | 説明 |
|---------|------|
| `/rite:setup` | 初回セットアップウィザード |
| `/rite:setup --upgrade` | 既存の `rite-config.yml` を最新スキーマバージョンへアップグレード |
| `/rite:getting-started` | 対話的オンボーディングガイド |
| `/rite:workflow` | ワークフローガイドを表示 |
| `/rite:unknowns` | 実装前探索セッション（盲点洗い出し・ブレスト・使い捨てプロトタイプ・インタビュー）— 任意・手動起動のみ |
| `/rite:issue-list` | Issue 一覧を表示 |
| `/rite:issue-create` | 新規 Issue を作成 |
| `/rite:issue-update` | 作業メモリを更新 |
| `/rite:issue-close` | Issue の完了状態を確認 |
| `/rite:issue-edit` | 既存 Issue を対話的に編集 |
| `/rite:open` | 作業を一気通貫で開始（ブランチ → 計画 → 実装 → lint → draft PR） |
| `/rite:iterate` | mergeable になるまで review ⇄ fix をループ |
| `/rite:merge` | PR を squash merge |
| `/rite:pr-create` | draft PR を作成 |
| `/rite:ready` | Ready for review に変更 |
| `/rite:pr-review` | マルチレビュアーレビュー |
| `/rite:fix` | レビュー指摘に対応 |
| `/rite:cleanup` | マージ後のクリーンアップ |
| `/rite:investigate` | 構造化コード調査 |
| `/rite:lint` | 品質チェックを実行 |
| `/rite:template-reset` | テンプレートを再生成 |
| `/rite:wiki-init` | Experience Wiki のブランチとディレクトリ構成を初期化 |
| `/rite:wiki-query` | キーワードに一致する経験則を Wiki ページから検索 |
| `/rite:wiki-ingest` | Raw Source（レビュー・修正・Issue）を Wiki ページへ取り込み |
| `/rite:wiki-lint` | 矛盾・陳腐化・孤児・欠落概念・壊れた相互参照を Wiki ページについて lint |
| `/rite:recover` | 中断した作業を再開 |
| `/rite:skill-suggest` | コンテキストを分析し適用可能なスキルを提案 |

## ワークフロー

```
/rite:issue-create → /rite:open (ブランチ → 計画 → 実装 → /rite:lint → draft PR)
                  → /rite:iterate (mergeable になるまで review ⇄ fix ループ)
                  → /rite:ready → /rite:merge → /rite:cleanup
```

**注意:** 一気通貫のフローは単一責務の 4 コマンドに分割されています。`/rite:open <issue>` はブランチ作成・実装・品質チェック・draft PR 作成を担当します。`/rite:iterate <pr>` は mergeable になるまで review と fix をループします。`/rite:ready <pr>` は PR を Ready for review に切り替えます。`/rite:merge <pr>` は squash merge を実行します。いずれかのステップが中断した場合（例: `Context limit reached`）、`/rite:recover` を実行して復旧します。

ステータス遷移:
```
Todo → In Progress → In Review → Done
 ↑         ↑            ↑         ↑
作成     作業開始     Ready 設定  マージ済
```

## 設定

プロジェクトのルートに `rite-config.yml` を作成します:

```yaml
schema_version: 2

project:
  type: webapp  # generic | webapp | library | cli | documentation

github:
  projects:
    enabled: true

branch:
  base: "main"       # フィーチャーブランチのベースブランチ（Git Flow なら "develop"）
  pattern: "{type}/issue-{number}-{slug}"

# 任意: Iteration（GitHub Projects Iteration フィールド）連携
iteration:
  enabled: false  # 有効にするには true
```

全オプションは [設定リファレンス](docs/CONFIGURATION.md) を参照してください。

## トラブルシューティング

| 問題 | 解決策 |
|------|--------|
| 長時間実行コマンド中の `Context limit reached` | `/clear` を実行してから `/rite:recover` で継続 |

## ドキュメント

- [完全な仕様](docs/SPEC.md)
- [設定リファレンス](docs/CONFIGURATION.md)

## 要件

必須:

- [GitHub CLI (gh)](https://cli.github.com/) - GitHub 操作（Issue / PR / Projects）に必須
- [jq](https://jqlang.github.io/jq/) - フックとスクリプトの JSON 解析に必須
- **bash 4+** - 必須。フックとスクリプトが連想配列（`declare -A`）や `mapfile` など bash 4 の機能に依存

推奨:

- **macOS**: [coreutils](https://formulae.brew.sh/formula/coreutils)（`brew install coreutils`）- Wiki の陳腐化検出は GNU の `date -d` を使うが、macOS 標準の BSD `date` にはこの機能がない。coreutils を入れ、その `gnubin` を `PATH` に追加して `date` を GNU 版に解決させるとこの検出が有効になる（未対応時はその検出のみスキップ）

## ライセンス

MIT License - 詳細は [LICENSE](LICENSE) を参照してください。

## コントリビューション

コントリビューションを歓迎します。ガイドラインは [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。

---

Made with 📜 rite
