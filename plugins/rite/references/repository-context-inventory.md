# Repository Context Inventory

作業先の規範と設計理由は [Host Runtime Contract](host-runtime-contract.md#作業先と所有者)。配布パスを絶対指定しても helper の cwd は変わらない。以下は repository 解決・state 置場・worktree 判定を持つ呼出しの分類結果。コメントと tests 配下を除く。各行の判定は原始操作の実測と当該式の読解に基づき、書込 helper 全体を foreign repository で実行した結果とは区別する。

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
| `skills/open/SKILL.md` | `--issue` と保持した `--repo {owner_repo}`、絶対 `--cwd "{execution_cwd}"` | helper が repository 不一致で止まったら open を続けない |
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
| Complexity helper の repository 明示 / 省略 | target/linked + `--repo fixture/target` は light。foreign 開始 cwd でも `--cwd` に target の絶対パスを渡せば light。foreign + target 明示は非ゼロ停止し Issue API を呼ばない。`--repo` 省略もどの cwd でも非ゼロ停止 |
| shim が認証 / rate limit エラーを返す | repository 照合成功後の取得失敗は従来の `issue_fetch_failed` full fallback |

この測定は各候補の内部処理全体を実行した証拠ではない。上記 R/S/W の解決 primitive と全 Complexity consumer の呼出し条件を確認する。書込 helper 全体を foreign repository で起動せず、候補表のコード位置を読んで明示 cwd / path と暗黙呼出しを区別する。

## 呼出し単位の判定と除外理由

`壊れない（明示対象）` は呼出し式自身の対象パスが固定される。`壊れない（固定cwd）` は既存の最外側入口と nested 実行が同じ `{execution_cwd}` を使う条件に基づく除外であり、非固定の単体実行では壊れる。この条件は各行に記録する。入口の owner/repo は一度だけ解決して保持し、後続では再解決しない。

Complexity の三つの consumer は固定 cwd だけでは repo 引数を持たず、入口 identity を検査できなかったため修正対象。他の固定 cwd 呼出しの正常な操作行は書き換えない。各表の「式」は上の `rg -n` で再発見できる source の検索キー。重複する式はファイル内出現順で区別する。行番号を規範として固定しない。

| 修正対象 consumer | 分類 | 修正前の判定と根拠 | 適用後 |
|---|---|---|---|
| `skills/open/SKILL.md` の complexity block | R | 壊れる。調査でforeign cwdへ移ると誤Issueを取得し full fallback | 入口identityと絶対cwdを明示し不一致停止 |
| `skills/issue-implement/SKILL.md` の complexity block | R | 壊れる。同じ絶対helperでもcwdは変わらず誤Issueを取得 | 同上。入口identityはnestedで再解決しない |
| `skills/pr-review/SKILL.md` の complexity block | R | 壊れる。foreign originで誤ったレーンへ倒れる | 同上。非ゼロ終了はレビュー停止 |

## Script の個別一覧

| 配布内パス・出現順 | 式 | 分類 | 壊れる／壊れないの判定 | 根拠・除外理由 |
|---|---|---|---|---|
| `scripts/check-no-direct-gh-issue-create.sh` (1) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/create-issue-with-projects.sh` (1) | `_git_or_line=$(bash "$PLUGIN_ROOT/hooks/scripts/lib/git-remote.sh" resolve-owner-repo 2>/dev/null) ¦¦ _git_or_line=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/fix-step.sh` (1) | `owner_repo=$(bash "$plugin_root"/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/fix-step.sh` (2) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/fix-step.sh` (3) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/fix-step.sh` (4) | `echo "ERROR: fix-step.sh: owner/repo を解決できませんでした (git-remote.sh と gh repo view の両方が失敗)" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/fix-step.sh` (5) | `owner_repo=$(bash "$plugin_root"/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/fix-step.sh` (6) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/fix-step.sh` (7) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/fix-step.sh` (8) | `echo "ERROR: fix-step.sh: owner/repo を解決できませんでした (git-remote.sh と gh repo view の両方が失敗)" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/fix-step.sh` (9) | `if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/fix-step.sh` (10) | `echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/fix-step.sh` (11) | `if [ "${reviewed_commit_sha}" = "$(git rev-parse HEAD)" ]; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/fix-step.sh` (12) | `if ! state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ [ -z "$state_root" ]; then` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (13) | `triage_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ {` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (14) | `_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (15) | `head_sha=$(git rev-parse HEAD 2>/dev/null ¦¦ echo "unknown")` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/fix-step.sh` (16) | `fix_cycle_base_sha=$(git rev-parse HEAD) ¦¦ { echo "[fix:error]"; exit 1; }` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/fix-step.sh` (17) | `git rev-parse --verify "${nref_base}^{commit}" >/dev/null 2>&1 ¦¦ nref_base="${base_branch}"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/fix-step.sh` (18) | `_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (19) | `commit_sha_after=$(git rev-parse HEAD 2>/dev/null ¦¦ echo "unknown")` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/fix-step.sh` (20) | `_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (21) | `_nb_done_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ _nb_done_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (22) | `_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (23) | `sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ sweep_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (24) | `echo "ERROR: state-path-resolve が空。NB sweep 対象を取得できない" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/fix-step.sh` (25) | `sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ sweep_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (26) | `sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ {` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (27) | `sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ sweep_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/fix-step.sh` (28) | `sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ exit 1` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/issue-complexity-lane.sh` (1) | `_or_line=$(bash "$_icl_dir/../hooks/scripts/lib/git-remote.sh" resolve-owner-repo) ¦¦ {` | R | 単体foreignでは不一致停止、修正 | 保持した --repo と cwd origin を比較する検査。cwdから対象identityを上書きしない |
| `scripts/iterate-step.sh` (1) | `pin_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ pin_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/iterate-step.sh` (2) | `current_head=$(git rev-parse HEAD 2>/dev/null) ¦¦ current_head=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/iterate-step.sh` (3) | `pin_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ pin_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/iterate-step.sh` (4) | `nb_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ nb_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/iterate-step.sh` (5) | `echo "ERROR: state-path-resolve が空を返した。NB sweep 対象を取得できない" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/iterate-step.sh` (6) | `nb_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ exit 1` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/iterate-step.sh` (7) | `nb_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) ¦¦ nb_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/iterate-step.sh` (8) | `echo "ERROR: state-path-resolve が空を返した。止まった sweep の有無を判定できない" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/iterate-step.sh` (9) | `head_sha=$(git rev-parse HEAD 2>/dev/null) ¦¦ head_sha=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/iterate-step.sh` (10) | `state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/migrate-review-state-to-1.1.sh` (1) | `if [ -z "${REPO_ROOT:-}" ] && git rev-parse --show-toplevel >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/migrate-review-state-to-1.1.sh` (2) | `if _mig_state_root=$("$_mig_script_dir/../hooks/state-path-resolve.sh" 2>/dev/null) && [ -n "$_mig_state_root" ]; then` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/migrate-review-state-to-1.1.sh` (3) | `echo "WARNING: state-path-resolve.sh の解決に失敗。git toplevel をフォールバック使用します" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/migrate-review-state-to-1.1.sh` (4) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/pr-review-step.sh` (1) | `if ! local_head=$(git rev-parse HEAD); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/pr-review-step.sh` (2) | `git rev-parse HEAD` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/pr-review-step.sh` (3) | `_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/pr-review-step.sh` (4) | `_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/pr-review-step.sh` (5) | `if git rev-parse --verify "origin/${base_branch}^{commit}" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/pr-review-step.sh` (6) | `echo "RESUME_HINT: flow-state.sh が異常 exit (rc=$rc) しました。ファイル不在/empty/jq parse 失敗は --default で吸収 (exit 0) されるため、本経路は helper validation 失敗 / --field 引数欠落 / invalid field name 等の caller 側引数異常で発火します。\$PLUGIN_ROOT/hooks/_validate-helpers.sh と state-path-resolve.sh の存在/実行権限を確認し、必要なら /rite:recover で再開、または STATE_ROOT 配下の sessions/ を確認してください。" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/pr-review-step.sh` (7) | `_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/review-cycle-scope.sh` (1) | `_rcs_root=$(bash "$_rcs_dir/../hooks/state-path-resolve.sh" "$PWD" 2>/dev/null) ¦¦ _rcs_root=""` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `scripts/review-cycle-scope.sh` (2) | `[ -n "$_rcs_root" ] ¦¦ echo "WARNING: review-cycle-scope: state-path-resolve.sh の解決に失敗しました" >&2` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/review-pr-recommendations.sh` (1) | `state_root=$(bash "$HOOKS_DIR/state-path-resolve.sh") ¦¦ fail results_dir_missing "state root unresolved"` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `scripts/review-source-resolve.sh` (1) | `if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/review-source-resolve.sh` (2) | `echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/review-source-resolve.sh` (3) | `if _p2_state_root=$(bash "$_p2_script_dir/../hooks/state-path-resolve.sh" "$PWD" 2>/dev/null) && [ -n "$_p2_state_root" ]; then` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `scripts/review-source-resolve.sh` (4) | `echo "WARNING: review-source-resolve: state-path-resolve.sh の解決に失敗。cwd 相対の .rite/review-results へフォールバックします" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/review-source-resolve.sh` (5) | `if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `scripts/review-source-resolve.sh` (6) | `echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/watchdog-status-mismatch.sh` (1) | `_git_or_line=$(bash "$PLUGIN_ROOT/hooks/scripts/lib/git-remote.sh" resolve-owner-repo 2>"${git_remote_err:-/dev/null}") ¦¦ _git_or_line=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/watchdog-status-mismatch.sh` (2) | `if ! REPO_INFO=$(gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `scripts/watchdog-status-mismatch.sh` (3) | `echo "ERROR: gh repo view failed" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `scripts/watchdog-status-mismatch.sh` (4) | `echo "ERROR: failed to parse owner/name from gh repo view (owner='$REPO_OWNER' name='$REPO_NAME')" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |

## Hook の個別一覧

| 配布内パス・出現順 | 式 | 分類 | 壊れる／壊れないの判定 | 根拠・除外理由 |
|---|---|---|---|---|
| `hooks/_validate-helpers.sh` (1) | `state-path-resolve.sh` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/_validate-state-root.sh` (1) | `echo "  対処: caller (state-path-resolve.sh / pwd 由来 path) を経由して正規化された path を渡してください。" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/_validate-state-root.sh` (2) | `echo "  対処: caller (state-path-resolve.sh / pwd 由来 path) を経由して正規化された path を渡してください。" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/cleanup-work-memory.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)") ¦¦ exit 1` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/flow-state.sh` (1) | `source "$SCRIPT_DIR/state-path-resolve.sh"` | S | 呼出し対象外 | 関数定義をsourceするだけ。解決操作はstate-path-resolve本体の行で分類 |
| `hooks/host-runtime.sh` (1) | `STATE_ROOT=$(bash "$SCRIPT_DIR/state-path-resolve.sh" "$CWD")` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/host-runtime.sh` (2) | `CURRENT_BRANCH=$(git -C "$CWD" branch --show-current)` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/host-runtime.sh` (3) | `CURRENT_COMMIT=$(git -C "$CWD" rev-parse --short HEAD)` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/issue-body-safe-update.sh` (1) | `_git_or_line=$(bash "$SCRIPT_DIR/scripts/lib/git-remote.sh" resolve-owner-repo 2>"${_git_err:-/dev/null}") ¦¦ _git_or_line=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/issue-body-safe-update.sh` (2) | `_out=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>"${_err:-/dev/null}") ¦¦ _rc=$?` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/issue-body-safe-update.sh` (3) | `echo "${err_level:-WARNING}: issue-body-safe-update: owner/repo を解決できません (gh repo view rc=$_rc)。--repo なしで続行します（SSH host alias 環境では gh 呼び出しが失敗する可能性があります）" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/issue-claim.sh` (1) | `source "$SCRIPT_DIR/state-path-resolve.sh"` | S | 呼出し対象外 | 関数定義をsourceするだけ。解決操作はstate-path-resolve本体の行で分類 |
| `hooks/issue-comment-wm-sync.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") ¦¦ exit 1` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/issue-comment-wm-sync.sh` (2) | `_git_or_line=$(cd "$STATE_ROOT" 2>/dev/null && bash "$SCRIPT_DIR/scripts/lib/git-remote.sh" resolve-owner-repo 2>"${_git_err:-/dev/null}") ¦¦ _git_or_line=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/issue-comment-wm-sync.sh` (3) | `_out=$(cd "$STATE_ROOT" 2>/dev/null && gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>"${_err:-/dev/null}") ¦¦ _rc=$?` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/issue-comment-wm-sync.sh` (4) | `echo "[rite] WARNING: issue-comment-wm-sync: gh repo view failed (rc=$_rc)" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/post-compact.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") ¦¦ exit 0` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/post-compact.sh` (2) | `repo_view_err=$(mktemp "${TMPDIR:-/tmp}/rite-pc-repo-err-XXXXXX") ¦¦ { repo_view_err=""; stderr_capture_disabled=1; echo "[rite] WARNING: post-compact: mktemp failed for repo_view_err; gh repo view stderr will not be captured" >&2; }` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/post-compact.sh` (3) | `_git_or_line=$(cd "$STATE_ROOT" 2>/dev/null && bash "$SCRIPT_DIR/scripts/lib/git-remote.sh" resolve-owner-repo 2>"${git_remote_err:-/dev/null}") ¦¦ _git_or_line=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/post-compact.sh` (4) | `"TOCTOU cd failure must be distinguished from gh repo view failure inside the same subshell") ¦¦ _ri_cd_err=""` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/post-compact.sh` (5) | `if REPO_INFO=$(cd "$STATE_ROOT" 2>"${_ri_cd_err:-/dev/null}" && gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/post-compact.sh` (6) | `echo "[rite] ⚠️ post-compact: gh repo view failed or parse empty — reconciliation safety net unavailable" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/post-compact.sh` (7) | `echo "[rite] WARNING: post-compact: Issue #$ISSUE — cd STATE_ROOT failed inside gh repo view subshell (rc=${repo_rc:-NA}, stderr=$ri_cd_err_oneline); TOCTOU race between -d check and cd (state_root_toctou_race)" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/post-compact.sh` (8) | `echo "[rite] WARNING: post-compact: Issue #$ISSUE — gh repo view failed (rc=${repo_rc:-NA}, stderr=${repo_err_oneline:-NA}, git_remote_stderr=${git_remote_err_oneline:-NA}); PR Status reconciliation could not run (post_compact_gh_repo_view_failed)" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/post-compact.sh` (9) | `echo "[rite] WARNING: post-compact: Issue #$ISSUE — gh repo view returned null fields (owner=$REPO_OWNER name=$REPO_NAME jq_owner_stderr=$jq_owner_err_oneline jq_name_stderr=$jq_name_err_oneline); PR Status reconciliation could not run (post_compact_gh_repo_view_returned_null)" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/post-tool-wm-sync.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") ¦¦ exit 0` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/post-tool-wm-sync.sh` (2) | `_sym=$(git -C "$CWD" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) ¦¦ _sym=""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/post-tool-wm-sync.sh` (3) | `_diff_raw=$(git -C "$CWD" diff --name-status "origin/${_base_branch}...HEAD" 2>"${_git_diff_err:-/dev/null}") ¦¦ _diff_rc=$?` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/pre-compact.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") ¦¦ exit 0` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/pre-tool-bash-guard.sh` (1) | `BLOCKED_ALTERNATIVE="Read-only inspection stays allowed: 'git config --list', 'git config --get <key>', 'cat .git/config', 'git rev-parse --symbolic-full-name HEAD', 'git remote -v', 'git ls-remote'. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement)."` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/pre-tool-bash-guard.sh` (2) | `BLOCKED_ALTERNATIVE="Reviewers are strictly read-only — never write into .git. To INSPECT it, read instead: 'cat .git/config', 'git config --list', 'git cat-file -p <obj>', 'git show <ref>:<file>', 'git rev-parse'. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement)."` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/pre-tool-bash-guard.sh` (3) | `_mrg_root=$(bash "$SCRIPT_DIR/state-path-resolve.sh" 2>/dev/null) ¦¦ _mrg_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/pre-tool-bash-guard.sh` (4) | `BLOCKED_ALTERNATIVE="Retry the command. If it is denied again, run a literal git commit, or git -C <worktree> commit, in its own Bash call, with a long message written to a file and passed by git commit -F <message-file>."` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/pre-tool-bash-guard.sh` (5) | `BLOCKED_ALTERNATIVE="Run a literal git commit, or git -C <worktree> commit, in its own Bash call. Do not hide the worktree in a variable."` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/pre-tool-bash-guard.sh` (6) | `_co_root=$(bash "$SCRIPT_DIR/state-path-resolve.sh" "${CLAUDE_PROJECT_DIR:-$_co_cwd}" 2>/dev/null) ¦¦ _co_root=""` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/pre-tool-bash-guard.sh` (7) | `_audit_root=$(bash "$SCRIPT_DIR/state-path-resolve.sh" 2>/dev/null) ¦¦ _audit_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/pre-tool-edit-guard.sh` (1) | `TARGET_ROOT=$(git -C "$_tdir" rev-parse --show-toplevel 2>/dev/null) ¦¦ TARGET_ROOT=""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/pre-tool-edit-guard.sh` (2) | `if [ "$(git -C "$_tdir" rev-parse --is-inside-git-dir 2>/dev/null)" = "true" ]; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/pre-tool-edit-guard.sh` (3) | `_deny_reason="BLOCKED (reviewer-edit-git-dir): This subagent is treated as a reviewer (${TYPE_BASIS}), and reviewer subagents must not write into a Git internal directory. The ${TOOL_NAME} tool targeted '${ABS_PATH}', which is inside a .git directory. Writing there — .git/hooks/*, .git/config (core.hooksPath / alias / core.fsmonitor), etc. — can execute arbitrary code in the non-sandboxed main session on the next git operation. Reviewers are strictly read-only: inspect refs/blobs with 'git show', 'git cat-file', 'git rev-parse' instead. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement)."` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/pre-tool-edit-guard.sh` (4) | `_deny_reason="BLOCKED (reviewer-edit-parent-tree): This subagent is treated as a reviewer (${TYPE_BASIS}), and reviewer subagents must not mutate the parent working tree. The ${TOOL_NAME} tool targeted '${ABS_PATH}', which resolves inside the repository working tree (${TARGET_ROOT}). Reviewers are strictly read-only — inspect files with Read/Grep and compare historical content with 'git show <ref>:<file>'. If you need a mutation/verification experiment, do it in an isolated detached worktree under \$TMPDIR: run 'bash ${SCRIPT_DIR}/session-identity.sh' on its own to get your session ID, then 'mktemp -d -t rite-review-mutation-owner.<that session ID>.XXXXXX' on its own, then in a separate Bash call run 'git worktree add --detach <that literal path> HEAD' and edit files THERE (a real worktree whose root is named rite-review-mutation-* / rite-revert-test-* is allowed). See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement / Mutation experiments)."` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/release-promotion-verify.sh` (1) | `owner_repo_tab=$(bash "$SCRIPT_DIR/scripts/lib/git-remote.sh" resolve-owner-repo 2>/dev/null) ¦¦ owner_repo_tab=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/release-promotion-verify.sh` (2) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/release-promotion-verify.sh` (3) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/release-promotion-verify.sh` (4) | `state_root=$(bash "$SCRIPT_DIR/state-path-resolve.sh")` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/review-result-save.sh` (1) | `_state_root=$("$_save_script_dir/state-path-resolve.sh" "$PWD") ¦¦ {` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/review-skip-notification.sh` (1) | `if _notif_state_root=$("$_notif_script_dir/state-path-resolve.sh" 2>/dev/null) && [ -n "$_notif_state_root" ]; then` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/review-skip-notification.sh` (2) | `echo "WARNING: state-path-resolve.sh の解決に失敗。cwd 相対パスで表示します" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/backlink-format-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/backlink-format-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/bang-backtick-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/bang-backtick-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/bang-backtick-edit-hook.sh` (1) | `REPO_ROOT=$(cd "$CWD" && git rev-parse --show-toplevel 2>/dev/null) ¦¦ REPO_ROOT="$CWD"` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/bang-backtick-edit-hook.sh` (2) | `REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/bash-heaviness-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/bash-heaviness-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/cleanup-deferred-branch-recovery.sh` (1) | `branch_wt=$(git worktree list --porcelain 2>/dev/null ¦ awk -v wanted="refs/heads/$branch" '` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/cleanup-deferred-branch-recovery.sh` (2) | `shared_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ shared_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/cleanup-deferred-branch-recovery.sh` (3) | `[ -n "$shared_root" ] ¦¦ shared_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ shared_root=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/cleanup-deferred-branch-recovery.sh` (4) | `echo "WARNING: ローカルブランチ $branch の作業ツリーは reaper の dirty gate を通過できないため recovery=manual です。まず git -C $wt_q status --short で確認し、変更を commit / stash / copy してください。clean を確認した後だけ実行: git worktree remove $wt_q && git worktree prune && git branch -D -- $branch_q" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/cleanup-deferred-branch-recovery.sh` (5) | `echo "WARNING: ローカルブランチ $branch の作業ツリーを解決できないため recovery=manual です。git worktree list --porcelain で branch refs/heads/$branch の実パスを特定し、変更を保全して clean を確認するまで削除しないでください。" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/cleanup-follow-up-issue.sh` (1) | `elif ! git -C "$STATE_ROOT" cat-file -e "${pr_head}^{commit}" 2>"$head_err"; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/cleanup-follow-up-issue.sh` (2) | `if [ -n "$sha" ] && { [ "$sha" = "$head_sha" ] ¦¦ git -C "$STATE_ROOT" diff --quiet --end-of-options "$sha" "$head_sha" -- "${k_loc%:*}" 2>/dev/null; }; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/cleanup-pr-state-purge.sh` (1) | `state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` (1) | `cur_top=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ cur_top=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` (2) | `wt_list=$(git worktree list --porcelain 2>/dev/null) ¦¦ wt_list_rc=$?` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` (3) | `echo "WARNING: git worktree list が rc=${wt_list_rc} で失敗しました。未記録の作業ツリーの有無を確認できていません" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` (4) | `echo "WARNING: sandbox が作業ツリーの管理ディレクトリ（${_wt_admin}/${_masked_file}）にマスクマウントを張っているため、削除を見送りました。この状態で git worktree remove を実行すると管理ディレクトリが半壊するため、削除自体を試行しません。次回のセッション開始時（sandbox 外）に作業ツリーとローカルブランチが自動で回収されます。実行エージェントはこの場で sandbox を無効化して remove を再試行しないこと。" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` (5) | `if LC_ALL=C git worktree remove "$flow_wt" 2>"${_wt_rm_err:-/dev/null}" \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` (6) | `¦¦ LC_ALL=C git worktree remove --force "$flow_wt" 2>"${_wt_rm_err:-/dev/null}"; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` (7) | `git worktree prune 2>/dev/null ¦¦ true` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/cleanup-session-worktree-teardown.sh` (8) | `echo "WARNING: worktree 削除が「Device or resource busy」で失敗しました。Claude Code の sandbox が worktree の .git/worktrees/*/config.worktree・commondir に read-only bind mount を張っている環境では、sandbox 内からの git worktree remove（--force 含む）は構造的に失敗します。この失敗は意図的に non-blocking として遅延 reap（pr-cycle-cleanup.sh）へ委譲するため、実行エージェントはこの場で sandbox を無効化して同コマンドを再試行しないこと。復旧: ユーザーが sandbox 外のシェルで次を実行してください: git worktree remove --force $_q_flow_wt && git worktree prune" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/comment-journal-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/comment-journal-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/comment-line-ref-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/comment-line-ref-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/commit-convention-locate.sh` (1) | `worktree=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ worktree=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/commit-convention-locate.sh` (2) | `shared=$("$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ shared=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/dollar-zero-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/dollar-zero-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/fix-reason-coverage-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/fix-reason-coverage-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/fix-report-diff-gate.sh` (1) | `_state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/fix-report-diff-gate.sh` (2) | `REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ REPO_ROOT=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/fix-report-diff-gate.sh` (3) | `if ! git -C "$REPO_ROOT" cat-file -e "${before}^{commit}" 2>/dev/null; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/fix-report-diff-gate.sh` (4) | `if ! git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/fix-report-diff-gate.sh` (5) | `if ! diff_out=$(git -C "$REPO_ROOT" diff -U0 "${before}..HEAD" 2>"$diff_err"); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/git-commit-file.sh` (1) | `tree=$(git rev-parse --show-toplevel) ¦¦ {` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/git-commit-file.sh` (2) | `old_head=$(git -C "$tree" rev-parse HEAD)` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/gitignore-health-check.sh` (1) | `--repo-root DIR                   Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/gitignore-health-check.sh` (2) | `REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ {` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/gitignore-health-check.sh` (3) | `echo "ERROR: not inside a git repository (git rev-parse --show-toplevel failed)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/gitignore-health-check.sh` (4) | `state_root=$(bash "$_GHC_HOOKS_DIR/state-path-resolve.sh") ¦¦ state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/gitignore-health-check.sh` (5) | `echo "WARNING: gitignore-health-check: state-path-resolve.sh failed" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/hardcoded-line-number-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/hardcoded-line-number-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/git-remote.sh` (1) | `url=$(git config --get remote.origin.url 2>/dev/null)` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/scripts/lib/git-remote.sh` (2) | `echo "ERROR: git-remote.sh: unknown subcommand '${1:-}' (expected: resolve-owner-repo)" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/rite-config-path.sh` (1) | `top=$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) ¦¦ top=""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/rite-config-path.sh` (2) | `resolver="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/state-path-resolve.sh"` | 対象外 | 呼出し対象外（配布パス探索） | 実行中helperの配布パスからresolverのファイル名を組み立てる式。state rootの解決は後続のresolver呼出しが明示したdirで行う |
| `hooks/scripts/lib/rite-config-path.sh` (3) | `printf 'main checkout root を解決できません (state-path-resolve.sh rc=%s, dir=%s)\n' "$rc" "$dir" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (1) | `wt_head=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>"${rev_parse_err:-/dev/null}")` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (2) | `echo "ERROR: git -C '$worktree' rev-parse --abbrev-ref HEAD が失敗しました (rc=$wt_head_rc)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (3) | `echo " 対処: git worktree remove $_q_worktree && bash $_q_setup_sh" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (4) | `echo " hint: git -C $_q_worktree checkout $_q_expected_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (5) | `if ! git_dir=$(git -C "$tree" rev-parse --absolute-git-dir 2>&1); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (6) | `echo "ERROR: git -C '$tree' rev-parse --absolute-git-dir が失敗しました: $git_dir" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (7) | `if ! git -C "$worktree" add -- "$@" 2>"${add_err:-/dev/null}"; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (8) | `git -C "$worktree" diff --cached --quiet 2>"${diff_err:-/dev/null}"` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (9) | `if ! git -C "$worktree" commit --quiet -F "$msg_file" 2>"${commit_err:-/dev/null}"; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (10) | `if head_sha=$(git -C "$worktree" rev-parse HEAD 2>"${head_err:-/dev/null}"); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (11) | `echo "WARNING: git -C '$worktree' rev-parse HEAD failed post-commit (rc=$head_rc)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (12) | `if head_sha=$(git -C "$worktree" rev-parse HEAD 2>"${head_err:-/dev/null}"); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (13) | `echo "WARNING: git -C '$worktree' rev-parse HEAD failed (rc=$head_rc)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (14) | `if ahead_count=$(git -C "$worktree" rev-list "origin/${branch}..${branch}" --count 2>/dev/null) \` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (15) | `if git -C "$worktree" push --quiet origin "$branch" 2>"${push_err:-/dev/null}"; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (16) | `echo " manual recovery: git -C $_q_worktree push origin $_q_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (17) | `echo " manual recovery: git -C $_q_worktree fetch origin $_q_branch && git -C $_q_worktree rebase $_q_origin_branch && git -C $_q_worktree push origin $_q_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (18) | `if ! git -C "$worktree" fetch --quiet origin "$branch" 2>"${push_err:-/dev/null}"; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (19) | `if ! git -C "$worktree" rebase --quiet "origin/$branch" 2>"${push_err:-/dev/null}"; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (20) | `git -C "$worktree" rebase --abort 2>/dev/null ¦¦ true` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (21) | `echo " manual recovery: git -C $_q_worktree fetch origin $_q_branch && git -C $_q_worktree rebase $_q_origin_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (22) | `git_common=$(git rev-parse --git-common-dir 2>/dev/null) ¦¦ {` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (23) | `cur_top=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ cur_top=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (24) | `registered=$(git worktree list --porcelain 2>/dev/null ¦ awk -v p="$wt_path" '$1=="worktree" && $2==p {print "yes"}')` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (25) | `git worktree prune >/dev/null 2>&1 ¦¦ true` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (26) | `branch_wt=$(git worktree list --porcelain 2>/dev/null ¦ awk -v b="refs/heads/$branch" '` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (27) | `if ! dirty=$(git -C "$main_root" status --porcelain 2>/dev/null); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (28) | `if ! switch_err=$(git -C "$main_root" switch --no-guess -- "$base" 2>&1); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/lib/worktree-git.sh` (29) | `git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 && branch_local=yes` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (30) | `git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1 && branch_remote=yes` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (31) | `if git worktree add "$wt_path" "$branch" 1>&2; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (32) | `echo "ERROR: ensure_session_worktree: git worktree add '$wt_path' '$branch' failed (issue #$issue)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (33) | `echo "  recovery: restart Claude Code from the repo root, or run: git worktree add $_q_wt_path $_q_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/lib/worktree-git.sh` (34) | `if git worktree add --track -b "$branch" "$wt_path" "origin/$branch" 1>&2; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/lib/worktree-git.sh` (35) | `echo "ERROR: ensure_session_worktree: git worktree add --track -b '$branch' '$wt_path' 'origin/$branch' failed (issue #$issue)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/nb-sweep-collect.sh` (1) | `owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner') ¦¦ collect_fail repo_unresolved` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/scripts/number-reference-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/number-reference-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ¦¦ {` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/number-reference-check.sh` (3) | `if ! git rev-parse --verify "${base}^{commit}" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/orphan-reference-check.sh` (1) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/post-review-state-verify.sh` (1) | `b="DETACHED:$(git rev-parse --short HEAD 2>/dev/null ¦¦ echo unknown)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/post-review-state-verify.sh` (2) | `top=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ return 1` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/post-review-state-verify.sh` (3) | `echo "WARNING: git rev-parse / for-each-ref failed — branch_list drift axis skipped for this check" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (1) | `if ! git rev-parse --show-toplevel >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (2) | `repo_root=$("$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ repo_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (3) | `[ -n "$repo_root" ] ¦¦ repo_root=$(git rev-parse --show-toplevel)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (4) | `echo "ERROR: empty repo_root (git rev-parse race / permission change の可能性)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (5) | `if wt_list=$(git worktree list --porcelain 2>"${wt_list_err:-/dev/null}"); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (6) | `if wt_rm_err=$(git worktree remove --force "$current_path" 2>&1); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (7) | `echo "WARNING: git worktree list --porcelain が失敗しました (rc=$wt_rc)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (8) | `if git worktree prune 2>"${prune_err:-/dev/null}"; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (9) | `echo "WARNING: git worktree prune が失敗しました (rc=$prune_rc)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (10) | `if wt_err=$(git worktree remove --force "$orphan" 2>&1); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (11) | `echo "  git worktree remove --force:" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (12) | `git worktree prune 2>/dev/null ¦¦ true` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (13) | `if ! git rev-parse --verify --quiet "refs/heads/$_m_val" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (14) | `[ "$DRY_RUN" = "0" ] && git worktree prune 2>/dev/null ¦¦ true` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (15) | `if _m_st=$(git -C "$_m_val" status --porcelain 2>/dev/null); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/pr-cycle-cleanup.sh` (16) | `elif git worktree remove --force -- "$_m_val" 2>/dev/null ¦¦ rm -rf -- "$_m_val" 2>/dev/null; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (17) | `git worktree prune 2>/dev/null ¦¦ true` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (18) | `if _p_list=$(git worktree list --porcelain 2>"${_p_list_err:-/dev/null}"); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (19) | `_p_head=$(git -C "$_p_path" rev-parse HEAD 2>/dev/null) ¦¦ _p_head=""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/pr-cycle-cleanup.sh` (20) | `elif ! _p_refs=$(git -C "$_p_path" for-each-ref --contains="$_p_head" --format='%(refname)' 2>/dev/null); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/pr-cycle-cleanup.sh` (21) | `git worktree prune 2>/dev/null ¦¦ true` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (22) | `echo "WARNING: Step 4-P git worktree list --porcelain が失敗しました (rc=$_p_rc)。detached TMPDIR 回収を skip します" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (23) | `_common=$(git rev-parse --git-common-dir 2>/dev/null) ¦¦ _common=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (24) | `&& ! git -C "$wt_path" rev-parse --git-dir >/dev/null 2>&1; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/pr-cycle-cleanup.sh` (25) | `echo "  手動確認: git -C $_q_wt_path status / 不要なら git worktree remove $_q_wt_path" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (26) | `_wt_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null) ¦¦ _wt_branch=""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/pr-cycle-cleanup.sh` (27) | `_reaped_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null) ¦¦ _reaped_branch=""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/pr-cycle-cleanup.sh` (28) | `if git worktree remove --force "$wt_path" 2>/dev/null ¦¦ rm -rf "$wt_path" 2>/dev/null; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (29) | `echo "WARNING: corpse admin dir '$(printf '%s' "$_admin_dir" ¦ neutralize_ctrl)' の削除に失敗しました。手動回収: rm -rf $_q_admin_dir && git worktree prune" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (30) | `echo "WARNING: corpse session worktree '$(printf '%s' "$wt_path" ¦ neutralize_ctrl)' の回収に失敗しました。手動回収: rm -rf $_q_wt_path $_q_admin_dir && git worktree prune" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/pr-cycle-cleanup.sh` (31) | `git worktree list --porcelain 2>/dev/null ¦¦ true` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (32) | `_listed=$(git worktree list --porcelain 2>/dev/null ¦¦ true)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (33) | `git worktree prune 2>/dev/null ¦¦ true` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/pr-cycle-cleanup.sh` (34) | `if _or_line=$(bash "$SCRIPT_DIR/lib/git-remote.sh" resolve-owner-repo 2>/dev/null); then` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/scripts/projects-board-drift-check.sh` (1) | `_git_or_line=$(bash "$SCRIPT_DIR/lib/git-remote.sh" resolve-owner-repo 2>"${git_remote_err:-/dev/null}") ¦¦ _git_or_line=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/scripts/projects-board-drift-check.sh` (2) | `if ! REPO_INFO=$(gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/scripts/projects-board-drift-check.sh` (3) | `echo "ERROR: gh repo view failed" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/projects-board-drift-check.sh` (4) | `echo "ERROR: failed to parse owner/name from gh repo view (owner='$REPO_OWNER' name='$REPO_NAME')" >&2` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/projects-status-gate.sh` (1) | `_git_or_line=$(bash "$SCRIPT_DIR/lib/git-remote.sh" resolve-owner-repo 2>"$git_remote_err") ¦¦ _git_or_line=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/scripts/projects-status-gate.sh` (2) | `if ! REPO_INFO=$(gh repo view --json owner,name 2>"$repo_view_err"); then` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/scripts/projects-status-gate.sh` (3) | `warn "gh repo view failed; cannot verify board Status"` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/projects-status-gate.sh` (4) | `warn "failed to parse owner/name from gh repo view"` | R | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/ready-pr-head-gate.sh` (1) | `if ! git worktree remove --force "$cleanup_path" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/ready-pr-head-gate.sh` (2) | `current_oid=$(git rev-parse HEAD) ¦¦ { echo "ERROR: Ready gate: 現在の HEAD を解決できません" >&2; exit 2; }` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/ready-pr-head-gate.sh` (3) | `git worktree add --detach "$ready_gate_tmp" "$pr_head_oid" >/dev/null 2>&1 ¦¦ { echo "ERROR: Ready gate: PR head $pr_head_oid の一時 worktree 作成に失敗しました" >&2; exit 2; }` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/ready-reviewed-head-gate.sh` (1) | `[ -x "$plugin_root/hooks/state-path-resolve.sh" ] ¦¦ {` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/ready-reviewed-head-gate.sh` (2) | `echo "ERROR: Ready reviewed-head gate: state-path-resolve.sh not found. 照合不能のため Ready 化を拒否します。" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/ready-reviewed-head-gate.sh` (3) | `results_dir=$(bash "$plugin_root/hooks/state-path-resolve.sh")/.rite/review-results ¦¦ {` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/ready-reviewed-head-gate.sh` (4) | `if [ -x "$plugin_root/hooks/state-path-resolve.sh" ]; then` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/ready-reviewed-head-gate.sh` (5) | `resolved_root=$(bash "$plugin_root/hooks/state-path-resolve.sh") ¦¦ resolved_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/review-adoption-gate.sh` (1) | `owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>"$work/err") ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `hooks/scripts/review-fix-scope-check.sh` (1) | `root=$(bash "$script_dir/../state-path-resolve.sh")` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/review-fix-scope-check.sh` (2) | `root=$(bash "$script_dir/../state-path-resolve.sh")` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/review-save-json-verify.sh` (1) | `--results-dir P   レビュー結果 JSON のディレクトリ (既定: state-path-resolve.sh 経由で解決)` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/review-save-json-verify.sh` (2) | `state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh") ¦¦ state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/review-save-json-verify.sh` (3) | `[ -n "$state_root" ] ¦¦ _degraded "state-path-resolve.sh がレビュー結果ディレクトリの root を解決できませんでした"` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/review-save-json-verify.sh` (4) | `actual_head=$(git rev-parse HEAD 2>/dev/null) \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/review-save-json-verify.sh` (5) | `¦¦ _degraded "helper の cwd で git rev-parse HEAD を実行できません。レビュー対象 HEAD を独立検証できません"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/review-schema-version-check.sh` (1) | `--repo-root DIR    Repository root (default: state-path-resolve.sh resolution;` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/review-schema-version-check.sh` (2) | `falls back to git rev-parse --show-toplevel with a WARNING)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/review-schema-version-check.sh` (3) | `if [ -z "$REPO_ROOT" ] && git rev-parse --show-toplevel >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/review-schema-version-check.sh` (4) | `if _check_state_root=$("$_check_script_dir/../state-path-resolve.sh" 2>/dev/null) && [ -n "$_check_state_root" ]; then` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/review-schema-version-check.sh` (5) | `echo "WARNING: state-path-resolve.sh の解決に失敗。git toplevel をフォールバック使用します" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/review-schema-version-check.sh` (6) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/review-trend-divergence.sh` (1) | `--results-dir P   レビュー結果 JSON のディレクトリ (既定: state-path-resolve.sh 経由で解決)` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/review-trend-divergence.sh` (2) | `_state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh") ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/review-trend-divergence.sh` (3) | `echo "WARNING: state-path-resolve.sh の解決に失敗。cwd 相対の .rite/review-results へフォールバックします" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/reviewer-registry-drift-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/reviewer-registry-drift-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/rite-tmp-artifact.sh` (1) | `repo_root=$("$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ repo_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/rite-tmp-artifact.sh` (2) | `[ -n "$repo_root" ] ¦¦ repo_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ repo_root=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/run-queue-reap.sh` (1) | `source "$HOOKS_DIR/state-path-resolve.sh"` | S | 呼出し対象外 | 関数定義をsourceするだけ。解決操作はstate-path-resolve本体の行で分類 |
| `hooks/scripts/sentinel-contract-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/sentinel-contract-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/sh-cross-ref-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/sh-cross-ref-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/skill-rail-diff-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel).` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/skill-rail-diff-check.sh` (2) | `REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ REPO_ROOT=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/skill-rail-diff-check.sh` (3) | `if ! git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF^{commit}" >/dev/null; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/skill-rail-diff-check.sh` (4) | `if ! base_blob=$(git -C "$REPO_ROOT" show "$BASE_REF:$REL_PATH" 2>/dev/null); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/tempfile-lifecycle-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/tempfile-lifecycle-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/tmp-hardcode-check.sh` (1) | `--repo-root DIR    Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/tmp-hardcode-check.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/triage-adoption-run.sh` (1) | `state_root=$(bash "$plugin_root/hooks/state-path-resolve.sh") && [ -n "$state_root" ] \` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/wiki-apply-advance-head.sh` (1) | `WORKTREE=$(git rev-parse --show-toplevel) ¦¦ _fail "作業ツリーを解決できません"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-apply-advance-head.sh` (2) | `FROM_SHA=$(git -C "$WORKTREE" rev-parse --verify -q "${FROM}^{commit}") ¦¦ _fail "--from を commit に解決できません: $FROM"` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-advance-head.sh` (3) | `HEAD_SHA=$(git -C "$WORKTREE" rev-parse --verify -q "HEAD^{commit}") ¦¦ _fail "HEAD を解決できません"` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-advance-head.sh` (4) | `ROOT=$(bash "$SCRIPT_DIR/../state-path-resolve.sh") ¦¦ _fail "state root を解決できません"` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/wiki-apply-capture.sh` (1) | `WT=$(git rev-parse --show-toplevel)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-apply-capture.sh` (2) | `ROOT=$(bash "$SCRIPT_DIR/../state-path-resolve.sh") ¦¦ { echo "ERROR: state root を解決できません" >&2; exit 1; }` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/wiki-apply-capture.sh` (3) | `PATHS=$(git -C "$WT" status --porcelain ¦ awk '{print $NF}' ¦ paste -sd, -)` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-capture.sh` (4) | `HEAD_SHA=$(git -C "$WT" rev-parse HEAD) ¦¦ { echo "ERROR: HEAD を読めません" >&2; exit 1; }` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-capture.sh` (5) | `&& git -C "$WT" cat-file -e "HEAD:$_wiki_path" 2>/dev/null; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-capture.sh` (6) | `_wiki_oid=$(readlink -- "$WT/$_wiki_path" ¦ tr -d '\n' ¦ git -C "$WT" hash-object --stdin) ¦¦ {` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-capture.sh` (7) | `_wiki_oid=$(git -C "$WT" hash-object -- "$_wiki_path") ¦¦ {` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-gate.sh` (1) | `WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ WORKTREE=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-apply-gate.sh` (2) | `ROOT=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ ROOT=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/wiki-apply-gate.sh` (3) | `if ! git -C "$WORKTREE" diff --cached --name-only >"$DIFF_DIR/staged" 2>>"$DIFF_DIR/err"; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-gate.sh` (4) | `git -C "$WORKTREE" diff --no-ext-diff --no-textconv --name-only "${BASE}...HEAD" >"$DIFF_DIR/names" 2>>"$DIFF_ERRF" ¦¦ DIFF_OK=0` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-apply-gate.sh` (5) | `git -C "$WORKTREE" diff --no-ext-diff --no-textconv "${BASE}...HEAD" >"$DIFF_DIR/text" 2>>"$DIFF_ERRF" ¦¦ DIFF_OK=0` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-branch-init.sh` (1) | `stash_before=$(git rev-parse -q --verify refs/stash) ¦¦ stash_before=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-branch-init.sh` (2) | `stash_sha=$(git rev-parse -q --verify refs/stash) ¦¦ stash_sha=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-growth-check.sh` (1) | `--repo-root DIR          Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-growth-check.sh` (2) | `REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ {` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-growth-check.sh` (3) | `echo "ERROR: not inside a git repository (git rev-parse --show-toplevel failed)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-growth-check.sh` (4) | `if git rev-parse --verify "$wiki_branch" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-growth-check.sh` (5) | `elif git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (1) | `if ! git rev-parse --show-toplevel >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (2) | `_convention_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ _convention_root=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (3) | `repo_root=$("$_SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ repo_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (4) | `[ -n "$repo_root" ] ¦¦ repo_root=$(git rev-parse --show-toplevel)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (5) | `printf ' manual recovery: git -C %q reset -q --%s\n' "$repo_root" "$(printf ' %q' "${pending_files[@]}")" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (6) | `head_sha=$(git rev-parse HEAD 2>/dev/null ¦¦ echo unknown)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (7) | `echo " 1) git -C $_q_repo_root fetch origin ${wiki_branch}:${wiki_branch} # fresh clone: create local branch from origin/${wiki_branch}" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (8) | `echo " hint: checkout a named branch first (e.g. git -C $_q_repo_root checkout develop)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (9) | `_stash_pop_hint="git -C $_q_repo_root stash pop \"\$(git -C $_q_repo_root stash list --format='%gd %H' ¦ awk -v s=$stash_sha '\$2 == s {print \$1}')\""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-ingest-commit.sh` (10) | `echo " manual recovery: git -C $_q_repo_root checkout $_q_current_branch && $_stash_pop_hint" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (11) | `echo " manual recovery: git -C $_q_repo_root checkout $_q_current_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (12) | `echo " manual recovery: git -C $_q_repo_root reset -q -- .rite/wiki/raw" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (13) | `echo " git -C $_q_repo_root stash list --format='%gd %H' ¦ grep $stash_sha" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (14) | `echo " 1) resolve the branch state: git -C $_q_repo_root checkout $_q_current_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (15) | `echo " 2) unstage raw sources carried over from the wiki branch: git -C $_q_repo_root reset -q -- .rite/wiki/raw" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (16) | `echo " 1) git -C $_q_repo_root rm --cached $_q_f" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-commit.sh` (17) | `stash_before=$(git rev-parse -q --verify refs/stash 2>/dev/null) ¦¦ stash_before=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (18) | `stash_sha=$(git rev-parse -q --verify refs/stash 2>/dev/null) ¦¦ stash_sha=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (19) | `committed_sha=$(git rev-parse HEAD 2>/dev/null ¦¦ echo unknown)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-ingest-commit.sh` (20) | `echo " manual recovery: git -C $_q_repo_root push origin $wiki_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-ingest-lock.sh` (1) | `source "$HOOKS_DIR/state-path-resolve.sh"` | S | 呼出し対象外 | 関数定義をsourceするだけ。解決操作はstate-path-resolve本体の行で分類 |
| `hooks/scripts/wiki-lint-broken-refs.sh` (1) | `--repo-root DIR             Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-lint-broken-refs.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-lint-descriptive-refs.sh` (1) | `--repo-root DIR             Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-lint-descriptive-refs.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-lint-descriptive-refs.sh` (3) | `if git rev-parse --verify -q "${wiki_branch}^{commit}" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-lint-open-contradictions.sh` (1) | `--repo-root DIR             Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-lint-open-contradictions.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-lint-orphans.sh` (1) | `--repo-root DIR             Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-lint-orphans.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-lint-skipped-refs.sh` (1) | `--repo-root DIR             Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-lint-skipped-refs.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-lint-source-refs.sh` (1) | `--repo-root DIR             Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-lint-source-refs.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-lint-stale.sh` (1) | `--repo-root DIR             Repository root (default: git rev-parse --show-toplevel)` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-lint-stale.sh` (2) | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null ¦¦ pwd)"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-numref-precommit.sh` (1) | `git -C "$numref_tree" add -N -- .rite/wiki ¦¦ numref_stage_rc=$?` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-numref-precommit.sh` (2) | `numref_ignored=$(git -C "$numref_tree" -c core.quotePath=false ls-files --others --ignored --exclude-standard -- .rite/wiki) ¦¦ numref_ig_rc=$?` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-numref-precommit.sh` (3) | `¦ git -C "$numref_tree" -c core.quotePath=false check-ignore -v --stdin) ¦¦ numref_ci_rc=$?` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-numref-precommit.sh` (4) | `echo "        手動: git -C $numref_tree check-ignore -v -- <上記のファイル>" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-commit.sh` (1) | `if ! git rev-parse --show-toplevel >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-commit.sh` (2) | `_convention_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ _convention_root=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-commit.sh` (3) | `repo_root=$("$_SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ repo_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/wiki-worktree-commit.sh` (4) | `[ -n "$repo_root" ] ¦¦ repo_root=$(git rev-parse --show-toplevel)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-commit.sh` (5) | `git -C "$worktree_path" diff --quiet -- "$wiki_rel"` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-worktree-commit.sh` (6) | `untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard -- "$wiki_rel" 2>"${lsf_err:-/dev/null}")` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-worktree-commit.sh` (7) | `echo "ERROR: git -C '$worktree_path' ls-files --others が失敗しました (rc=$lsf_rc)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-commit.sh` (8) | `git -C "$worktree_path" diff --cached --quiet -- "$wiki_rel"` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-worktree-commit.sh` (9) | `git -C "$worktree_path" diff --name-only -- "$wiki_rel" ¦ sed 's/^/ M /'` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-worktree-setup.sh` (1) | `if ! git rev-parse --show-toplevel >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-setup.sh` (2) | `repo_root=$("$_SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) ¦¦ repo_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/scripts/wiki-worktree-setup.sh` (3) | `[ -n "$repo_root" ] ¦¦ repo_root=$(git rev-parse --show-toplevel)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-setup.sh` (4) | `echo "    1) git -C $_q_repo_root fetch origin ${wiki_branch}:${wiki_branch}" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (5) | `if wt_list=$(git worktree list --porcelain 2>"${wt_list_err:-/dev/null}"); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-setup.sh` (6) | `echo "WARNING: git worktree list --porcelain が失敗しました (rc=$wt_list_rc)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (7) | `echo "  影響: idempotency check が空結果として進み、後段の git worktree add で初めて顕在化する可能性" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (8) | `echo "  自動回復: git worktree prune で metadata を整理してから worktree を再作成します" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (9) | `if ! git worktree prune 2>"${wt_list_err:-/dev/null}"; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-setup.sh` (10) | `echo "ERROR: git worktree prune に失敗しました" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (11) | `echo "  手動回復: git worktree prune を直接実行してから本 script を再実行してください" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (12) | `echo "  manual recovery: git worktree remove $_q_target_path && re-run this script" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (13) | `if [ -e "$target_path" ] && ! git -C "$target_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/scripts/wiki-worktree-setup.sh` (14) | `echo "WARNING: '$abs_target' は git worktree として解決できない残留ディレクトリです (stale .git gitdir — リポジトリ移動/コピー後に発生)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (15) | `echo "  自動回復: 残留を削除し git worktree prune してから worktree を再作成します" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (16) | `if ! git worktree prune 2>"${prune_err:-/dev/null}"; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-setup.sh` (17) | `echo "WARNING: git worktree prune に失敗しました (stale metadata が残存する可能性があります)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (18) | `echo "WARNING: mktemp for add_err failed — git worktree add stderr will not be captured for diagnostics" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (19) | `if ! git worktree add --quiet "$target_path" "$wiki_branch" 2>"${add_err:-/dev/null}"; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/scripts/wiki-worktree-setup.sh` (20) | `echo "ERROR: git worktree add '$target_path' '$wiki_branch' failed" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/scripts/wiki-worktree-setup.sh` (21) | `echo "  hint: ensure the wiki branch is not already checked out elsewhere (git worktree list)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/session-end.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") ¦¦ exit 0` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/session-start.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") ¦¦ exit 0` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/session-start.sh` (2) | `if _git_common=$(cd "$CWD" && _gc=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$_gc" && pwd -P); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/state-path-resolve.sh` (1) | `root=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null) ¦¦ true` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/state-path-resolve.sh` (2) | `common=$(cd "$cwd" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ¦¦ common=""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/state-path-resolve.sh` (3) | `common_rel=$(cd "$cwd" && git rev-parse --git-common-dir 2>/dev/null) ¦¦ common_rel=""` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/stop-failure.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") ¦¦ {` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/stop-loop-continuation.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD") ¦¦ exit 0` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/wiki-ingest-trigger.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$PWD") ¦¦ exit 1` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/wiki-ingest-trigger.sh` (2) | `echo "NOTE: raw source を state-path-resolve ルート '$STATE_ROOT' 配下へ書き込みます (cwd='$PWD' とは別 — multi-session worktree / サブディレクトリ起動)。wiki-ingest-commit.sh の scan ルートと一致させる整合動作です。" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/wiki-query-inject.sh` (1) | `STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$PWD") ¦¦ exit 1` | S | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `hooks/wiki-query-inject.sh` (2) | `if git rev-parse --verify "$wiki_branch" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/wiki-query-inject.sh` (3) | `elif git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/wiki-query-inject.sh` (4) | `rev=$(git rev-parse "${ref}:.rite/wiki/${p}" 2>/dev/null) ¦¦ rev=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `hooks/work-memory-update.sh` (1) | `if [ -z "${WM_PLUGIN_ROOT:-}" ] ¦¦ [ ! -x "${WM_PLUGIN_ROOT}/hooks/state-path-resolve.sh" ]; then` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/work-memory-update.sh` (2) | `echo "rite: ${WM_SOURCE:-work-memory-update}: state-path-resolve.sh not found" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `hooks/work-memory-update.sh` (3) | `state_root=$(bash "${WM_PLUGIN_ROOT}/hooks/state-path-resolve.sh") ¦¦ _sr_rc=$?` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `hooks/work-memory-update.sh` (4) | `last_commit=$(git rev-parse --short HEAD 2>/dev/null ¦¦ echo "")` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |

## Skill の実行 block の個別一覧

| 配布内パス・出現順 | 式 | 分類 | 壊れる／壊れないの判定 | 根拠・除外理由 |
|---|---|---|---|---|
| `skills/batch-run/SKILL.md` (1) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/batch-run/SKILL.md` (2) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/batch-run/SKILL.md` (3) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/batch-run/SKILL.md` (4) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/batch-run/SKILL.md` (5) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/batch-run/SKILL.md` (6) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/batch-run/SKILL.md` (7) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/cleanup/SKILL.md` (1) | `owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/cleanup/SKILL.md` (2) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/cleanup/SKILL.md` (3) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/cleanup/SKILL.md` (4) | `_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/cleanup/SKILL.md` (5) | `echo "WARNING: state-path-resolve.sh の解決に失敗（空/非ゼロ）。cwd には倒さず Issue コメント側へ fallback します" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `skills/cleanup/SKILL.md` (6) | `cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) ¦¦ cur_branch=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/cleanup/SKILL.md` (7) | `_head_rev=$(git rev-parse HEAD 2>/dev/null); _head_rc=$?` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/cleanup/SKILL.md` (8) | `_base_rev=$(git rev-parse "origin/{base_branch}" 2>/dev/null); _base_rc=$?` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/cleanup/SKILL.md` (9) | `_bu_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ _bu_root=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/cleanup/SKILL.md` (10) | `git diff --name-only --no-relative -z HEAD 2>/dev/null ¦ xargs -0 -r git -C "$_bu_root" diff --quiet "origin/{base_branch}" -- 2>/dev/null; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `skills/cleanup/SKILL.md` (11) | `_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/cleanup/SKILL.md` (12) | `[ -n "$_state_root" ] ¦¦ { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/cleanup/SKILL.md` (13) | `_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/cleanup/SKILL.md` (14) | `_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ _state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/cleanup/SKILL.md` (15) | `[ -n "$_state_root" ] ¦¦ { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/cleanup/SKILL.md` (16) | `git rev-parse --verify "$wiki_branch" >/dev/null 2>&1 && ref="$wiki_branch"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/cleanup/SKILL.md` (17) | `[ -z "$ref" ] && git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1 && ref="origin/$wiki_branch"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/getting-started/SKILL.md` (1) | `gh repo view --json owner,name` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/issue-audit/SKILL.md` (1) | `bash {plugin_root}/hooks/state-path-resolve.sh` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/issue-cancel/SKILL.md` (1) | `_wt_list=$(git worktree list --porcelain) ¦¦ _list_rc=$?` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/issue-cancel/SKILL.md` (2) | `echo "ERROR: git worktree list に失敗しました (rc=${_list_rc})。対象 worktree の有無を確認できないため中止します" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `skills/issue-cancel/SKILL.md` (3) | `cur_top=$(git rev-parse --show-toplevel) ¦¦ cur_top=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/issue-create/SKILL.md` (1) | `owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/issue-create/SKILL.md` (2) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/issue-create/SKILL.md` (3) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/issue-implement/SKILL.md` (1) | `git worktree list --porcelain` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/issue-implement/SKILL.md` (2) | `git worktree add {worktree_base}/{issue_number}/{task_id} -b {branch_name}/{task_id} {branch_name}` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/issue-implement/SKILL.md` (3) | `git worktree remove {worktree_base}/{issue_number}/{task_id}` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/issue-implement/SKILL.md` (4) | `echo "RESUME_HINT: flow-state.sh が異常 exit (rc=$rc) しました。ファイル不在/empty/jq parse 失敗は --default で吸収 (exit 0) されるため、本経路は helper validation 失敗 / --field 引数欠落 / invalid field name 等の caller 側引数異常で発火します。\$PLUGIN_ROOT/hooks/_validate-helpers.sh と state-path-resolve.sh の存在/実行権限を確認し、必要なら /rite:recover で再開、または STATE_ROOT 配下の sessions/ を確認してください。" >&2` | S | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `skills/learn/SKILL.md` (1) | `git rev-parse --verify {base_branch} 2>/dev/null \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/learn/SKILL.md` (2) | `¦¦ git rev-parse --verify origin/{base_branch} 2>/dev/null` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/lint/SKILL.md` (1) | `owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/lint/SKILL.md` (2) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/lint/SKILL.md` (3) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/lint/SKILL.md` (4) | `git rev-parse --verify "${number_ref_diff_base}^{commit}" >/dev/null 2>&1 ¦¦ number_ref_diff_base="{base_branch}"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/merge/SKILL.md` (1) | `state_root=$(bash "{plugin_root}/hooks/state-path-resolve.sh" 2>/dev/null) ¦¦ state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/open/SKILL.md` (1) | `cur_top=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ cur_top=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/open/SKILL.md` (2) | `repo_root=$(git rev-parse --show-toplevel)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/open/SKILL.md` (3) | `if _dirty_files=$(git -C "$repo_root" status --porcelain 2>/dev/null); then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `skills/open/SKILL.md` (4) | `wt_registered=$(git worktree list --porcelain ¦ awk -v p="$wt_path" '$1=="worktree" && $2==p {print "yes"}')` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/open/SKILL.md` (5) | `branch_exists=$(git rev-parse --verify "$branch" >/dev/null 2>&1 && echo yes ¦¦ echo no)` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/open/SKILL.md` (6) | `branch_wt=$(git worktree list --porcelain ¦ awk -v b="refs/heads/$branch" '` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/open/SKILL.md` (7) | `git worktree prune` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/open/SKILL.md` (8) | `cur_top=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ cur_top=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/open/SKILL.md` (9) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/pr-create/SKILL.md` (1) | `owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/pr-create/SKILL.md` (2) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/pr-create/SKILL.md` (3) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/pr-review/references/scope-triage.md` (1) | `triage_adoption="$(bash {plugin_root}/hooks/state-path-resolve.sh)/.rite/state/adoption-{pr_number}-triage.json"` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/pr-review/references/scope-triage.md` (2) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) && [ -n "$state_root" ] \` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/ready/SKILL.md` (1) | `owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/ready/SKILL.md` (2) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/ready/SKILL.md` (3) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/recover/SKILL.md` (1) | `wt_issues=$(git worktree list --porcelain 2>/dev/null ¦ awk '$1=="worktree"{print $2}' \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/recover/SKILL.md` (2) | `[ -f "$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)" ] && git_in_merge=yes ¦¦ git_in_merge=no` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/recover/SKILL.md` (3) | `if [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] ¦¦ [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/recover/SKILL.md` (4) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/recover/SKILL.md` (5) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) ¦¦ state_root=""` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/recover/SKILL.md` (6) | `[ -n "$state_root" ] ¦¦ { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; state_root="$(pwd)"; }` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/recover/SKILL.md` (7) | `wiki_branch_probe=$(git -C "$wiki_wt" branch --show-current 2>/dev/null ¦¦ echo "")` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `skills/recover/SKILL.md` (8) | `if ! git -C "$wiki_wt" rev-parse -q --verify "origin/$wiki_branch_probe" >/dev/null 2>&1; then` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `skills/recover/SKILL.md` (9) | `unpushed=$(git -C "$wiki_wt" log "origin/$wiki_branch_probe..HEAD" --oneline 2>/dev/null)` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `skills/recover/SKILL.md` (10) | `cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) ¦¦ cur=""` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/recover/SKILL.md` (11) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/rite-workflow/references/session-detection.md` (1) | `owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/rite-workflow/references/session-detection.md` (2) | `owner=$(gh repo view --json owner --jq '.owner.login')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/rite-workflow/references/session-detection.md` (3) | `repo=$(gh repo view --json name --jq '.name')` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/rite-workflow/references/work-memory-format.md` (1) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/setup/SKILL.md` (1) | `if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (2) | `git rev-parse --verify HEAD >/dev/null 2>&1` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (3) | `owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) ¦¦ owner_repo=""` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/setup/SKILL.md` (4) | `gh repo view "$owner/$repo" --json owner,name,id,url` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/setup/SKILL.md` (5) | `gh repo view --json owner,name,id,url` | R | 壊れない（固定cwd）、除外 | 入口・helperの対象cwdを固定すると同じorigin。非固定単体foreignでは別repoへ解決され壊れる |
| `skills/setup/SKILL.md` (6) | `project_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ project_root="$PWD"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (7) | `project_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ project_root="$PWD"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (8) | `project_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ project_root="$PWD"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (9) | `project_root=$(git rev-parse --show-toplevel 2>/dev/null) ¦¦ project_root="$PWD"` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (10) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/setup/SKILL.md` (11) | `LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null) && \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (12) | `REMOTE_HEAD=$(git rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null) && \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (13) | `state_root=$(bash "{hooks_dir}/state-path-resolve.sh")` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/setup/SKILL.md` (14) | `state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/setup/SKILL.md` (15) | `if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 ¦¦ \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (16) | `git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (17) | `if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 ¦¦ \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (18) | `git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/setup/SKILL.md` (19) | `bash {plugin_root}/hooks/state-path-resolve.sh` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/wiki-ingest/SKILL.md` (1) | `if ! ( git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 ¦¦ \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/wiki-ingest/SKILL.md` (2) | `git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1 ); then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/wiki-ingest/SKILL.md` (3) | `wiki_wt_abs="$(bash "$plugin_root/hooks/state-path-resolve.sh")/.rite/wiki-worktree"` | S | 壊れない（固定cwd）、除外 | 既存入口の対象cwdで共有state rootを解決。非固定単体foreignでは別stateへ解決され壊れる |
| `skills/wiki-ingest/SKILL.md` (4) | `echo "  対処: git -C \"$wiki_wt_abs\" status で worktree の状態を確認" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `skills/wiki-ingest/SKILL.md` (5) | `echo "  手動回復: git -C \"$wiki_wt_abs\" push origin $wiki_branch" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `skills/wiki-ingest/SKILL.md` (6) | `if [ "{branch_strategy}" = "same_branch" ] && [ -f "$(git rev-parse --git-dir)/commondir" ]; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/wiki-ingest/SKILL.md` (7) | `separate_branch) echo "  対処: 直近の wiki の commit を確認し（git -C \"$wiki_wt_abs\" log --oneline -n 20）、重複や上書きがあれば手で直してください" >&2 ;;` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `skills/wiki-ingest/SKILL.md` (8) | `echo "  対処: git worktree list で他セッションのブランチを確認し、全ブランチの wiki の履歴（git log --all --oneline -n 20 -- .rite/wiki/）を調べ、重複や上書きがあれば手で直してください" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `skills/wiki-ingest/SKILL.md` (9) | `*) echo "  対処: 直近の wiki の commit を確認し（separate_branch: git -C \"$wiki_wt_abs\" log --oneline -n 20 / same_branch: git log --oneline -n 20 -- .rite/wiki/）、重複や上書きがあれば手で直してください" >&2 ;;` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `skills/wiki-init/SKILL.md` (1) | `if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 ¦¦ \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/wiki-init/SKILL.md` (2) | `git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/wiki-init/SKILL.md` (3) | `echo "  対処: git -C {wiki_worktree_abs} status で状態を確認してください" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |
| `skills/wiki-init/SKILL.md` (4) | `3) echo "WARNING: migration commit 内部で git 操作失敗 (retry rc=3)。git -C {wiki_worktree_abs} status で状態を確認してください" >&2 ;;` | W | 壊れない（明示対象）、除外 | 式の対象パスへ git -C / cd / resolver引数で固定。引数が入口の対象であることを保持 |
| `skills/wiki-lint/SKILL.md` (1) | `if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 ¦¦ \` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/wiki-lint/SKILL.md` (2) | `git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then` | W | 壊れない（固定cwd）、除外 | 対象worktreeで同じHEAD/登録情報を読む。非固定単体foreignでは別Git情報を読み壊れる |
| `skills/wiki-lint/SKILL.md` (3) | `echo "  対処: wiki ブランチが存在するか確認してください (git rev-parse --verify $wiki_branch)" >&2` | W | 呼出し対象外 | 診断・usage・参照文字列で実操作しない |

コメントだけの候補は実操作から除外する: `hooks/_resolve-session-id-from-file.sh`、`hooks/review-nonblocking-record.sh`、`hooks/scripts/lib/wiki-config.sh`、`hooks/scripts/review-results-archive-or-rm.sh`、`scripts/fix-work-memory-update.sh`。検査patternやusageのように非コメントでも実操作でない一致は表内で「呼出し対象外」として理由を記録する。
