# コミット規約の適用

rite が作るコミットは、対象リポジトリのルートにある CLAUDE.md と AGENTS.md のコミット規約を優先する。指定のない項目だけを rite の既定で補う。自然言語の解釈は LLM が行い、helper は解釈しない。

## いつ読むか

メッセージを生成する直前に、毎回 `commit-convention-locate.sh` を実行し、返ったパスを Read する。結果を flow-state に保存して再利用しない。

```bash
bash {plugin_root}/hooks/scripts/commit-convention-locate.sh
```

| 出力 | 意味 |
|------|------|
| `COMMIT_CONVENTION_PRESENT=0` | 両ファイル不在。下記「既定」を使う |
| `CLAUDE_MD=` / `AGENTS_MD=` が絶対パス | そのファイルを Read する |
| helper が非ゼロ | 読取失敗。規約なしへ倒さず、対象コミットを止める |

locate は `state-path-resolve.sh` の共有ルートを見る。Wiki の分離ブランチ / worktree に規約ファイルが無くても、元プロジェクトのファイルを使う。サブディレクトリの同名ファイルは読まない。

## 指定項目と既定

両ファイルを同じ適用対象として読む。一方を常時優先しない。同一項目（言語、件名形式、本文の可否、trailer の可否）が食い違うときは、食い違い箇所を示してコミットしない。

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
| PR がある | PR 本文の該当節、および既存 `.rite/review-results/` |
| PR がない | 作業メモリの「決定事項・メモ」、または `commit-overflow-record.sh` が書いた既存ストア |

```bash
bash {plugin_root}/hooks/scripts/commit-overflow-record.sh write \
  --file "{store_file}" --section "{section}" --body-file "{body_file}"
```

書込が失敗したら成功扱いにしない。検査（Root Cause Gate を含む）はコミット本文を先に見し、無ければ同じ保存先を読む。どちらにも無ければ `missing` のまま止める。ゲート自体は無効化しない。

## helper への受渡し

生成したメッセージは作業ツリー外の絶対パスへ書き、`git commit -F` または helper の `--message-file` で渡す。引用符・改行・コマンドに見える文字列をシェルで展開しない。

規約ファイルがある自動 helper に `--message-file` を渡さない実行は fail-loud する。`--message` の改行拒否と wiki-numref-precommit は残す。
