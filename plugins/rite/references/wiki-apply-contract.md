# Wiki 適用証跡

実装・修正・レビューが共有する検索とコミット前判定。各スキルは手順を複製せず、この契約と `wiki-apply-capture.sh` / `wiki-apply-gate.sh` を呼ぶ。

## 状態

| status | 意味 | 検索 | commit |
|---|---|---|---|
| ok | ヒットあり | した | 本文の抜粋、判断、applied の検証結果が実物と一致すれば許可 |
| none | 索引を読んだ結果の 0 件 | した | 設定が検索オンかつ記録が現在の作業と一致すれば許可 |
| disabled | `wiki.enabled` が false / no / 0 | しない | 設定が disabled と一致すれば許可 |
| auto_query_off | enabled は true で `auto_query` が true でない | しない | 設定が auto_query_off と一致すれば許可 |
| uninitialized | 有効だが wiki ブランチまたは index が無い | できない | 拒否 |
| error | 読込または抽出の失敗 | 失敗 | 拒否 |

`wiki-query-inject.sh` は stderr に `WIKI_QUERY_STATUS=` を 1 行出す。ok の stdout だけが compact/full の Markdown。それ以外の stdout は空。exit 0 は ok、none、disabled、auto_query_off。exit 2 は uninitialized と error。exit 1 は引数エラー。キーが無い `auto_query` は、inject の直呼びでは検索する。capture は自動経路なので、値が true でない `auto_query` を auto_query_off として検索しない。`yes` や `1` は true ではない。

設定ファイルが無いとき、enabled は true、auto_query は true でない。ゲートは記録の status をこの読み方と照合し、食い違えば `config_mismatch` で拒否する。

## 再試行と再検索

索引とページ本文の読込失敗だけ、inject の内部で初回のあと 1 回試す。引数エラーは再試行しない。capture は追加で回さない。

再利用できるのは、次がすべて現在の作業と一致するときだけ。

- flow-state の issue、worktree（flow-state に worktree が無いときは capture を実行した作業ツリーの物理パス）。commit では session も
- query、executed_at（`YYYY-MM-DDTHH:MM:SSZ`）、attempts（ok と none は 1 以上、disabled と auto_query_off は 0）
- head が `git rev-parse HEAD` と一致
- paths の各 blob が、そのパスが stage 済みなら index、そうでなければ作業ツリーの `git hash-object` と一致
- 今回 stage したパスが記録した paths の部分集合

どれかが違えば拒否する。同じ issue、session、worktree、paths でも、HEAD やファイル内容が変わった記録は通さない。commit では別セッションの成功を通さない。review は commit を許可しないため session を照合しない。別セッションから再開したレビューは、実装・修正したセッションの記録を HEAD・blob の一致と「レビューの突合」節の突合で検証する。

## 証跡

正本はローカル作業メモリの `## Detail` にある `### Wiki 適用証跡`。新しい状態ファイルや frontmatter 項目は作らない。

```text
### Wiki 適用証跡
issue: 7
session: <flow-state の basename>
worktree: <物理パス>
query: <keywords>
executed_at: 2026-09-22T00:00:00Z
status: ok
attempts: 1
diagnostic: -
head: <40 hex>
paths: a,b
blob: a=<40 hex>
blob: b=<40 hex>
page: pages/a.md
rev: <blob>
excerpt: <rev の本文にある 1 行>
body: read
decision: applied
reason: <なぜ適用するか、または対象外か>
evidence: <変更パス>
result: <実行した検証コマンドと結果>
```

ok の各ページは、rev の blob 本文に含まれる 1 行を excerpt にする。`body: read` だけでは許可しない。applied は evidence と result が要る。out は reason が要る。excerpt が本文に無い、または applied の result が空なら拒否する。

## レビューの突合

`--mode review` の allow は承認ではない。applied の各ページで、次の 3 つを実物と突き合わせ、1 つでも違えば指摘にしてレビューを完了にしない。

1. `git cat-file -p <rev>` の本文に excerpt があり、reason がその本文の制約を述べている。
2. evidence のパスの `base...HEAD` 差分を読み、reason の変更がその差分にある。evidence の文字列が diff に含まれるだけでは足りない。
3. result に書いた検証コマンドを再実行し、記録された結果と一致する。

## 境界

`git-commit-file.sh` は commit の前に gate を呼ぶ。deny、または gate スクリプトが無いときは commit しない。allow で commit できたときだけ、証跡の head を新しい HEAD に更新する。`pre-tool-bash-guard.sh` は、phase が implement または fix の git commit に同じ gate を使う。literal な `git -C <path> commit` の対象は hook の cwd ではなくその path である。対象 worktree を解決できない commit は拒否する。別の worktree への commit は止めない。セッション worktree は flow-state の worktree で、flow-state に worktree が無いときは flow-state を持つ checkout（`<root>/.rite/sessions/` の `<root>`）である。head を新しい HEAD へ更新するのは、セッション worktree の commit が allow になったときだけである。phase がそれ以外の commit は止めない。
