# Contextual Commits を rite workflow に統合

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

[Contextual Commits](https://github.com/berserkdisruptors/contextual-commits) の5種のアクションライン（intent/decision/rejected/constraint/learned）をコミット body に構造化埋め込みし、git 履歴自体を意思決定の永続記録にする。加えて `/rite:issue:recall` コマンドで過去の決定事項を検索可能にする。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

rite workflow は Conventional Commits でコミットメッセージを生成しているが、body は自由記述で構造化されていない。セッション中の意思決定（作業メモリの `決定事項・メモ`、`計画逸脱ログ`）は Issue 終了後に参照されなくなり、過去の判断理由が失われる。

AIコーディングセッションは3つのアウトプットを生む:
1. **コード変更** — git に保存される
2. **意思決定** — セッション終了で消失
3. **理解・知見** — セッション終了で消失

セッション価値の2/3が失われる問題を、コミットメッセージという既存インフラだけで解決する。

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

1. **コミット body へのアクションライン自動生成**: `implement.md` と `pr/fix.md` のコミット生成時に、作業メモリ・Issue本文・diff から構造化アクションラインを生成
2. **`/rite:issue:recall` コマンド**: コンテキストコミット履歴から決定事項を検索
   - 引数なし: 現在ブランチの全アクションライン要約
   - scope 指定: 全履歴から scope でフィルタ（prefix マッチ）
   - action(scope) 指定: 全履歴から action+scope でフィルタ
3. **設定によるオプトアウト**: `commit.contextual: false` で従来の自由記述 body に戻せる
4. **team-execute 対応**: 並列実行時のコミットにもアクションラインを生成

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

1. **Conventional Commits 互換性**: subject line は変更なし。commitlint / semantic-release が正常動作すること
2. **コミットボディの肥大化防止**: アクションライン最大10行
3. **再現性**: 生成ソースは作業メモリ(SoT) > Issue本文 > diff > 会話コンテキスト(補助)の優先度
4. **i18n 対応**: アクションタイプは英語固定、description は language 設定に従う

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

| 論点 | 決定 | 理由 |
|------|------|------|
| アクションタイプの言語 | 英語固定（description は language 設定に従う） | type/scope と同じ扱い |
| デフォルト値 | `commit.contextual: true` | 追加コストなし、価値は常にある |
| 切り捨て優先度 | intent を最優先保持。超過時は learned → constraint → rejected → decision → intent の順で切り捨て | intent は「なぜ」の核であり最も重要 |
| 生成ソース | 作業メモリ + diff + Issue本文（会話コンテキストは補助） | /clear 後の再現性を確保 |
| コミット対象コマンド | `implement.md` + `pr/fix.md` | review-fix は判断が濃くアクションラインの価値が高い |
| recall の位置づけ | 独立コマンド（resume 統合は将来 Phase 2） | まず独立運用で利用パターンを見る |

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

| コンポーネント | 役割 | ファイル |
|---------------|------|---------|
| **設定** | `commit.contextual` フラグ管理 | `rite-config.yml`, `templates/config/rite-config.yml` |
| **リファレンス** | アクションライン仕様・マッピングテーブル定義 | `references/contextual-commits.md` (新規) |
| **コミット生成（実装）** | implement フローのコミット body 拡張 | `commands/issue/implement.md` |
| **コミット生成（修正）** | review-fix フローのコミット body 拡張 | `commands/pr/fix.md` |
| **recall コマンド** | git 履歴からアクションライン検索 | `commands/issue/recall.md` (新規) |
| **スキルルーティング** | recall のキーワード検出・ルーティング | `skills/rite-workflow/SKILL.md` |
| **並列実行対応** | team-execute のコミットテンプレート拡張 | `commands/sprint/team-execute.md` |
| **i18n** | recall コマンド用メッセージ | `i18n/{ja,en}/issue.yml` |

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

```
コミット生成時:
  作業メモリ (決定事項・メモ, 計画逸脱ログ, 要確認事項)
  + Issue 本文 (仕様詳細, 技術的決定事項)
  + diff (明確な技術選択)
  + 会話コンテキスト (補助: 実装中の発見)
    ↓ マッピングテーブル
  アクションライン生成 (intent/decision/rejected/constraint/learned)
    ↓ 10行上限フィルタリング
  コミット body に埋め込み

recall 検索時:
  git log → アクションライン抽出 → scope/type 別グループ化 → 表示
```

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

| ファイル | 変更種別 | 変更内容 |
|---------|---------|---------|
| `rite-config.yml` | 修正 | `commit.contextual: true` 追加 |
| `plugins/rite/templates/config/rite-config.yml` | 修正 | `commit.contextual: true` 追加 |
| `plugins/rite/skills/rite-workflow/references/contextual-commits.md` | 新規 | リファレンスドキュメント |
| `plugins/rite/commands/issue/implement.md` | 修正 | Phase 5.1.1 コミット body 生成拡張 |
| `plugins/rite/commands/pr/fix.md` | 修正 | コミット body 生成拡張 |
| `plugins/rite/commands/issue/recall.md` | 新規 | recall コマンド |
| `plugins/rite/skills/rite-workflow/SKILL.md` | 修正 | ルーティング追加 |
| `plugins/rite/commands/sprint/team-execute.md` | 修正 | コミットテンプレート拡張 |
| `plugins/rite/i18n/ja/issue.yml` | 修正 | メッセージキー追加 |
| `plugins/rite/i18n/en/issue.yml` | 修正 | メッセージキー追加 |

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

1. **作業メモリの `決定事項・メモ` がフリーフォーマット**: Claude がコミット時に自然言語メモからアクションタイプを推論する必要がある
2. **recall の git log パース性能**: 大規模リポジトリでは `git log --all` が遅くなる可能性。`--since` や `--max-count` で制限
3. **既存コミットとの後方互換性**: contextual 設定を有効にする前のコミットにはアクションラインがない。recall は「ない場合は無視」の設計
4. **ライセンス**: contextual-commits は MIT License。独自リファレンスドキュメントを書くため問題なし。帰属表示 `Based on Contextual Commits (MIT License)` を記載

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

1. **`resume.md` へのコンテキストコミット復元統合** — Phase 2 として将来対応。まず recall を独立運用
2. **lint でのコンテキストコミット形式検証** — Claude が生成するためタイポリスクが低い
3. **`commit.contextual_types` による選択的タイプフィルタ** — 初期実装では全5タイプ生成
4. **commitlint プラグイン** — 既存ツールチェーンへの影響がないため不要
