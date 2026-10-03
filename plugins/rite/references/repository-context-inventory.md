# Repository Context Inventory

作業先の規範と設計理由は [Host Runtime Contract](host-runtime-contract.md#作業先と所有者)。配布パスを絶対指定しても helper の cwd は変わらない。以下は repository 解決・state 置場・worktree 判定を持つ候補の全件で、コメントと tests 配下を除く。

## 分類と確認方法

| 記号 | 処理 | foreign cwd の影響 / 壊れない条件 |
|---|---|---|
| R | `git-remote.sh`、`remote.origin.url`、`gh repo view` | 暗黙解決は foreign repository を採る。入口で対象 cwd を固定し、API の repository 引数を明示した呼出しは対象を維持する |
| S | `state-path-resolve.sh` | 引数省略は foreign state root。明示した対象パスなら cwd に依存しない。linked worktree は main checkout の共有 root を返す |
| W | `git rev-parse`、`git worktree`（`git -C` を含む） | bare git は foreign HEAD / worktree を読む。対象絶対パスへ `git -C` / `cd` した操作は対象を維持する。worktree の HEAD と共有 state root は別のパス |

同じ helper が複数分類を持つ場合は両方を照合する。`--repo` だけでは S/W を固定できない。`dirname BASH_SOURCE` の `pwd` は配布ファイル探索であり repository 解決候補に含めない。

```bash
rg -n 'git-remote.sh|remote.origin.url|gh repo view|state-path-resolve|git (rev-parse|worktree)|git -C' \
  "{plugin_root}/scripts" "{plugin_root}/hooks" -g '*.sh' -g '!**/tests/**' -g '!*.test.sh'
rg -n 'issue-complexity-lane.sh|git-remote.sh|state-path-resolve' "{plugin_root}/skills" -g '*.md'
```

## Complexity 呼出し family

| Consumer | 必須入力 | 確認 |
|---|---|---|
| `skills/open/SKILL.md` | `--issue` と `--repo "{owner_repo}"`、固定 cwd | helper が repository 不一致で止まったら open を続けない |
| `skills/issue-implement/SKILL.md` | 同上 | 不一致を full fallback として実装へ流さない |
| `skills/pr-review/SKILL.md` | 同上 | 不一致を full fallback としてレビューへ流さない |

他の repo 解決呼出し（issue-create / setup / lint / ready / cleanup / pr-create / session-detection）と state helper 呼出しも同じ入口・nested cwd 契約を使う。helper ごとに別の repository override を増やさない。

## 副作用のない実測の再実行

同梱の [helper suite](../scripts/tests/issue-complexity-lane.test.sh) はローカル Git repository と gh shim を作り、不一致・明示入力欠落・API 取得失敗を検証する。[consumer suite](../hooks/tests/complexity-lane-contract.test.sh) で family の入力契約を確認する。どちらも一時ファイルを自分で生成し、過去セッションの `/tmp` ファイルや実 API に依存しない。

```bash
bash "{plugin_root}/scripts/tests/issue-complexity-lane.test.sh"
bash "{plugin_root}/hooks/tests/complexity-lane-contract.test.sh"
```

ネットワークへ接続しない二つのローカル Git repository を作り、origin を `git@github.com-alias:fixture/target.git` / `fixture/foreign.git` に設定する。target に linked worktree を追加する。PATH の先頭に gh shim を置き、`issue view -R fixture/target` は Complexity S、foreign は XL を返し、argv/cwd をログへ記録する。両 repo と linked worktree から同じ絶対 helper パスを呼ぶ。

| Probe | 観測 / 期待 |
|---|---|
| `git-remote.sh resolve-owner-repo` | target/linked は `fixture<TAB>target`、foreign は `fixture<TAB>foreign` |
| `state-path-resolve.sh` | target/linked は target の main root、foreign は foreign root |
| `state-path-resolve.sh <target絶対パス>` | どの cwd でも target root |
| `git rev-parse --show-toplevel` | target / foreign / linked の各実 worktree |
| Complexity helper の repository 明示 / 省略 | target/linked + `--repo fixture/target` は light。foreign + target 明示は非ゼロ停止し Issue API を呼ばない。`--repo` 省略もどの cwd でも非ゼロ停止 |
| shim が認証 / rate limit エラーを返す | repository 照合成功後の取得失敗は従来の `issue_fetch_failed` full fallback |

この測定は各候補の内部処理全体を実行した証拠ではない。上記 R/S/W の解決 primitive と全 Complexity consumer の呼出し条件を確認する。書込 helper 全体を foreign repository で起動せず、候補表のコード位置を読んで明示 cwd / path と暗黙呼出しを区別する。

## Shell 候補一覧

| 配布内パス | 分類 |
|---|---|
| `scripts/check-no-direct-gh-issue-create.sh` | W |
| `scripts/create-issue-with-projects.sh` | R |
| `scripts/fix-step.sh` | R / S / W |
| `scripts/issue-complexity-lane.sh` | R |
| `scripts/iterate-step.sh` | S / W |
| `scripts/migrate-review-state-to-1.1.sh` | S / W |
| `scripts/pr-review-step.sh` | S / W |
| `scripts/review-cycle-scope.sh` | S |
| `scripts/review-pr-recommendations.sh` | S |
| `scripts/review-source-resolve.sh` | S / W |
| `scripts/watchdog-status-mismatch.sh` | R |
| `hooks/_validate-helpers.sh` | S |
| `hooks/_validate-state-root.sh` | S |
| `hooks/cleanup-work-memory.sh` | S |
| `hooks/flow-state.sh` | S |
| `hooks/host-runtime.sh` | S / W |
| `hooks/issue-body-safe-update.sh` | R |
| `hooks/issue-claim.sh` | S |
| `hooks/issue-comment-wm-sync.sh` | R / S |
| `hooks/post-compact.sh` | R / S |
| `hooks/post-tool-wm-sync.sh` | S |
| `hooks/pre-compact.sh` | S |
| `hooks/pre-tool-bash-guard.sh` | S / W |
| `hooks/pre-tool-edit-guard.sh` | W |
| `hooks/release-promotion-verify.sh` | R / S |
| `hooks/review-result-save.sh` | S |
| `hooks/review-skip-notification.sh` | S |
| `hooks/scripts/backlink-format-check.sh` | W |
| `hooks/scripts/bang-backtick-check.sh` | W |
| `hooks/scripts/bang-backtick-edit-hook.sh` | W |
| `hooks/scripts/bash-heaviness-check.sh` | W |
| `hooks/scripts/cleanup-deferred-branch-recovery.sh` | S / W |
| `hooks/scripts/cleanup-pr-state-purge.sh` | S |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` | W |
| `hooks/scripts/comment-journal-check.sh` | W |
| `hooks/scripts/comment-line-ref-check.sh` | W |
| `hooks/scripts/commit-convention-locate.sh` | S / W |
| `hooks/scripts/dollar-zero-check.sh` | W |
| `hooks/scripts/fix-reason-coverage-check.sh` | W |
| `hooks/scripts/fix-report-diff-gate.sh` | S / W |
| `hooks/scripts/git-commit-file.sh` | W |
| `hooks/scripts/gitignore-health-check.sh` | S / W |
| `hooks/scripts/hardcoded-line-number-check.sh` | W |
| `hooks/scripts/lib/git-remote.sh` | R |
| `hooks/scripts/lib/rite-config-path.sh` | S / W |
| `hooks/scripts/lib/worktree-git.sh` | W |
| `hooks/scripts/nb-sweep-collect.sh` | R |
| `hooks/scripts/number-reference-check.sh` | W |
| `hooks/scripts/orphan-reference-check.sh` | W |
| `hooks/scripts/post-review-state-verify.sh` | W |
| `hooks/scripts/pr-cycle-cleanup.sh` | R / S / W |
| `hooks/scripts/projects-board-drift-check.sh` | R |
| `hooks/scripts/projects-status-gate.sh` | R |
| `hooks/scripts/ready-pr-head-gate.sh` | W |
| `hooks/scripts/ready-reviewed-head-gate.sh` | S |
| `hooks/scripts/review-adoption-gate.sh` | R |
| `hooks/scripts/review-fix-scope-check.sh` | S |
| `hooks/scripts/review-save-json-verify.sh` | S / W |
| `hooks/scripts/review-schema-version-check.sh` | S / W |
| `hooks/scripts/review-trend-divergence.sh` | S |
| `hooks/scripts/reviewer-registry-drift-check.sh` | W |
| `hooks/scripts/rite-tmp-artifact.sh` | S / W |
| `hooks/scripts/run-queue-reap.sh` | S |
| `hooks/scripts/sentinel-contract-check.sh` | W |
| `hooks/scripts/sh-cross-ref-check.sh` | W |
| `hooks/scripts/skill-rail-diff-check.sh` | W |
| `hooks/scripts/tempfile-lifecycle-check.sh` | W |
| `hooks/scripts/tmp-hardcode-check.sh` | W |
| `hooks/scripts/triage-adoption-run.sh` | S |
| `hooks/scripts/wiki-apply-advance-head.sh` | S / W |
| `hooks/scripts/wiki-apply-capture.sh` | S / W |
| `hooks/scripts/wiki-apply-gate.sh` | S / W |
| `hooks/scripts/wiki-branch-init.sh` | W |
| `hooks/scripts/wiki-growth-check.sh` | W |
| `hooks/scripts/wiki-ingest-commit.sh` | S / W |
| `hooks/scripts/wiki-ingest-lock.sh` | S |
| `hooks/scripts/wiki-lint-broken-refs.sh` | W |
| `hooks/scripts/wiki-lint-descriptive-refs.sh` | W |
| `hooks/scripts/wiki-lint-orphans.sh` | W |
| `hooks/scripts/wiki-lint-skipped-refs.sh` | W |
| `hooks/scripts/wiki-lint-source-refs.sh` | W |
| `hooks/scripts/wiki-lint-stale.sh` | W |
| `hooks/scripts/wiki-worktree-commit.sh` | S / W |
| `hooks/scripts/wiki-worktree-setup.sh` | S / W |
| `hooks/session-end.sh` | S |
| `hooks/session-start.sh` | S / W |
| `hooks/state-path-resolve.sh` | W |
| `hooks/stop-failure.sh` | S |
| `hooks/stop-loop-continuation.sh` | S |
| `hooks/wiki-ingest-trigger.sh` | S |
| `hooks/wiki-query-inject.sh` | S / W |
| `hooks/work-memory-update.sh` | S / W |
