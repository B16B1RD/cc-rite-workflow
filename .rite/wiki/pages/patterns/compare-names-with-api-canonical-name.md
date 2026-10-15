---
# Domain knowledge only; rite workflow candidates stay in raw.
type: "patterns"
title: "API が返す名前と照合するときは、URL から作った文字列ではなく API の正式名と比べる"
domain: "patterns"
description: "remote URL から作った owner/repo は大文字小文字や改名前の名前を含みうるので、API の返す full_name と文字列で比べると一致すべき行を黙って落とす。比べる両側を同じ API から取った正式名にそろえる。"
created: "2026-10-15T02:42:28Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-15T02:42:28Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261014T234324Z-pr-3903.md"
  - type: "fixes"
    resource: "raw/fixes/20261014T235100Z-pr-3903.md"
tags: ["github-api", "gh", "identity", "silent-failure"]
confidence: high
---

# API が返す名前と照合するときは、URL から作った文字列ではなく API の正式名と比べる

## 概要

remote URL から作った owner/repo は大文字小文字や改名前の名前を含みうるので、API の返す full_name と文字列で比べると一致すべき行を黙って落とす。比べる両側を同じ API から取った正式名にそろえる。

## 詳細

GitHub の API は、リポジトリを正式な表記（現在の名前と、作成時の大文字小文字）で返す。一方、ローカルの remote URL はクローン時の表記のままで、小文字で書かれていたり、改名前の名前を指していたりする。API はどちらの表記でもリダイレクトして応答するため、取得は成功する。ところが返ってきた `repository.full_name` を URL 由来の文字列と比べると一致せず、絞り込みが全件を落とす。落とした結果は「該当なし」と区別がつかず、エラーにもならない。

- 比べる側も `gh api repos/{owner}/{repo} --jq .full_name` で正式名を取り、正式名どうしで比べる。
- 正式名の取得に失敗したら、「該当なし」ではなく判定できないこととして扱う。
- テストでは remote を小文字で書いた fixture を使い、表記が違っても一致することを確かめる。

## 関連ページ

- [テスト用の偽コマンドは本番が渡す絞り込み引数を照合して適用する](./fake-command-applies-production-filters.md)

## ソース

- [表記の違いで親を黙って落としたレビュー結果](../../raw/reviews/20261014T234324Z-pr-3903.md)
- [正式名どうしで比べるようにした修正結果](../../raw/fixes/20261014T235100Z-pr-3903.md)
