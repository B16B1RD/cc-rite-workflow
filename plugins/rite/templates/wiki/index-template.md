---
okf_version: "0.2"
description: "rite Experience Wiki — プロジェクト固有の経験則 bundle（OKF v0.2 準拠）"
---

# Wiki Index

このファイルは Wiki 全ページのカタログです。Ingest サイクルごとに `## ページ一覧` の 5 列テーブルが自動更新されます。

bundle-root の frontmatter で OKF（Open Knowledge Format）v0.2 への準拠を `okf_version: "0.2"` として宣言します（ただし**ページカタログの形式は OKF の箇条書き `* [title](path) - desc` から意図的に逸脱**し、下記の 5 列テーブルを使います。v0.2 §8 は v0.1 から不変）。各ページは `## ページ一覧` テーブルの 1 行として登録されます（列順: ページ / ドメイン / サマリー / 更新日 / 確信度）。各値のドメイン / 更新日 / 確信度はページ本体の frontmatter を Source of Truth とする写しです。サマリー列は frontmatter `description` があればその写し、無ければ index 側に蓄積された値そのものです（`description` は optional なので再生成できません）。ページ列のリンクテキストとサマリー列にはセル区切りのエスケープが適用されます。`## 統計` の 3 行は ingest が同期します（節を削除すると同期はスキップされ、総ページ数は `/rite:wiki-lint` のレポート出力で確認できます）。

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|

## 統計

- 総ページ数: 0
- ドメイン別: patterns=0, heuristics=0, anti-patterns=0
- 最終更新: {initialized_at}
