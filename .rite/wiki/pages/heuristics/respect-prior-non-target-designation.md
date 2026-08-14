---
type: "heuristics"
title: "先行 Issue の明示的 Non-Target 指定は、reviewer 推奨だけで覆さずユーザー確認する"
domain: "heuristics"
promote: rite-plugin
description: "同種のクリーンアップ系列（例: 用語統一・裸ファイル名参照の一掃）で複数レビュアーが独立に同一箇所を「本 PR で対応すべき」と推奨しても、その箇所が先行 Issue/PR で明示的に Non-Target（対象外）と宣言されていた場合は、reviewer 推奨をそのまま実行せず、先行判断の経緯を提示したうえでユーザーに再確認する。"
created: "2026-07-08T03:06:55+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260707T175542Z-pr-1794.md"
tags: ["non-target", "scope-boundary", "reviewer-recommendation", "precedent", "askuserquestion"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-08T03:06:55+09:00" }
---

# 先行 Issue の明示的 Non-Target 指定は、reviewer 推奨だけで覆さずユーザー確認する

## 概要

同種のクリーンアップ系列（例: 用語統一・裸ファイル名参照の一掃）で複数レビュアーが独立に同一箇所を「本 PR で対応すべき」と推奨しても、その箇所が先行 Issue/PR で明示的に Non-Target（対象外）と宣言されていた場合は、reviewer 推奨をそのまま実行せず、先行判断の経緯を提示したうえでユーザーに再確認する。

## 詳細

`comment-best-practices.md` の裸ファイル名 `resume.md` 参照を `recover.md` へ統一する 1 行修正のレビューで、prompt-engineer と code-quality の 2 名が独立に `plugins/rite/hooks/flow-state.sh:24` の同種の裸ファイル名参照を検出し、うち code-quality は `分類: actionable` として別 Issue 化を推奨した。

ユーザーへの初回確認では「本 PR で対応」を選択したが、実装に進む前に `git log` で経緯を遡ったところ、以下の先行判断が見つかった:

- 元の resume→recover リネーム Issue（#1784）の「4.2 Non-Target Files」に `plugins/rite/hooks/flow-state.sh: phase enum に resume は含まれず変更不要` と明記されていた。
- 同種の裸ファイル名参照クリーンアップを行った先行 PR のコミットメッセージにも「flow-state.sh（先行 Issue で明示的 non-target）...は意図的に対象外のまま維持する」と明記され、当該ファイルは同種作業でも一貫して除外されてきた。

この矛盾（reviewer 推奨 vs 文書化された先行除外判断）をユーザーに提示し直したところ、ユーザーは「本 PR では修正せず別途確認」に判断を覆した。もし先行判断を確認せずに reviewer 推奨をそのまま実行していれば、複数の先行 Issue が意図的に維持してきた除外境界を無自覚に破ることになっていた。

**判定手順**:

1. reviewer が「別 Issue 化 / 本 PR で対応」を推奨した箇所について、対象ファイル・行に対する `git log` / 関連 Issue 本文を確認し、過去に明示的な Non-Target 宣言（Issue の Scope 節、コミットメッセージの除外理由等）がないか調べる。
2. 該当する先行宣言が見つかった場合、reviewer 推奨と先行宣言の矛盾を明示してユーザーに再確認する（先行判断の出典を具体的に引用する）。
3. reviewer の「同種パターンだから直すべき」という判断は、対象が本当に **無条件に同種** か（先行 Issue が対象を限定した理由が今も有効か）を機械的に確認できないため、reviewer 自身の判断に留めずユーザー判断に委ねる。

**なぜ reviewer が見落とすか**: reviewer は当該 PR の diff とファイル内容から判断するため、「このファイルはかつて別 Issue で意図的に除外された」という履歴的コンテキストは通常の Grep/Read では見えない。`git log --all --grep` や関連 Issue 本文の遡及確認は、reviewer の標準的な Detection Process には含まれていない。

## 関連ページ

- [stale 参照一掃の『残照ゼロ』AC は意図的維持カテゴリの線引きで判定する](./stale-sweep-intentional-retention-boundary.md)
- [ポリシー分類ドキュメント改訂では、意図的に対象外とした既存要素が新記述と矛盾しないか確認する](./policy-doc-revision-non-target-consistency-check.md)

## ソース

- [PR #1794 review results（0 findings / マージ可、推奨事項として flow-state.sh:24 を検出。先行 Issue #1784 / PR #1790 の Non-Target 宣言確認によりユーザーがスコープ拡大を見送った）](../../raw/reviews/20260707T175542Z-pr-1794.md)
