---
type: "heuristics"
title: "複数の異種 signal を集約するロジックは表層パターンではなく共通の構造化された状態を判定基準にする"
domain: "heuristics"
promote: rite-plugin
description: "複数の異種 signal（各ステップが出す `[CONTEXT]` marker、チェックボックスの x/空欄、絵文字 prefix 付き付記文など）を集約する新規ロジックを書く際、一律の仮定（「marker が無ければ異常」）や表層的な文字列パターン一致（「絵文字 prefix で判定する」）を先に決めてしまうと、各 signal の実際の emit 条件を個別確認していないぶんだけ取りこぼしや誤検知を生む。"
created: "2026-07-23T06:38:31Z"
updated: "2026-07-23T06:38:31Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260723T062652Z-pr-1975.md"
  - type: "fixes"
    ref: "raw/fixes/20260723T055411Z-pr-1975.md"
  - type: "fixes"
    ref: "raw/fixes/20260723T061352Z-pr-1975.md"
tags: ["signal-aggregation", "false-positive", "false-negative", "design-heuristic", "code-review-convergence"]
confidence: high
---

# 複数の異種 signal を集約するロジックは表層パターンではなく共通の構造化された状態を判定基準にする

## 概要

複数の異種 signal（各ステップが出す `[CONTEXT]` marker、チェックボックスの x/空欄、絵文字 prefix 付き付記文など）を集約する新規ロジックを書く際、一律の仮定（「marker が無ければ異常」）や表層的な文字列パターン一致（「絵文字 prefix で判定する」）を先に決めてしまうと、各 signal の実際の emit 条件を個別確認していないぶんだけ取りこぼしや誤検知を生む。各ルールが共通して持つ、より根本的で構造化された状態（本件ではチェックボックス自体の x/空欄）を先に特定し、それを判定基準にする設計の方が堅牢。

## 詳細

### 発生背景

cleanup 完了報告に非ブロッキング失敗を集約 surface する機能を追加した review-fix ループで、「未完了事項」集約ロジックが 4 review cycle にわたって 3 世代の異なるバグを生んだ:

1. **cycle 1**: cross-Bash-tool-call 境界での値受け渡しにシェル変数を使い、既存の `{placeholder}` 規約を確認しなかった（[別ページ「SKILL.md 新規セクションでシェル変数を Bash 呼び出し間の値受け渡しに使うと dead code 化する」](../anti-patterns/skill-md-shell-var-cross-bash-call-dead-code.md) 参照）。
2. **cycle 2**: 複数 signal の「異常」を一律の仮定（`marker` 不在 = 異常）で判定しようとしたが、各 signal の実際の emit 条件（成功時に marker を出す設計か、失敗時のみ出す設計か）を個別確認しなかったため、成功時に marker を出さない設計のステップで常に誤検知（false positive）した。
3. **cycle 3**: 表層的な文字列パターン（絵文字 `⚠️` prefix）を判定基準に選んだが、既存の複数ルールがその慣習に一律で従っているとは限らなかった。実際、ブランチ削除失敗の付記文（`BRANCH_DELETE_FAILED` / `BRANCH_DELETE_UNMERGED`）は絵文字 prefix を持たない bare-text だったため、絵文字ベースの判定はこのケースを取りこぼした——これはまさに当該 Issue が守るべき「ブランチ削除失敗のような非ブロッキング失敗を見逃さない」というシナリオそのものであり、5 名中 5 名のレビュアーが独立に同一の HIGH バグとして検出した。

### 収束した根本原因と修正

いずれのバグも「既存の複数ルールを集約する新ロジックを書く前に、各ルールが共通して持つ構造化された signal を先に特定すべきだった」という同一の教訓に収束する。cycle 3 の根本修正では、判定基準を「絵文字 prefix の有無」から「チェックボックスが `x` ではなく空欄（未チェック）として描画されているか」に変更した。cleanup 完了報告の 6 個のチェック項目はすべて、成功時は `x`・非ブロッキング失敗時は空欄という共通のチェックボックス契約を既に持っていたため、この基準への変更は特別な除外ロジックを一切必要とせず、単純かつ構造的に正しい解決になった。

### 予防

複数の異種 signal を集約する新ロジックを設計する際は、以下の順序で検討する:

1. 各 signal の実際の emit 条件（成功時のみ / 失敗時のみ / 常に）を個別に確認する。一律の仮定を先に立てない。
2. 表層的な文字列パターン（絵文字・特定の語句）ではなく、各 signal が共通して持つ、より根本的で構造化された状態（enum 値、真偽値、チェックボックスの状態など）を探す。
3. 統一ルールを先に決めてから signal 側を後付けで確認するのではなく、signal 側の構造を先に洗い出してから統一ルールを設計する。この順序を逆にすると false positive / false negative を生みやすい。

## 関連ページ

- [SKILL.md 新規セクションでシェル変数を Bash 呼び出し間の値受け渡しに使うと dead code 化する](../anti-patterns/skill-md-shell-var-cross-bash-call-dead-code.md)

## ソース

- [PR #1975 review results (cycle 4, mergeable)](../../raw/reviews/20260723T062652Z-pr-1975.md)
- [PR #1975 fix results (cycle 3)](../../raw/fixes/20260723T055411Z-pr-1975.md)
- [PR #1975 fix results (cycle 4)](../../raw/fixes/20260723T061352Z-pr-1975.md)
