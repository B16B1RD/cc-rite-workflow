# Investigation Protocol

コード調査時の品質を保証するためのプロトコル。rite workflow の全フェーズ（実装計画、実装、レビュー等）でコード調査が必要な際に参照する。

> **スキル版**: ユーザーが `/rite:investigate` を実行した場合は、[commands/investigate.md](../commands/investigate.md) の完全なフローが実行される。本ドキュメントは、他のフェーズ内でコード調査を行う際の簡潔なガイドラインである。

## 3段階検証プロセス

コード構造を調査するときは、以下の3段階を必ず守る:

### 1. 検索（Grep）— 場所の特定のみ（[commands/investigate.md Phase 2](../commands/investigate.md#phase-2-検索grep) に相当）

- Grep ツールで対象パターンを検索し、ファイルと行番号を特定する
- **この段階では値を読み取らない** — 場所の特定のみ
- 複数行にまたがる構造には2段階検索を使う（詳細は [commands/investigate.md Phase 2](../commands/investigate.md#2段階検索複数行にまたがる構造対策) を参照）

### 2. 検証（Read）— 実際の確認（[commands/investigate.md Phase 3](../commands/investigate.md#phase-3-検証read) に相当）

- Grep で特定した**各箇所**を Read ツールで実際に確認する
- **必須ルール**:
  - 構造の開始から終了まで読む（最低でも前後5行。構造が超える場合は終了まで）
  - 推測で値を補完しない（未確認なら「未確認」と報告）
  - 変数は定義元を追跡する
  - 大きなファイルは offset/limit で分割読み
- **完全性チェック**: grep ヒット数 = Read 検証数であることを確認。不一致なら追加 Read

### 3. クロスチェック — 信頼性の担保（[commands/investigate.md Phase 6](../commands/investigate.md#phase-6-クロスチェック) に相当）

`rite-config.yml` の `investigate.codex_review.enabled` に基づき:

| 設定 | 動作 |
|------|------|
| `enabled: true` + Codex MCP 接続 | Codex にクロスチェックを依頼 |
| `enabled: true` + Codex MCP 未接続 | 代替検証にフォールバック |
| `enabled: false` | 代替検証を実施 |
| `codex_review.enabled` 未設定 | デフォルト `true` として動作 |
| `investigate` セクション自体が未設定 | デフォルト `true` として動作 |

**代替検証**（Codex 不使用時）: 詳細は [commands/investigate.md Phase 6b](../commands/investigate.md#phase-6b-代替検証enabled-false-または-codex-mcp-未接続時) を参照。

## 他フェーズでの簡易適用ガイド

フルの `/rite:investigate` フローを実行するほどではないが、コード調査の品質を確保したい場合:

### 最低限守るべきルール

1. **grep だけで値を確定しない** — 必ず Read で該当行を確認する
2. **複数行構造を1行で判断しない** — 最低でも前後5行を含めて読む
3. **全件処理を保証する** — grep ヒット数と Read 検証数を照合する
4. **推測を事実と混同しない** — Read で確認できない値は「未確認」と明記する

### 適用場面

| フェーズ | 典型的な調査 | 推奨レベル |
|---------|-------------|-----------|
| 実装計画（Phase 3） | 変更対象ファイルの特定、既存実装の確認 | 簡易（ルール1-2） |
| 実装（Phase 5.1） | 参考実装の確認、影響範囲の調査 | 簡易（ルール1-3） |
| レビュー（Phase 5.4） | 指摘事項の検証、コード品質の確認 | フル（ルール1-4） |
| PR 修正（Phase 5.4.4） | 修正箇所の影響調査 | 簡易（ルール1-2） |

## 出力フォーマット

調査結果は以下のテーブル形式で記録する:

```markdown
| # | {観点1} | {観点2} | 検証ソース |
|---|---------|---------|-----------|
| 1 | `値1` | `値2` | ファイル名:行番号 |
```

「検証ソース」列は Read で確認したファイルと行番号。この列があることで、後続の検証や手動確認が可能になる。
