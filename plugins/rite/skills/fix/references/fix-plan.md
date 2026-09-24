# 一括修正計画と検証

`flow-state.review_cycle.status=completed` の `result_path` を全指摘の入力にする。現在 session / run / PR / cycle / HEAD が一致しない結果は流用しない。保存未完なら `/rite:pr-review` の回収・保存へ戻り、指摘を減らして先へ進まない。既存の severity・実測・AC ゲートは維持する。

最新 Issue を `gh issue view` の `--json number,body` で `{fix_issue_file}` へ取得する。再開時と最終検証前にも再取得し、取得失敗で古い snapshot を使用しない。Issue の targets は候補か閉じた allowlist かを本文で判断し、明示 Non-Target と Out of Scope は変更しない。曖昧で解消不能な制約は理由を保持して停止する。

`{fix_plan_file}` は現在セッションの `.rite/state/fix-plan-input-{session}.json` に置く。JSON 契約:

| フィールド | 内容 |
|---|---|
| `review_context` | 保存済みレビューの context を完全コピー |
| `issue_number`, `issue_body` | 最新 Issue の番号と本文を完全コピー。helper の照合は Decision Log のトリアージ行と非実測記録の marker 行を除外する（[レビュー停滞の診断](../../../references/review-stagnation.md)） |
| `constraints` | `targets` / `non_targets`: repository 相対パス配列。`closed_targets`: boolean。`rationale`: 本文から採った解釈の根拠 |
| `groups[]` | 同じ根因は1グループ。`root_cause`, `finding_ids`, `action`, `paths`, `rationale`, `semantic`, `verification_ids`。`rationale` に元要求との対応と、追加／削除／差し戻し／移動から選んだ処置の理由を短く書く（初回 finding でも。Escalation 段落の代用にしない） |
| `groups[].semantic` | `approved`: boolean。`acceptance_criteria`: AC全体との照合根拠。`out_of_scope`: 要求外の動作変更を含まない根拠。違反・未判断は `approved:false` と理由を記録 |
| `verifications[]` | `id`, `kind` (`related` / `full`), `command`, `inputs` (ファイル/ディレクトリ配列), `environment` (結果に影響する環境変数名配列) |

`action` は `fix` / `reply` / `accept` / `nit-noted` と、base 取り込み専用の `base-intake`（下記「base 取り込み」）。全 blocking finding ID を重複なく処置へ対応付ける。fix は予定パスを持ち、全処置は検証 ID と根拠を持つ。全体検証 (`kind:full`) を最低1件定める。未解決の人間由来指摘は `external_findings` に `id`・元の `thread_id`・`description` を記録し、同じグループと検証に対応付ける。

helper は標準 `### 4.2` 節内の backtick パスが `non_targets` に含まれることを確認する。それ以外の書式や散文制約は caller が全件抽出し根拠を記録する。パス検査は意味判断を代行しない。予定パスは相対表記とし親参照を含めない。Non-Target に達する symlink も対象外と扱う。

関連テストの `inputs` は実装・テスト・設定・依存lockfileを含め、影響するディレクトリを漏らさない。`environment` は必要な変数名を指定する。ツール版など環境変数にない関連環境は計画時にファイルへ実測出力し inputs に含め、再利用前に更新する。外部状態を固定できない検証は `full` として再実行する。stdout/stderr に秘密を出すコマンドは使わない。

`verifications[].command` は `bash -c` で実行され、**検証コマンド自身の終了コード 0 を成功**とする。検査対象が異常系で rc=2 を返すことを期待する場合は、その値をアサートし、期待どおりなら検証自身を 0 で終える。対象コマンドを直接登録して非ゼロ終了を成功扱いさせることはできない。`check` はコマンドの期待終了値を推測・実行しない。

次は `command` に入れるシェル本文の例（JSON では改行・引用符を適切にエスケープする）。`scripts/a.sh` が rc=2 を返すことを検査する:

```bash
# assert-expected-exit-single
actual=0
bash scripts/a.sh || actual=$?
test "$actual" -eq 2
```

複数対象は各終了値を検査し、先行対象の不一致を後続成功で隠さない。`a; b` だけでは最後の終了値しか返らない:

```bash
# assert-expected-exit-multiple
assert_rc2() {
  local actual=0
  "$@" || actual=$?
  test "$actual" -eq 2
}
assert_rc2 bash scripts/a.sh &&
  assert_rc2 bash scripts/b.sh
```

失敗時も実測終了コード・stdout/stderr は検証記録に残る。診断の `actual_rc` と証跡を確認し、対象の欠陥とアサーションの誤りを区別する。通常の計画で検証コマンドが誤っているときは、入力を直し、scope `check` と `verify --kind all` をやり直す。

修正中は `review-fix-scope-check.sh verify --plan ... --issue ... --kind related` を使う。内容（追加・削除・modeを含む）・コマンド・指定環境・作業先・基本runtimeが同一で、当該 context の実測成功がある関連テストだけ再利用する。失敗・入力変化・新しいreview contextは再実行する。全修正後は `fix` 本体の最終検証ブロックを実行し、関連結果の鮮度を確認した後、全体検証を全件実行する。検証コマンドは入力を変更しない。

機械検査と意味判断を分けた検査記録は `.rite/state/fix-plan-{session}.json`、実測コマンド・終了コード・stdout/stderr・鮮度キーは `.rite/state/fix-verification-{session}.json` に保存する。検査記録は入力とは別ファイルであり、記録と同一実体を `--plan` に渡すと `check` は書き込み前に拒否する。保存失敗は成功にせず前の記録を保持する。復旧は同じ入力で check → verify。任意のファイル直接編集やホスト権限の遮断は保証しない。

## base 取り込み

レビューを始めた PR ブランチへ base ブランチを取り込む正規の手順。レビュー中の作業先では、検証を経ない merge commit は拒否される（自動で commit する `git merge <ref>`、計画なしの `git commit` / `git merge --continue`）。取り込み後の HEAD は次の `review-start` で検証済みでなければ再レビューできず、ready / merge にも進めないため、この順で行う:

1. `git fetch origin <base>` のあと `git merge --no-commit --no-ff origin/<base>` で取り込み、競合を解消して `git add` する（HEAD はレビュー済み commit のまま）。`<base>` は `rite-config.yml` の `branch.base`（未設定なら取り込めず止まる）。merge が既に進行中（`MERGE_HEAD` がある）なら、取り込み相手が `origin/<base>` のときは競合解消と `git add` から始め、そうでなければ `git merge --abort` してからこの手順 1 に戻る
2. `git diff --no-renames --name-only HEAD` の全パスを 1 つの `action: "base-intake"` グループの `paths` に並べ、全体検証を対応付ける。`finding_ids` は空でよい。改名は旧パスと新パスの 2 つとして並ぶ
3. `check` → `verify --kind all` を通し、`git commit` で取り込みを確定する（`git merge --continue` も同じ検査を受ける）
4. `git push origin HEAD` で取り込み commit を PR に反映する
5. `/rite:iterate` で次のレビュー cycle を回し、mergeable になってから ready / merge へ進む

制約の除外はファイル単位で、base 側が変更したファイル（merge-base から取り込み相手までの差分に出るファイル）だけが Issue の Non-Target / 閉じた対象の検査から外れる。競合を解消したファイルは base 側も変更しているので外れる。base 側が変更していないファイル（base の変更に合わせて直した自ブランチのファイル等）は制約を受ける。

`base-intake` は merge 進行中（`MERGE_HEAD` がある状態）でだけ有効で、取り込み相手は `origin/<base>` またはその祖先に限る（別ブランチや別の worktree で作った commit は取り込めない）。計画に 1 グループまで。`--no-commit` / `--squash` / `--abort` / `--quit` / `--ff-only` の merge は拒否されない（オプションは git と同じく後に書いたものが勝つ。これらのオプションの省略形は判定できないため拒否される）。`git pull` / rebase 等でレビュー済み HEAD を動かした場合は次の `review-start` が拒否する。レビュー済み commit（`flow-state.sh get --jq-filter .review_cycle.review_context.commit_sha`）へ `git reset --keep` で戻してから、この手順で取り込む。ただし、`git fetch origin <PR ブランチ>` のあと `git merge-base --is-ancestor origin/<PR ブランチ> <レビュー済み commit>` が失敗するなら、戻すと push 済みの commit を巻き戻すことになるため、戻さずに止まり、その状況を報告する（公開済み履歴の書き換えは人間が判断する）。

## 停滞時の見直し計画

[レビュー停滞の診断](../../../references/review-stagnation.md) が `action=replan` を返した場合、同じ `{fix_plan_file}` に次の `replan` を追加する。全指摘・最新仕様・既存 `constraints` / `groups` / `verifications` との対応を維持する。

| フィールド | 内容 |
|---|---|
| `replan.alternatives[]` | 最低2案。それぞれ `id`, `description`, `paths`（相対パス配列）, `recurrence_prevention`（非空文字列）, `rejection_reason` を記録 |
| `replan.selected_id` | 選択案の `id`。`outcome:insoluble` のときは `null` |
| `replan.selection_reason` | 選択理由。解決不能時は仕様・契約上、範囲内で解けない理由 |
| `replan.outcome` | 範囲内修正を続ける `continue` / 範囲内解決不能の `insoluble` |

選択案の `paths` 集合は全 `groups[].paths` の集合と一致させる。非選択案には棄却理由を必須とし、`insoluble` は全案の棄却理由を保持する。再発防止検証は各案の根因を再現・検出できる内容を示し、選択案では `groups[].verification_ids` と `verifications[]` に接続する。未検証、証跡欠損、権限拒否を解決不能という意味判断に置き換えない。

編集前に `flow-state.sh review-replan --plan "{fix_plan_file}" --issue "{fix_issue_file}"` を実行する。helper は既存の範囲検査を適用して見直し結果を run に保存する。失敗時は計画・履歴を保持して編集せず、同じ工程を復旧する。通常の scope check も、診断 run の観測欠損や未完了の見直しを拒否する。

登録済み replan の検証コマンドだけを同じ run / context で直すときは `review-replan --amend --reason "訂正理由"` を使う。許可する差分は既存 `verifications[].command` のみで、診断用 `review-replan`（代替案の保存）とは別操作である。訂正後は scope `check` と `verify --kind all` をやり直す。固定済みの見直し計画を任意に書き換えて再登録できるという意味ではない。

最終 `verify --kind all` の成功で検証済み tree fingerprint と対象根因を保存する。次レビュー開始時の新 HEAD・clean tree と検証済み内容の照合を経て修正履歴を確定するため、検証後に入力が変わった場合は最終検証をやり直す。同じ run の再開で見直し回数や観測履歴をリセットしない。
