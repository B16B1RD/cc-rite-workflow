# Contextual Commits Reference

Based on [Contextual Commits](https://github.com/berserkdisruptors/contextual-commits) (MIT License).

Conventional Commits の subject line を維持したまま、コミット body に構造化されたアクションラインを埋め込み、意思決定の永続記録を git 履歴に残す。

## Configuration

`rite-config.yml` の `commit.contextual` で有効/無効を切り替える:

```yaml
commit:
  contextual: true    # true (default) | false
```

`false` の場合、既存の自由記述 body フォーマットを維持する。

## Action Line Format

```
{action-type}({scope}): {description}
```

- **action-type**: 英語固定（以下5種のいずれか）
- **scope**: 小文字英数字とハイフン。プロジェクト内で一貫した語彙を使う
- **description**: `rite-config.yml` の `language` 設定に従う（`ja`: 日本語、`en`: 英語、`auto`: ユーザー入力言語に合わせる）

## Action Types

| Type | Captures | When to Use |
|------|----------|-------------|
| `intent(scope)` | ユーザーの意図・目的 | 動機が subject line から明らかでない場合。大半の feature/refactor で使用 |
| `decision(scope)` | 選択した手法と理由 | 代替案が存在し、選択理由がある場合 |
| `rejected(scope)` | 却下した代替案と理由 | 代替案を検討して却下した場合。**必ず理由を含める** |
| `constraint(scope)` | 実装を制約した条件 | 非自明な制限が実装に影響した場合 |
| `learned(scope)` | 実装中に発見した知見 | API の癖、ドキュメントにない挙動、パフォーマンス特性など |

## Examples

### language: ja

```
feat(auth): Google OAuth プロバイダーを実装

intent(auth): ソーシャルログイン対応、まず Google から
decision(oauth): passport.js を選択（マルチプロバイダー対応の柔軟性）
rejected(oauth): auth0-sdk — セッションモデルが redis store と非互換
constraint(callback): /api/auth/callback/:provider パターンに従う必要あり
learned(passport-google): refresh token には明示的な offline_access scope が必要
```

### language: en

```
feat(auth): implement Google OAuth provider

intent(auth): social login starting with Google, then GitHub and Apple
decision(oauth): passport.js over auth0-sdk for multi-provider flexibility
rejected(oauth): auth0-sdk — locks into their session model, incompatible with redis store
constraint(callback): must follow /api/auth/callback/:provider pattern
learned(passport-google): requires explicit offline_access scope for refresh tokens
```

### Trivial commit (no action lines needed)

```
fix(typo): correct variable name in auth handler
```

## Generation Source Priority

アクションラインの生成元と優先度:

| Priority | Source | Reliability | Usage |
|----------|--------|-------------|-------|
| 1 | **作業メモリ** (SoT) | 高 | `決定事項・メモ`、`計画逸脱ログ`、`要確認事項` から抽出 |
| 2 | **Issue 本文** | 高 | 仕様詳細、技術的決定事項、受入条件から intent/constraint を抽出 |
| 3 | **diff** | 中 | 明確な技術選択が見える場合のみ `decision` を推論 |
| 4 | **会話コンテキスト** (補助) | 低 | 上記で不足する場合のみ、実装中の発見を `learned` として追加 |

**重要**: 会話コンテキストは `/clear` 後に消失するため、再現性が低い。作業メモリと Issue 本文を主な生成元とする。

## Work Memory → Action Line Mapping

| Work Memory Section | → Action Type | Mapping Rule |
|---------------------|---------------|--------------|
| Issue title/description | `intent(scope)` | Issue の目的・動機を反映 |
| `決定事項・メモ` の判断記録 | `decision(scope)` | 選択した手法と理由 |
| `決定事項・メモ` の却下記録 | `rejected(scope)` | 検討して却下した代替案（理由必須） |
| `計画逸脱ログ` の「変更」行 | `decision(scope)` | 計画から変更した理由 |
| `計画逸脱ログ` の「スキップ」行 | `rejected(scope)` | 不要と判断した理由 |
| `要確認事項` の解決済み項目 `[x]` | `constraint(scope)` / `learned(scope)` | 確認の結果判明した制約や知見 |
| diff から明確な技術選択が見える | `decision(scope)` | 新依存追加、ライブラリ切替など |

## Review-Fix Commit Mapping (pr/fix.md)

レビュー修正コミットでは、以下の追加マッピングを使用:

| Source | → Action Type |
|--------|---------------|
| レビュー指摘の対応方針 | `decision(scope)` |
| 対応しなかった指摘とその理由 | `rejected(scope)` |
| 対応中に発見した制約 | `constraint(scope)` |
| 対応中の発見事項 | `learned(scope)` |

## Scope Derivation Rules

| Priority | Source | Example |
|----------|--------|---------|
| 1 | コミットの subject line scope | `feat(auth)` → scope = `auth` |
| 2 | アクションが関わるサブコンポーネント | `decision(oauth-library)` |
| 3 | Issue の主要スコープ | Issue title に含まれるドメイン |

scope はプロジェクト内で一貫させる。`auth` を使ったら次のコミットで `authentication` にしない。

## Output Rules

### Minimum Output

- **Trivial な変更**（typo fix、依存バンプ、フォーマット）: アクションライン不要
- **Non-trivial な変更**: 最低1つの `intent` を含める

### Maximum Output

- **10行上限**（ガードレール）
- 超過時の切り捨て優先度（先に切り捨てるものから順）:
  1. `learned` — 知見は有用だが最も補助的
  2. `constraint` — 制約は diff から推測可能な場合がある
  3. `rejected` — 却下理由は高価値だが intent/decision より後
  4. `decision` — 選択は diff から部分的に推測可能
  5. `intent` — **最優先保持**（「なぜ」の核）

### Signal Quality Rule

- diff が示す情報を繰り返さない
- エビデンスのない fabrication は禁止（特に `intent`、`rejected`、`constraint`、`learned`）
- 会話コンテキストがない場合、diff から推論可能な `decision` のみ許可

## Queryability

アクションラインは `git log --grep` で検索可能:

```bash
# auth に関する全 rejected を検索
git log --all --grep="rejected(auth" --format="%s%n%b" | grep "^rejected(auth"

# 特定 scope の全アクションラインを検索
git log --all --grep="(oauth" --format="%s%n%b" | grep -E "^(intent|decision|rejected|constraint|learned)\(oauth"
```

`/rite:issue:recall` コマンドがこの検索を構造化して提供する。
