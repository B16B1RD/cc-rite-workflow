---
okf_version: "0.1"
description: "rite Experience Wiki — プロジェクト固有の経験則 bundle（OKF v0.1 準拠）"
---

# Wiki Index

このファイルは Wiki 全ページのカタログです。Ingest サイクルごとに `## ページ一覧` の 5 列テーブルが自動更新されます。

bundle-root の frontmatter で OKF（Open Knowledge Format）v0.1 への準拠を `okf_version: "0.1"` として宣言します。各ページは `## ページ一覧` テーブルの 1 行として登録されます（列順: ページ / ドメイン / サマリー / 更新日 / 確信度）。各値の Source of Truth はページ本体の frontmatter で、テーブルはカタログ用の写しです。`## 統計` 節を置くと ingest が総ページ数 / ドメイン別内訳 / 最終更新を同期します（節が無ければ同期はスキップされ、総ページ数は `/rite:wiki-lint` のレポート出力で確認できます）。

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
