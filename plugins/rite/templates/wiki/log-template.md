# Directory Update Log

このファイルは Wiki の変更履歴を OKF 予約ファイル構造（`## YYYY-MM-DD` 見出し + 散文 bullet、新しい順。v0.2 §9 は v0.1 から不変）で記録します（append-only、人間向け）。

skip 等の機械可読状態は **各 raw source の frontmatter（`ingest_status`）が Source of Truth** であり、本ログには保持しません（本ログは人間向けの変更履歴に純化しています）。例外は lint エントリ直下の「未解消の矛盾」の行で、次回の lint と ingest が未解消の矛盾の記録として読みます。

## {initialized_date}

* **init** — Wiki を初期化しました
