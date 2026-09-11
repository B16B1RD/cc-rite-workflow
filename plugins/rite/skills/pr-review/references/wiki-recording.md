#### 6.5.W Wiki Ingest Trigger (Conditional)

本体の設定判定で Wiki 記録が有効な場合だけ実行する。設定による skip は本体で記録済み。

**Step 2**: Generate a review Raw Source from the review results:
The review content includes: PR number, reviewer types, finding categories, severity distribution, and key patterns detected.

```bash
# {plugin_root} はリテラル値で埋め込む
# ⚠️ wiki-ingest-trigger.sh は --content-file に $PWD 配下・/tmp/rite-*・$TMPDIR/rite-* prefix のみを受容する
# mktemp デフォルトの ${TMPDIR:-/tmp}/tmp.* では trigger が exit 1 で silent fail する
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-content-XXXXXX")
trigger_stderr=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-trigger-err-XXXXXX") || trigger_stderr=/dev/null
# rm -f /dev/null は EPERM (exit 1) を返すため trap で条件分岐する (F-07 対応)
trap 'rm -f "$tmpfile"; [ "$trigger_stderr" != "/dev/null" ] && rm -f "$trigger_stderr"' EXIT
content_write_failed=0  # heredoc write 失敗フラグ (Step 3 で genuine trigger 失敗と区別するため carry-forward)

# heredoc 書き込みの exit code を捕捉 (disk full / permission 拒否で truncated content が
# silent に ingest される regression を防ぐ。wiki ingest は非ブロッキングのため write 失敗時は ingest をスキップ)
if ! cat <<'REVIEW_EOF' > "$tmpfile"
## Review Results

- **PR**: #{pr_number} — {title}
- **Type**: review
- **Reviewed at**: {timestamp}
- **Reviewers**: {reviewer_list}

### Finding Patterns
{finding_summary — レビュー結果の指摘パターン、頻出エラー、プロジェクト固有の癖を LLM がレビュー結果から要約して埋め込む}

### Severity Distribution
- CRITICAL: {count}
- HIGH: {count}
- MEDIUM: {count}
- LOW: {count}
REVIEW_EOF
then
 echo "[CONTEXT] WIKI_CONTENT_WRITE_FAILED=1; reason=cat_redirection_failed" >&2
 echo "WARNING: review ステップ 6.5.W: tmpfile への heredoc 書き込みに失敗 (/tmp full / permission 拒否 / inode 枯渇)。wiki ingest を非ブロッキングにスキップ。" >&2
 trigger_exit=1
 content_write_failed=1
 echo "trigger_exit=$trigger_exit"
else
 bash {plugin_root}/hooks/wiki-ingest-trigger.sh \
  --type reviews \
  --source-ref "pr-{pr_number}" \
  --content-file "$tmpfile" \
  --pr-number {pr_number} \
  --title "{title}（レビュー結果）" \
  2>"$trigger_stderr"
 trigger_exit=$?
 echo "trigger_exit=$trigger_exit"
 if [ "$trigger_exit" -ne 0 ] && [ "$trigger_stderr" != "/dev/null" ] && [ -s "$trigger_stderr" ]; then
  # UTF-8 multi-byte 境界を safe にする (head -c 500 で切れた invalid sequence を drop)
  # (F-09 対応) iconv 不在環境 (Alpine 等) では LC_ALL=C tr で ASCII-only fallback
  if command -v iconv >/dev/null 2>&1; then
   _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
  else
   _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | LC_ALL=C tr -cd '\11\12\15\40-\176')
  fi
  echo "[CONTEXT] WIKI_TRIGGER_STDERR=${_wiki_err_snippet}" >&2
 fi
fi
echo "content_write_failed=$content_write_failed"
```

**ステップ 6.5.W content write failure reason** (reason table drift prevention — heredoc redirection の exit code を `WIKI_CONTENT_WRITE_FAILED` flag の reason 値として surface する):

| reason | Description |
|--------|-------------|
| `cat_redirection_failed` | tmpfile への heredoc redirection の exit code が非ゼロ (disk full / write permission denied / inode 枯渇 / IO error)。truncated content の silent ingest を防ぐため wiki ingest を非ブロッキングにスキップする |

**Non-blocking**: ingest 失敗は review を止めない。`trigger_exit` 非ゼロなら 6.5.W.2 を skip。`content_write_failed` は Step 2 stdout から再取得する（別 bash は shell 状態を引き継がない）。
**Step 3 — Failure surfacing**: write 失敗と genuine trigger 失敗を分けて emit する。

```bash
if [ "${content_write_failed:-0}" -eq 1 ]; then
 # write 失敗経路: trigger は未起動。gate (ステップ 8.0.1) は WIKI_INGEST_* のみ認識するため
 # accurate な reason を付けて WIKI_INGEST_FAILED を emit する (trigger_exit_1 への誤帰属を防ぐ)。
 echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=content_write_failed; exit_code=1"
 echo "WARNING: review ステップ 6.5.W: content write 失敗のため wiki ingest をスキップ (trigger は未起動)。" >&2
elif [ "${trigger_exit:-1}" -ne 0 ] && [ "${trigger_exit:-1}" -ne 2 ]; then
 echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
 echo "WARNING: wiki-ingest-trigger.sh exited $trigger_exit during skills/pr-review/SKILL.md ステップ 6.5.W" >&2
fi
```

**ステップ 6.5.W Step 3 failure surfacing reason** (`WIKI_INGEST_FAILED` flag の reason 値):

| reason | Description |
|--------|-------------|
| `content_write_failed` | tmpfile への heredoc write 失敗 (`content_write_failed=1`)。trigger は未起動。root cause の `WIKI_CONTENT_WRITE_FAILED` とは別に、gate-visible な `WIKI_INGEST_FAILED` を accurate reason で surface する (`trigger_exit_*` への誤帰属を防ぐ) |
| `trigger_exit_<n>` | `wiki-ingest-trigger.sh` が exit `<n>` (≠0, ≠2) で終了した genuine trigger 失敗 |

#### 6.5.W.2 Wiki Raw Commit (Shell — deterministic path)


本 block は **raw sources only** を commit する。page 統合は `/rite:wiki-ingest`。
**Condition**: 次をすべて満たすときだけ（直前 6.5.W stdout）:

- `wiki_enabled=true`
- `auto_ingest=true`
- `trigger_exit=0` (the trigger ran successfully — non-zero means Wiki disabled/uninitialized, so there is nothing to commit)

When the condition is not satisfied, skip this block and proceed to ステップ 6.5.1.

```bash
# {plugin_root} はリテラル値で埋め込む
#
# commit_err の signal trap 登録を block 冒頭で行う。
# SIGINT/SIGTERM/SIGHUP で中断された場合でも /tmp の一時ファイルが orphan として残らない。
commit_err=""
trap 'rm -f "${commit_err:-}"' EXIT INT TERM HUP

# mktemp failure must NOT silently swallow wiki-ingest-commit.sh stderr (fix / close と対称)。
# rc 捕捉は `if cmd; then :; else rc=$?; fi` 形式 (「!」否定は $? を反転するため使用禁止)
# rationale: ../../fix/references/design-rationale.md#wiki-ingest-notes と同根
if commit_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-commit-err-XXXXXX" 2>/dev/null); then
 : # mktemp 成功 — commit_err は valid path
else
 mktemp_commit_err_rc=$?
 echo "WARNING: mktemp failed for wiki-ingest-commit stderr capture (rc=$mktemp_commit_err_rc) — script stderr will be suppressed" >&2
 echo " hint: check /tmp permission / disk space / inode exhaustion" >&2
 commit_err="/dev/null"
fi
commit_rc=0
wiki_push_attempt="review-{pr_number}-$(date +%s)-$$-$RANDOM"
echo "[CONTEXT] WIKI_PUSH_ATTEMPT=$wiki_push_attempt; source=review; pr={pr_number}"
if commit_out=$(bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh 2>"${commit_err}"); then
 # Success — the script prints exactly one status line to stdout, e.g.
 # [wiki-ingest-commit] committed=1; branch=wiki; head=<sha>; push=ok
 # [wiki-ingest-commit] committed=0; branch=wiki; reason=no-pending
 echo "$commit_out"
 echo "[CONTEXT] WIKI_INGEST_DONE=1; pr={pr_number}; type=reviews; attempt=$wiki_push_attempt"
else
 commit_rc=$?
 # exit 2 = 意図的 skip (wiki disabled / branch missing) / exit 4 = commit landed but push failed
 if [ "$commit_err" != "/dev/null" ] && [ -s "$commit_err" ]; then
 head -5 "$commit_err" | sed 's/^/ /' >&2
 fi
 case "$commit_rc" in
 2)
 echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=commit_branch_missing; exit_code=$commit_rc"
 echo "WARNING: wiki-ingest-commit.sh exited 2 (wiki branch missing / disabled) during skills/pr-review/SKILL.md ステップ 6.5.W.2" >&2
 ;;
 4)
 echo "[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; exit_code=$commit_rc; pr={pr_number}; attempt=$wiki_push_attempt"
 # script の stdout status 行 (`committed=N; ...; push=failed`) を保持して local commit を trace 可能にする
 if [ -n "${commit_out:-}" ]; then
 echo "$commit_out"
 fi
 echo "WARNING: wiki-ingest-commit.sh exited 4 (commit landed locally, push failed) during skills/pr-review/SKILL.md ステップ 6.5.W.2" >&2
 ;;
 *)
 echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=commit_rc_$commit_rc; exit_code=$commit_rc"
 echo "WARNING: wiki-ingest-commit.sh exited $commit_rc during skills/pr-review/SKILL.md ステップ 6.5.W.2" >&2
 ;;
 esac
fi
[ "$commit_err" != "/dev/null" ] && rm -f "$commit_err"
commit_err=""
trap - EXIT INT TERM HUP
```

`commit_rc=4` を観測した場合は、上の Bash block とは**別の Bash tool call**で次を 1 回だけ再試行する。`{wiki_push_attempt}` は直前の `WIKI_PUSH_ATTEMPT` marker の値へリテラル置換する。tool call には `dangerouslyDisableSandbox: true` を指定する（ユーザー確認不要。`/rite:open` ステップ 6.1 と同じ既知の SSH host-key / network sandbox 制約）。通常 sandbox のまま同じ push を繰り返してはならない。

```bash
if retry_out=$(bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh --push-only 2>&1); then
  echo "$retry_out"
  echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=ok; source=review; pr={pr_number}; attempt={wiki_push_attempt}"
else
  retry_rc=$?
  printf '%s\n' "$retry_out" | head -5 | sed 's/^/  /' >&2
  echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=failed; source=review; pr={pr_number}; attempt={wiki_push_attempt}; exit_code=$retry_rc"
fi
```

result pattern の emit 前に、**現在の `WIKI_PUSH_ATTEMPT` と同じ `attempt=`** の `WIKI_INGEST_PUSH_FAILED=1` があり、その attempt に `WIKI_INGEST_PUSH_RETRY=ok` が無い場合だけ、次の行を**必ず**完了報告へ表示する（non-blocking は維持する）。過去 attempt の marker は参照しない:

```
⚠️ Wiki push 未完了: local wiki commit は保持されています。手動回復: bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh --push-only
```

**Non-blocking**: 本 block の失敗は review を止めない。失敗時 helper が raw を dev 作業ツリーへ戻す。
**ステップ 6.5.W.2 Wiki Raw Commit failure reasons** (reason table drift prevention — `wiki-ingest-commit.sh` の exit code を `[CONTEXT] WIKI_INGEST_*` flag の reason 値として surface する):

| reason | Description |
|--------|-------------|
| `commit_branch_missing` | `wiki-ingest-commit.sh` が exit 2 (wiki branch 不在 / 無効) で終了 (`WIKI_INGEST_SKIPPED` flag、非ブロッキング) |
| `commit_rc_4` | `wiki-ingest-commit.sh` が exit 4 (commit はローカルに landed したが push 失敗) で終了 (`WIKI_INGEST_PUSH_FAILED` flag、非ブロッキング)。その他の非ゼロ exit は `commit_rc_$commit_rc` 動的 reason として `WIKI_INGEST_FAILED` flag で emit される |

**Position rationale**: [design-rationale.md#wiki-raw-source-placement-notes](design-rationale.md#wiki-raw-source-placement-notes)。
trigger が raw を dev 作業ツリーへ書き、commit helper が wiki ブランチへ移す。page 統合は `/rite:wiki-ingest`。
