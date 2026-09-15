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
  - type: "reviews"
    resource: "raw/reviews/20260915T042231Z-pr-2833.md"
tags: ["non-target", "scope-boundary", "reviewer-recommendation", "precedent", "askuserquestion"]
confidence: medium
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-15T04:40:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-15T04:40:00Z" }
---

# 先行 Issue の明示的 Non-Target 指定は、reviewer 推奨だけで覆さずユーザー確認する

## 概要

同種のクリーンアップ系列（例: 用語統一・裸ファイル名参照の一掃）で複数レビュアーが独立に同一箇所を「本 PR で対応すべき」と推奨しても、その箇所が先行 Issue/PR で明示的に Non-Target（対象外）と宣言されていた場合は、reviewer 推奨をそのまま実行せず、先行判断の経緯を提示したうえでユーザーに再確認する。

## 詳細

`comment-best-practices.md` の裸ファイル名 `resume.md` 参照を `recover.md` へ統一する 1 行修正のレビューで、prompt-engineer と code-quality の 2 名が独立に `plugins/rite/hooks/flow-state.sh:24` の同種の裸ファイル名参照を検出し、うち code-quality は `分類: actionable` として別 Issue 化を推奨した。

ユーザーへの初回確認では「本 PR で対応」を選択したが、実装に進む前に `git log` で経緯を遡ったところ、以下の先行判断が見つかった:

- 元の resume→recover リネーム Issue の「4.2 Non-Target Files」に `plugins/rite/hooks/flow-state.sh: phase enum に resume は含まれず変更不要` と明記されていた。
- 同種の裸ファイル名参照クリーンアップを行った先行 PR のコミットメッセージにも「flow-state.sh（先行 Issue で明示的 non-target）...は意図的に対象外のまま維持する」と明記され、当該ファイルは同種作業でも一貫して除外されてきた。

この矛盾（reviewer 推奨 vs 文書化された先行除外判断）をユーザーに提示し直したところ、ユーザーは「本 PR では修正せず別途確認」に判断を覆した。もし先行判断を確認せずに reviewer 推奨をそのまま実行していれば、複数の先行 Issue が意図的に維持してきた除外境界を無自覚に破ることになっていた。

**判定手順**:

1. reviewer が「別 Issue 化 / 本 PR で対応」を推奨した箇所について、対象ファイル・行に対する `git log` / 関連 Issue 本文を確認し、過去に明示的な Non-Target 宣言（Issue の Scope 節、コミットメッセージの除外理由等）がないか調べる。
2. 該当する先行宣言が見つかった場合、reviewer 推奨と先行宣言の矛盾を明示してユーザーに再確認する（先行判断の出典を具体的に引用する）。
3. reviewer の「同種パターンだから直すべき」という判断は、対象が本当に **無条件に同種** か（先行 Issue が対象を限定した理由が今も有効か）を機械的に確認できないため、reviewer 自身の判断に留めずユーザー判断に委ねる。

**なぜ reviewer が見落とすか**: reviewer は当該 PR の diff とファイル内容から判断するため、「このファイルはかつて別 Issue で意図的に除外された」という履歴的コンテキストは通常の Grep/Read では見えない。`git log --all --grep` や関連 Issue 本文の遡及確認は、reviewer の標準的な Detection Process には含まれていない。

**Non-Target が同じ Issue の契約に書かれている場合（出力契約の拡張と消費側手順書の同期衝突）**: helper の出力契約（新しい失敗 reason・成功 marker の末尾 suffix）を足す Issue が、その marker を読む消費側の手順書を自身の Non-Target に指定していることがある。このとき reviewer 3 名が独立に「消費側手順書の reason 列挙・marker 形・除外判別子の説明が古い」と推奨しても、同じ PR で直すと Issue 契約違反になる。自律実行（ユーザーに問わない batch）ではユーザー再確認の代わりに、次の 2 点を満たして境界を保つ:

1. **routing が壊れていないことを先に確かめる**: 消費側が新しい reason を catch-all 行（「上記以外 → 停止」）で、suffix 付き marker を前方一致で拾えるなら、古いのは列挙の文言だけで挙動は保たれている。挙動まで壊れているなら Non-Target でも同 PR で扱う理由になるので、ここで区別する。
2. **同期を追跡可能な別 Issue に切り出し、PR 本文と Decision Log に Non-Target 維持の理由を残す**: 「列挙が古い」指摘は複数 reviewer から重複して出るため、切り出し先を 1 件に集約して後続レビューでの再訴訟を防ぐ。

先行 Issue の Non-Target と違い、同一 Issue の Non-Target は reviewer から契約本文で直接見えるため、reviewer 自身も「本 PR では直せない」と申し送る傾向がある。reviewer が boundary 分類で申し送ったなら、それをそのまま切り出しの根拠に使える。

## 関連ページ

- [stale 参照一掃の『残照ゼロ』AC は意図的維持カテゴリの線引きで判定する](./stale-sweep-intentional-retention-boundary.md)
- [ポリシー分類ドキュメント改訂では、意図的に対象外とした既存要素が新記述と矛盾しないか確認する](./policy-doc-revision-non-target-consistency-check.md)

## ソース

- [0 findings / マージ可、推奨事項として flow-state.sh:24 を検出。先行 Issue / PR の Non-Target 宣言確認によりユーザーがスコープ拡大を見送った](../../raw/reviews/20260707T175542Z-pr-1794.md)
- [帰結クラス降格 helper に除外入力源を足したレビュー結果。Non-Target の消費側手順書の同期漏れを 3 名が独立に指摘し別 Issue へ切り出した](../../raw/reviews/20260915T042231Z-pr-2833.md)
