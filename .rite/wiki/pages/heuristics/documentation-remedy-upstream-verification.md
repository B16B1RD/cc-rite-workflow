---
type: "heuristics"
title: "ドキュメントが提示する解決策は上流ソース（公式ドキュメント・issue tracker）で機能を裏取りする"
domain: "heuristics"
description: "ドキュメントのみの変更（コード変更を伴わない reference / skill 定義の修正）であっても、記載する設定・コマンド・回避策が実際に機能するかどうかは、公式ドキュメントだけでなく外部ツールの issue tracker で裏取りする必要がある。"
created: "2026-07-20T18:16:28+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260720T154907Z-pr-1933.md"
  - type: "reviews"
    resource: "raw/reviews/20260720T163001Z-pr-1933-cycle2.md"
  - type: "reviews"
    resource: "raw/reviews/20260720T170155Z-pr-1933-cycle3-final.md"
  - type: "fixes"
    resource: "raw/fixes/20260720T155318Z-pr-1933.md"
  - type: "fixes"
    resource: "raw/fixes/20260720T163246Z-pr-1933-cycle2.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-20T18:16:28+00:00" }
---

# ドキュメントが提示する解決策は上流ソース（公式ドキュメント・issue tracker）で機能を裏取りする

## 概要

ドキュメントのみの変更（コード変更を伴わない reference / skill 定義の修正）であっても、記載する設定・コマンド・回避策が実際に機能するかどうかは、公式ドキュメントだけでなく外部ツールの issue tracker で裏取りする必要がある。「公式にサポートされた設定」という記述は、その設定が *存在する* ことの根拠にはなるが、*意図した問題を解決できる* ことの根拠にはならない。

## 詳細

起点事例（`references/git-worktree-patterns.md` の sandbox SSH host alias ブロックに関する原因記述修正）では、3 回の review-fix cycle でこのギャップが段階的に露見した:

1. **cycle 1**: 著者は「`sandbox.excludedCommands` は公式サポートされた設定であり、指定コマンドを sandbox 外の通常 permission フローに乗せる」という公式ドキュメントの一般的な記述から、この設定が SSH 経由の git push/fetch ブロック問題も解消すると類推し、「恒久策」として提示した。prompt-engineer reviewer が上流の Claude Code issue（#30619, #29274, #53012、いずれも `not planned` でクローズ、2026-04 時点でも未修正）を WebFetch で直接検証した結果、Linux/WSL2 環境では `excludedCommands` は **ファイルシステムの sandbox のみバイパスし、ネットワークの sandbox はグローバルに適用され続ける** ことが判明した。SSH（port 22）はブロックされたままで、この「恒久策」は実際には機能しない。
2. 修正の結果、実際に機能する `dangerouslyDisableSandbox` を主回避策に戻し、`excludedCommands` は「一見恒久策に見えるが機能しない設定」として上流 issue 参照付きで位置づけ直した。
3. **cycle 2**: 修正時に見出しラベルへ限定情報（「Linux/WSL2 では現状機能しない」）を詰め込んだ結果、同ファイル内の既存ラベル命名規約（短い名詞句）から逸脱するという副作用が生じた。緊急性の高い技術的正確性の修正を優先するあまり、周辺のスタイル一貫性が後回しになった。

この事例が示す教訓は 2 点:

- **外部ツールの挙動に関する記述は、その公式ドキュメントの一般論だけでなく、実際の issue tracker（bug report / not-planned の既知の制約）まで確認する。** 「公式にドキュメント化された設定」であっても、プラットフォーム固有の未修正の制約（今回は Linux/WSL2 でのネットワークサンドボックス回避不可）により、期待した効果を持たない場合がある。
- **修正を急ぐあまり、周辺の構造的規約（見出しラベルの命名パターン等）を壊さないよう、修正内容を「本文」と「見出し」に適切に配分する。** 限定条件・例外事項は本文で説明し、見出しラベルは既存の命名慣習（短い名詞句等）を維持する。

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](../heuristics/docs-review-implementation-grep-verification.md)
- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](../heuristics/prose-cited-implementation-behavioral-verification.md)

## ソース

- [PR #1933 review results](../../raw/reviews/20260720T154907Z-pr-1933.md)
- [PR #1933 review results (cycle 2)](../../raw/reviews/20260720T163001Z-pr-1933-cycle2.md)
- [PR #1933 review results (cycle 3, mergeable)](../../raw/reviews/20260720T170155Z-pr-1933-cycle3-final.md)
- [PR #1933 fix results](../../raw/fixes/20260720T155318Z-pr-1933.md)
- [PR #1933 fix results (cycle 2)](../../raw/fixes/20260720T163246Z-pr-1933-cycle2.md)
