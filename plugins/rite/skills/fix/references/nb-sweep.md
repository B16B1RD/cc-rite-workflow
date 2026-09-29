### 1.3.S `--nb-sweep` consume（5.S 専用）

`[CONTEXT] NB_SWEEP=1` のときだけ評価する。通常ループでは本節を skip。既存の `nb-sweep-done-{pr_number}.txt` があっても consume を skip しない。成功した書込は 1 行目を上書きする。既存の 2 行目が SHA なら残し、新しい SHA は足さない。入口でファイルの有無を見て return しない。fix/SKILL.md のステップ 2–4 は評価せず、本節の後に fix/SKILL.md の 5.1 へ進む。
rationale: ../../iterate/references/rationale.md#nb-sweep-step

1. **collect**（iterate 5.S と同 helper。冪等）:

```bash
bash {plugin_root}/scripts/fix-step.sh nb-sweep-collect --pr {pr_number}
```

`empty` なら手順 2・3 を skip して fix/SKILL.md の 5.1 へ。collect は sweep の hold ファイル（state root の `.rite/state/adoption-hold-{pr_number}-sweep.json`）があれば、その候補のうち今回の target と内容の一致しないものを `candidates[]` に合流させる（元の review JSON の basename を `record` に持ち、id は `<record>#<key>`）。保留した commit を問わず、今回の review JSON の head で判定し直す（直っていれば RESOLVED、PR 起因が残れば保留のまま）。hold ファイルは手順 3 の台帳記録が成功するまで残る（手順 3 の bash が消す）。そのため起票や台帳 persist の途中で止まった再実行でも、持ち越した候補は候補に残る。

`NB_SWEEP_ENTRIES=present` なら、この sweep の起票は前回済んでいて手順 3 で止まっている（entries は手順 2 の全件成功後にだけ作られ、手順 4 か `empty` で消える）。手順 2 を実行せず、手順 3 の後の戻り方で entries を直して手順 3 から続ける。`absent` なら手順 2 へ。`reason=nb_sweep_entries_stale` は、entries の 1 行目（`<!-- nb-sweep-record: ... -->`）が今回の `record=` の basename を名指さない（別の sweep の entries が残っている）。起票も台帳 persist も始めずに止まる。行の出典は照合しない（合流した保留候補の行は元の review JSON を出典に持つ）。1 行目が別の record を名指す entries の行は、前回の sweep が起票したまま台帳に載せられなかった記録であり、1 行目も行の出典も今回の record に書き換えてはならない（書き換えると手順 2 を飛ばし、今回の対象が起票も記録もされない）。記録コメントの `### 却下台帳` に同じ id・位置・出典の行が既にあれば、手順 3 は成功済みなので再実行しない（append は重複を除かず、同じ行が二重に載る）。entries を消して `/rite:iterate {pr_number}` を再実行する。無ければ書き換えずに手順 3 の bash だけを実行して元の出典のまま台帳へ載せ、成功したら entries を消して `/rite:iterate {pr_number}` を再実行する。台帳に載った指摘は collect が除外するので重複起票せず、今回の sweep は手順 2 から始まる。

2. **採否ゲートと起票**（採否は採否判定 helper の出口で決め、重要度・実測で決めない）:

`already_rejected[]` はゲートに掛けず `recorded` として転記する。sweep はコードを変更せず、commit / push を行わない。
rationale: design-rationale.md#nb-sweep-routing

**判定記録**: 手順 1 の stdout の `candidates[]` 全件について、本手順を実行する分類役が根因ごとに 1 件の判定記録を Write tool で state root（`state-path-resolve.sh` の出力）の `.rite/state/adoption-{pr_number}-sweep.json` に保存する（形式と欄は `hooks/scripts/review-adoption-gate.sh` と `hooks/scripts/lib/review-adoption.py` の docstring）。`head` は手順 1 の出力のトップレベル `.record`（今回読んだ review JSON。ゲートの `--review-result`）の `commit_sha`（candidate の `record` ではない）、`ids` は candidate の `id`（target は `key`、合流した保留候補は `<record>#<key>`）。起票になる記録（ADOPT で origin=pre_existing、DIAGNOSE で調査として引き受ける記録）には `acceptance`（起票する Issue の受入条件）を書く。target に `prior` があれば記録の `prior` にそのまま写す（prior の違う target を 1 つの記録にまとめない）。手順 1 の出力の `ledger[]`（台帳の `issued` / `LINK` / `REJECT` 行。`issued` と `LINK` の判定文に起票先・追跡先の `#N` がある）と、判定記録ファイルの `tracker` を持つ記録（`head` を問わない）を読み、既存の Issue が今回の候補と同じ根因を追跡していれば、文面・位置・id が変わっていても記録の `tracker` にその番号を入れる（閉じた Issue の番号は入れない）。`REJECT` 行が同じ根因・同じ前提の候補を処分していれば、その行を記録の `prior`（`{finding_id, file_line, disposition, premise}`。行の `id` を `finding_id`、`loc` を `file_line` に写し、`source` は写さない）に写す。collect が写すのは id と位置が一致する行だけなので、id・文面・位置が変わった候補はここで紐づける。同じ `head` の判定記録が既にあればそこから始め、足りない記録を補い、helper の ERROR で止まった記録は直す。起票が書き戻した `tracker` だけは書き換えない（消さない）。

**裁定が必要な場合**: ゲートが `reconciliation[]` を返したら、親が [共通の裁定手順](../../../references/review-reconciliation.md) に従い、当該記録の `reconciliation` に回答する。既存候補だけを扱い、未裁定・入力変更・契約変更の保留は `hold.detail` / `resume` から同手順へ戻る。HEAD が同じでも候補・判定記録・契約・履歴が変われば回答を流用しない。

**ゲート**: 下の helper が collect をもう一度実行し、`candidates[]` から候補ファイルを作ってゲートを呼ぶ。`{base_branch}` は rite-config `branch.base`、無ければステップ 1.1 の `.baseRefName`。

```bash
bash {plugin_root}/scripts/fix-step.sh nb-sweep-gate --pr {pr_number} --base-branch {base_branch} --owner-repo {owner_repo}
```

`[fix:error]` のどれでも、起票も entries も台帳 persist も done の書込もしない。`reason=nb_sweep_adoption_held` は出口の出ていない候補がある（判定記録なし・helper の ERROR・hold の出口）。候補の全文・出典・対象 HEAD・再開位置はゲートが stderr の `hold_file=` に保存済み。保留を REJECT や処分済みに書き換えず、hold ファイルの resume（ゲートの WARNING にも出る）に従って再開する（PR 起因の保留はコードを直して push し再レビューするなど、理由ごとの手段は resume が持つ）。HEAD が変わらない再開では、ステップ 0.7 が 5.S へ戻し本手順から続く。

**起票**: stdout の `verdicts[]` のうち `verdict=file` の記録ごとに 1 件起票する（1 根因 = 1 Issue。違う記録を 1 件にまとめない）。`verdict=record` は起票しない。本文は記録（`verdicts[].record`）から作り、`/rite:open` が複雑度を読む Meta で始め、Projects に渡す `complexity` と同じ値を宣言する。`projects` は rite-config.yml の設定を反映する。起票ごとに、タイトル `{type}: {summary}`（1 行）と下のテンプレートの本文を Write tool で作業ツリー外の絶対パスへ書き、下の 1 行で起票する。helper は起票した番号を判定記録の `tracker` に書き戻してから、stdout に起票結果の JSON を出す。成功時の `issue_number` と `issue_url` を当該記録に対応付けて entries に使う:

| Placeholder | Source |
|-------------|--------|
| `{type}` | 根因から推定（`fix` / `refactor` / `docs` 等） |
| `{summary}` | 根因の要約（動詞始まり、50 文字以内） |
| `{overview}` | 根因の説明（何が起きていて何が困るか） |
| `{contract}` / `{evidence}` / `{acceptance}` | 記録の `contract`（`ref` と引用 `text`）/ `evidence` / `acceptance` |
| `{proposition}` | `action=investigate` のとき記録の `proposition` の命題・到達条件・その出所・完了条件。それ以外は `## 調査` 節ごと消す |
| `{observations}` | 記録の `ids` の candidate ごとに `- {file}:{line} {description}`（`suggestion` があれば続ける） |
| `{record_ids}` | 記録の `ids`（JSON 配列） |
| `{projects_enabled}` / `{project_number}` / `{owner}` | `rite-config.yml` → `github.projects.enabled` / `project_number` / `owner` |
| `{issue_title_file}` / `{issue_body_file}` | タイトルと本文を Write tool で書いた作業ツリー外の絶対パス |

```markdown
**Type**: {type}
**Complexity**: S

## 概要

{overview}

## 契約

{contract}

## 根拠

{evidence}

## 受入条件

{acceptance}

## 調査

{proposition}

## 観測した候補

{observations}

## 関連

- 元の PR: #{pr_number}
```

```bash
bash {plugin_root}/scripts/fix-step.sh nb-sweep-file-issue --pr {pr_number} \
  --issue-title-file '{issue_title_file}' --issue-body-file '{issue_body_file}' --record-ids '{record_ids}' \
  --projects-enabled {projects_enabled} --project-number {project_number} --project-owner {owner}
```

起票失敗時は台帳 persist・done ファイル書込・完了通知へ進まない。全件成功後に entries を生成する（手順 3 を再実行するときは、同じ sweep の entries を直して使う。前回の sweep の entries を今回の起票済みとして使わない）。`verdict=record` の記録も `already_rejected` も silent に落とさない。起票の途中で止まったときも再実行は手順 2 の判定記録から続き、書き戻した `tracker` によりゲートは起票済みの記録を LINK にするので、同じ根因を二度起票しない。

3. **台帳 persist**（全 target と already_rejected）:

Write tool で entries を手順 1 の `NB_SWEEP_ENTRIES` の `path=`（`.rite/state/nb-sweep-entries-{pr_number}.md`。会話や再起動をまたいで起票済みの記録を残すため一時ディレクトリに置かない）に保存（1 行目は `<!-- nb-sweep-record: {sweep_record} -->`。`{sweep_record}` は手順 1 の stderr に出る `record=` の値の basename で、手順 1 の tally はこの行でどの sweep の entries かを決める。続けて列 0。candidate 1 件に 1 行。行形式 `| {key} | {file}:{line} | {判定} | {判定文} | {record_basename} |`）。`verdict=file` の記録の candidate は判定 `issued`・判定文に起票先 `#N` と URL。`verdict=record` の記録の candidate は判定に出口名（`REJECT` / `RESOLVED` / `LINK`）、判定文に記録の `reason`（RESOLVED で reason が無ければ `evidence`、LINK は `追跡先 #{tracker}`）。hold は書かない（held なら手順 2 で止まっている）。`already_rejected` は判定 `recorded`・判定文 `severity={sev}; measured={bool}`。`{record_basename}` は candidate の `record`（今回の target は手順 1 の stderr に出る `[CONTEXT] NB_SWEEP_COLLECT=ok; ...; record=` の値の basename、合流した保留候補は元の review JSON の basename）、`already_rejected` は `record=` の値の basename。cleanup の follow-up 起票はこの出典で sweep 起票済みの指摘を同定するため、最終列を欠いた行が 1 行でもあれば、append は entries 全体を `reason=entries_source_invalid` で拒否し、台帳を変更しない。`already_rejected` は id=`reviewer`、位置=`file_line`、severity=`original_severity`、measured=false とする。セル内のパイプ・改行はエスケープする。

```bash
bash {plugin_root}/scripts/fix-step.sh nb-sweep-persist --pr {pr_number} --owner-repo {owner_repo}
```

台帳の記録が成功すると、同じ bash が sweep の hold ファイルを消す。

手順 3 が `[fix:error]` で止まったときは、手順 2 の起票をやり直さない。起票は済んでいるが台帳に行が無いため、sweep を最初から実行し直すと同じ指摘を再び起票する。起票済みの Issue は entries の issued 行が持つ。entries（`.rite/state/nb-sweep-entries-{pr_number}.md`）を stderr の理由に合わせて直し、手順 3 だけを再実行する。`reason=entries_source_invalid` の診断は不正行の先頭 3 行しか示さないので、entries の全行について最終列がその行の candidate の `record`（`already_rejected` は手順 1 の `record=` の basename）になっているかを確かめ、欠けた行には最終列として足す。別の record を名指す行は書き換えない（手順 1 の `reason=nb_sweep_entries_stale` の戻り方に従う）。成功したら手順 4 へ進む。この会話で続けられないときは entries を直したうえで `/rite:iterate {pr_number}` を再実行する（別の会話からでもよい）。iterate のステップ 0.7 が再レビューを回さずに 5.S へ戻し、手順 1 が `NB_SWEEP_ENTRIES=present` を出すので手順 2 を飛ばして手順 3 から続く。

4. **完了**:

下の bash が entries の判定列から件数を数えて `[CONTEXT] NB_SWEEP_RESULT=done; issued=K; recorded=M` を出し（K は `issued` 行、M は `REJECT` / `RESOLVED` / `LINK` / `recorded` 行）、台帳に載った entries を消す（別の会話から戻ったときも件数を会話に頼らない）。全件の台帳 persist 成功後に 1 行目を `done <basename>` にする。basename は collect が `--pr` で選ぶのと同じ最新 JSON（`LC_ALL=C` sort の末尾。collect 出力 `.record` の basename と同一）。この bash は別シェルなので `.record` を再計算する。既存の 2 行目が SHA なら残し、新しい SHA は足さない。既存ファイルでも 1 行目は上書きする（ファイルが無いときだけ書く形にはしない）。

```bash
bash {plugin_root}/scripts/fix-step.sh nb-sweep-finish --pr {pr_number}
```

fix/SKILL.md のステップ 5.1 が `[fix:sweep-done]` を emit する。`K+M` は collect `count`（already_rejected 転記を含む）と一致する。未消化 0 が正常出口。
