# コミット規約の適用

rite が作るコミットは、今いる作業ツリーの CLAUDE.md と AGENTS.md のコミット規約を優先する。対象変更パスに適用するネストした同名ファイルも、ホストの指示階層に従って読む。指定のない項目だけを rite の既定で補う。自然言語の解釈は LLM が行い、helper は解釈しない。

## いつ読むか

メッセージを生成する直前に、毎回 `commit-convention-locate.sh` を実行し、返ったパスを Read する。結果を flow-state に保存して再利用しない。コミット対象の相対パスがあるときは `--path` で渡す。

```bash
bash {plugin_root}/hooks/scripts/commit-convention-locate.sh --path {changed_path}
```

| 出力 | 意味 |
|------|------|
| `COMMIT_CONVENTION_PRESENT=0` | 適用ファイル不在。下記「既定」を使う |
| `CLAUDE_MD=` / `AGENTS_MD=` が絶対パス | 作業ツリー根のファイルを Read する |
| `NESTED_CLAUDE_MD=` / `NESTED_AGENTS_MD=` | 対象パスに適用するネストしたファイル（コロン区切り）。空なら根だけ |
| helper が非ゼロ | 読取失敗。規約なしへ倒さず、対象コミットを止める |

locate の既定ルートは `git rev-parse --show-toplevel`（当該作業ツリー）。共有ルート（`state-path-resolve.sh`）へ倒すのは、Wiki 分離ツリーに規約ファイルが無いときだけである。通常の feature worktree は、そのツリーに置いた最新の規約を読む。

ネストした CLAUDE.md / AGENTS.md は対象変更パスの祖先ディレクトリにあるものだけを適用する。`--path` が無いときは、cwd が根の下ならその親連鎖だけを辿る。全ツリー検索はしない。ホストの指示階層では、対象パスにより近いネストが根より優先する。同じディレクトリの CLAUDE.md と AGENTS.md が同一項目で食い違うなど、階層で解決できないときだけ食い違い箇所を示してコミットしない。ホストの managed / user 指示ファイルは読まない。

## 指定項目と既定

両ファイルを同じ適用対象として読む。一方を常時優先しない。同一項目が食い違うときは、食い違い箇所を示してコミットしない。

| 項目 | 規約に指定があるとき | 未指定の既定 |
|------|----------------------|--------------|
| 言語 | 指定どおり | LLM 経路: `rite-config.yml` の `language`。helper 自動コミット: その helper の現行固定文 |
| 件名形式 | 指定どおり | Conventional Commits `type(scope): description` |
| 本文 | 禁止なら書かない。必須なら書く | LLM 経路は why 本文を書く。helper 固定文は現行どおり |
| trailer | 禁止ならコミットに付けない | 既存の Addresses / Acknowledged-finding を付ける |

helper の固定文へ LLM 経路の既定を置き換えない。

## 必須記録が規約に収まらないとき

根本原因・simplification-first・Acknowledged-finding などの必須記録は削除しない。コミットに書けないときは次へ移し、検査も同じ場所を読む。

| 経路 | 保存先 |
|------|--------|
| PR がある | PR 本文の該当節（下書きへ helper write → `gh pr edit --body-file` → `gh pr view` で同じファイルへ再取得してから `read`。view/edit 失敗は成功扱いにしない）、および既存 `.rite/review-results/` |
| PR がない | `{state_root}/.rite/commit-records/issue-{issue_number}.md`（`commit-overflow-record.sh` が書く）。cleanup の作業メモリ削除では消えない |

```bash
bash {plugin_root}/hooks/scripts/commit-overflow-record.sh write \
  --file "{store_file}" --section "{section}" --body-file "{body_file}"
```

書込が失敗したら成功扱いにしない。検査（Root Cause Gate を含む）はコミット本文を先に見し、無ければ同じ保存先を読む。どちらにも無ければ `missing` のまま止める。ゲート自体は無効化しない。

## helper への受渡し

生成したメッセージは作業ツリー外の絶対パスへ書き、`git commit -F` または helper の `--message-file` で渡す。引用符・改行・コマンドに見える文字列をシェルで展開しない。

規約ファイルがある自動 helper に `--message-file` を渡さない実行は fail-loud する。`--message` の改行拒否と wiki-numref-precommit は残す。
