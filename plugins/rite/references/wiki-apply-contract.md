# Wiki 適用証跡

実装・修正・レビューが共有する検索とコミット前判定。各スキルは手順を複製せず、この契約と `wiki-apply-capture.sh` / `wiki-apply-gate.sh` を呼ぶ。

## 状態

| status | 意味 | 検索 | commit |
|---|---|---|---|
| ok | ヒットあり | した | 各ページの本文確認と判断が揃えば許可 |
| none | 索引を読んだ結果の 0 件 | した | 許可 |
| disabled | `wiki.enabled` が false | しない | 許可 |
| auto_query_off | `auto_query` が true でない | しない | 許可 |
| uninitialized | 有効だが wiki ブランチまたは index が無い | できない | 拒否 |
| error | 読込または抽出の失敗 | 失敗 | 拒否 |

`wiki-query-inject.sh` は stderr に `WIKI_QUERY_STATUS=` を 1 行出す。ok の stdout だけが compact/full の Markdown。それ以外の stdout は空。exit 0 は ok、none、disabled、auto_query_off。exit 2 は uninitialized と error。exit 1 は引数エラー。キーが無い `auto_query` は、inject の直呼びでは検索する（手動クエリと既存テスト）。capture は自動経路なので、true でない `auto_query` を auto_query_off として検索しない。

## 再試行と再検索

索引とページ本文の読込失敗だけ、inject の内部で初回のあと 1 回試す。引数エラーは再試行しない。capture は追加で回さない。

記録を再利用できるのは、flow-state の issue、session、worktree が記録と一致し、今回 stage したパスが記録した `paths` の部分集合であるときだけ。どれかが違えば再検索する。別セッションの成功では通さない。

## 証跡

正本はローカル作業メモリの `## Detail` にある `### Wiki 適用証跡`。新しい状態ファイルや frontmatter 項目は作らない。

```text
### Wiki 適用証跡
issue: 7
session: <flow-state の basename>
worktree: <物理パス>
query: <keywords>
status: ok
attempts: 1
diagnostic: -
paths: a,b
page: pages/a.md
rev: <blob>
body: read
decision: applied
reason: <なぜ適用するか、または対象外か>
evidence: <変更パスまたは diff に現れる検証の文字列>
```

ok のページは本文を読んでから `body: read` にする。applied は evidence が要る。out は reason が要る。

## 境界

`git-commit-file.sh` は commit の前に gate を呼ぶ。deny、または gate スクリプトが無いときは commit しない。`pre-tool-bash-guard.sh` は、phase が implement または fix で作業ツリーが一致する git commit に同じ gate を使う。phase がそれ以外の commit は止めない。レビューは `--mode review` を使い、applied の evidence が `base...HEAD` の diff に無いとき承認しない。
