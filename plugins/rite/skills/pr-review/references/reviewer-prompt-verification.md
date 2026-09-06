# Reviewer 指示テンプレート（Verification モード）

`/rite:pr-review` ステップ 4.5.1 で `review_mode == "verification"` のとき、通常テンプレート（[reviewer-prompt-generator.md](./reviewer-prompt-generator.md)）に**加えて**使用する検証レビュー指示のテンプレート。検証結果とフルレビュー結果は最終 assessment で統合される。SKILL.md 側の「Placeholder embedding method」表に従い `{placeholder}` を埋めて使用する。

```
PR #{number}: {title} の検証レビューを {reviewer_type} として実行してください。

## 変更概要
{change_intelligence_summary}

## Review Mode: Verification

前回の指摘が正しく修正されたかの検証と、修正箇所のリグレッションチェックに集中してください。なお、この検証レビューに加えて、フルレビューも別途実施されます。

### Part 1: 前回指摘の修正検証

前回のレビューで以下の指摘がありました。各指摘が正しく修正されたか検証してください:

{previous_findings_table}

対応表:
{fix_change_map}

各指摘について以下のいずれかで判定:
- **FIXED**: 推奨対応（または同等の修正）が正しく適用された
- **NOT_FIXED**: 指摘が対応されていない、または修正が不正確
- **PARTIAL**: 一部対応済み、残りの問題を具体的に記載

### Part 2: リグレッションチェック（修正差分のみ）

前回レビュー以降に変更されたファイルの差分（incremental diff）:
{incremental_diff}

これらの変更されたファイルのみを対象に、以下をチェック:
1. Fix による明らかなリグレッション（既存機能の破壊、新たなバグの導入）
2. 新たな CRITICAL/HIGH のセキュリティ脆弱性

**重要（Part 2 スコープのみに適用）**: 前回の Fix サイクルで変更されていないコードに対して新規の MEDIUM/LOW-MEDIUM/LOW 指摘を生成しないこと。未変更コードの CRITICAL/HIGH 指摘のみ「見落とし」として報告可。この制約は Part 2（リグレッションチェック）にのみ適用されます。フルレビュー（ステップ 4.5 の通常テンプレート）では、すべてのコードを対象にレビューを行ってください。

## 共通レビュー原則
<!-- `_reviewer-base.md` から抽出される全 reviewer 共通の原則。READ-ONLY Enforcement / Mindset / Cross-File Impact Check / Confidence Scoring が含まれる。reviewer 固有の identity は named subagent の system prompt (agents/{reviewer_type}-reviewer.md) として自動注入される -->
{shared_reviewer_principles}

## 出力フォーマット
以下の形式で評価を出力してください:

### 評価: [可 / 条件付き / 要修正]

### 修正検証結果

| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |
|---|--------|------------|------|------|------|
| {n} | {severity} | {file:line} | {description} | FIXED / NOT_FIXED / PARTIAL | {notes} |

### リグレッション（修正差分で検出された問題）

| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| {severity} | {scope} | {file:line} | {description} | {recommendation} |

### 未変更コードの重大指摘（該当がある場合のみ）
<!-- CRITICAL/HIGH のみ。MEDIUM/LOW-MEDIUM/LOW は記載しない -->

| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| {severity} | {scope} | {file:line} | {description} | {recommendation} |

## 制約
[READ-ONLY RULE] このレビューは読み取り専用。`Edit`/`Write` 禁止、問題は指摘事項として報告し修正は `/rite:fix` に委譲する。許可/禁止コマンドの完全一覧は上記「共通レビュー原則」に注入済みの `_reviewer-base.md` `## READ-ONLY Enforcement` を SoT として参照。
```
