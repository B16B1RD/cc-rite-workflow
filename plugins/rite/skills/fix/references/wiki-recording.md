### 4.6.W Wiki Ingest Trigger (Conditional)

本体の設定判定で Wiki 記録が有効な場合だけ実行する。設定による skip は本体で記録済み。

**Step 2**: Generate a fix Raw Source from the fix results:

The fix content includes: findings addressed, fix strategies used, and patterns of overcorrection or effective approaches. 下のテンプレートの本文を Write tool で `{wiki_content_file}` に書き、ステップ 1.1 の PR title を 1 行で作業ツリー外の絶対パス `{wiki_title_file}` に書いてから、次の 1 行を実行する。`{wiki_content_file}` は `$TMPDIR`（未設定なら `/tmp`）直下の `rite-` で始まる絶対パス（例: `rite-fix-wiki-content-{pr_number}.md`）にする。helper は本文を写さずに `wiki-ingest-trigger.sh` へ渡すため、trigger の symlink 拒否とパス allowlist がこのパスに効き、外れたパスは trigger が exit 1 で拒否する。

```markdown
## Fix Results

- **PR**: #{pr_number}
- **Type**: fix
- **Fixed at**: {timestamp}

### Fix Patterns
{fix_summary — 修正パターン、過剰反応の傾向、効果的な修正戦略を LLM が修正結果から要約して埋め込む}

### Statistics
- Total findings: {total_count}
- Fixed: {fix_count}
- Replied: {reply_count}
```

```bash
bash {plugin_root}/scripts/fix-step.sh wiki-trigger --pr {pr_number} --content-file '{wiki_content_file}' --title-file '{wiki_title_file}'
```

**Non-blocking**。非ゼロなら 4.6.W.2 を skip。`content_write_failed` も Step 2 stdout から再注入して Step 3 で使う (Bash 呼び出し間でシェル状態は消える)。

**Step 3 — Failure surfacing**: 2 つの失敗経路を区別して surface する。

`{content_write_failed}` / `{trigger_exit}` は Step 2 の stdout の値を使う。

- **(a) content write 失敗** (`content_write_failed=1`): trigger は**起動していない**ため `trigger_exit` の値 (1) を reason にすると誤帰属になる。root cause は Step 2 の `WIKI_CONTENT_WRITE_FAILED` で既出だが、W Phase Completion Gate (ステップ 5.0) は `WIKI_INGEST_*` 接頭辞の sentinel しか認識しないため、gate-visible な `WIKI_INGEST_FAILED` を `reason=content_write_failed` で emit する。
- **(b) genuine trigger 失敗** (`trigger_exit != 0` AND `trigger_exit != 2`、exit 2 = Wiki disabled/uninitialized = legitimate skip は Step 1 で既出): `wiki-ingest-trigger.sh` が実際に非ゼロ終了したので `reason=trigger_exit_$trigger_exit` で emit する。

```bash
bash {plugin_root}/scripts/fix-step.sh wiki-trigger-result --content-write-failed {content_write_failed} --trigger-exit {trigger_exit}
```

**ステップ 4.6.W Step 3 failure surfacing reason** (`WIKI_INGEST_FAILED` flag の reason 値):

| reason | Description |
|--------|-------------|
| `content_write_failed` | 本文またはタイトルのファイルの不在・空 (`content_write_failed=1`)。trigger は未起動。root cause の `WIKI_CONTENT_WRITE_FAILED` とは別に、gate-visible な `WIKI_INGEST_FAILED` を accurate reason で surface する (`trigger_exit_*` への誤帰属を防ぐ) |
| `trigger_exit_<n>` | `wiki-ingest-trigger.sh` が exit `<n>` (≠0, ≠2) で終了した genuine trigger 失敗 |

### 4.6.W.2 Wiki Raw Commit (Shell — deterministic path)


**Responsibility scope**: this block commits **raw sources only**. LLM-driven Wiki **page** integration is deferred to `/rite:wiki-ingest`, which is idempotent over accumulated raw sources and can be invoked later. The split guarantees raw sources are never lost even when page integration is skipped or fails.

**Condition**: Execute only when **all** of the following are true (read from prior ステップ 4.6.W stdout):

- `wiki_enabled=true`
- `auto_ingest=true`
- `trigger_exit=0` (the trigger ran successfully — non-zero means Wiki disabled/uninitialized, so there is nothing to commit)

When the condition is not satisfied, skip this block.

コミットメッセージ `{wic_commit_message}`（[commit-convention.md](../../../references/commit-convention.md) 適用後の全文）を Write tool で作業ツリー外の絶対パス `{wic_message_file}` に書いてから、次の 1 行を実行する。ファイルが無い・空なら `WIKI_INGEST_FAILED=1; reason=msg_file_missing` を出して commit をスキップし（非ブロッキング）、中身が未置換の `{...}` なら `reason=msg_placeholder_residue` を出して exit 1 で止まる。

```bash
bash {plugin_root}/scripts/fix-step.sh wiki-raw-commit --pr {pr_number} --message-file '{wic_message_file}'
```

`wiki_ingest_commit_rc=4` を観測した場合（`WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; exit_code=4`）は、上の Bash block とは**別の Bash tool call**で次を 1 回だけ再試行する。`{wiki_push_attempt}` は直前の `WIKI_PUSH_ATTEMPT` marker の値へリテラル置換する。tool call には `dangerouslyDisableSandbox: true` を指定する（ユーザー確認不要。`/rite:open` ステップ 6.1 と同じ既知の SSH host-key / network sandbox 制約）。通常 sandbox のまま同じ push を繰り返してはならない。

```bash
bash {plugin_root}/scripts/fix-step.sh wiki-push-retry --pr {pr_number} --attempt {wiki_push_attempt}
```

result pattern の emit 前に、**現在の `WIKI_PUSH_ATTEMPT` と同じ `attempt=`** の `WIKI_INGEST_PUSH_FAILED=1` があり、その attempt に `WIKI_INGEST_PUSH_RETRY=ok` が無い場合だけ、次の行を**必ず**完了報告へ表示する（non-blocking は維持する）。過去 attempt の marker は参照しない:

```
⚠️ Wiki push 未完了: local wiki commit は保持されています。手動回復: bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh --push-only
```

**Non-blocking**: failures do not halt the fix workflow. `wiki-ingest-commit.sh` restores raw source files on failure via its cleanup trap, so the next invocation can retry them.

**ステップ 4.6.W.2 Wiki Raw Commit failure reasons** (reason table drift prevention — `wiki-ingest-commit.sh` の exit code を `[CONTEXT] WIKI_INGEST_*` flag の reason 値として surface する):

| reason | Description |
|--------|-------------|
| `commit_branch_missing` | `wiki-ingest-commit.sh` が exit 2 (wiki branch 不在 / 無効) で終了 (`WIKI_INGEST_SKIPPED` flag、非ブロッキング) |
| `commit_rc_4` | `wiki-ingest-commit.sh` が exit 4 (commit はローカルに landed したが push 失敗) で終了 (`WIKI_INGEST_PUSH_FAILED` flag、非ブロッキング)。その他の非ゼロ exit は `commit_rc_$wiki_ingest_commit_rc` 動的 reason として `WIKI_INGEST_FAILED` flag で emit される |

rationale: design-rationale.md#wiki-ingest-placement

---
