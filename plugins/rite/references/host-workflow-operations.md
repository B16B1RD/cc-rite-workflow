# Host workflow operations

[Host Runtime Contract](host-runtime-contract.md) の具体的な呼出し手順。実行時に公開された tool schema を用い、ホスト名から能力を推測しない。工程・引数・sentinel は各 SKILL.md が SoT。

## Skill と caller

1. native Skill があれば使用する。無ければ、解決済み plugin root の `skills/{name}/SKILL.md` と必要な同梱参照を読み、親が同じ手順を実行する。`user-invocable: false` は nested 実行を省略する理由にしない。
2. 呼出し前に `caller / callee / args / expected_sentinels` を作業メモリへ記録する。native/本文実行とも caller からの呼出しは E2E とする。復旧時は flow-state と既存 PR を再照合し、記録だけで完了扱いにしない。
3. 子の実際の操作結果を検証し、定義された sentinel を caller へ返す。本文の読込だけ、ファイル生成だけ、子の起動確認だけでは成功にしない。caller の分岐表に従って同じ turn で次工程へ進む。
4. sentinel 不在・失敗は caller の再試行回数と停止手順へ戻す。未実施の工程を補完しない。`batch-run` は cursor を失敗 Issue に保持し `active=false`、`iterate` は最後に検証した phase と review record を保持する。

## TaskCreate / TaskUpdate / TaskList

native task 機能があれば既存手順で使う。無い実行面では、現在セッションの flow-state path の basename を用いた `.rite/state/tasks-{session_id}.json` を同等の台帳として使う。共有/global 名は禁止。

- 初回のみ全 step を `{id, subject, status:"pending"}` の配列として保存する。外側 skill の `workflow`、実 `session_id`、`issue_number` も保存する。nested skill は同じ台帳を更新する。
- 作業開始時に `in_progress`、結果を検証した step のみ `completed` にする。書込み後に JSON を読み直す。IO エラーでは後続を止め、記録済み phase から recover する。
- 最外側の終了前に全件を読み、未完了があれば最初の未完了工程へ戻る。失敗停止では未完了を残す。正常終了時のみ自セッションの台帳を削除する。

台帳は進捗の表示用で、flow-state / run-queue の工程・所有者を上書きする権威ではない。別ホストへの移管時も、別セッションの台帳を自分のものとして使用しない。

## 独立 reviewer

`pr-review` の選定人数、専門本文、レビュー対象、読取専用制約、時刻記録、結果形式を保持する。

| 経路 | 実行 |
|---|---|
| native named Agent/Task | 選定済み `rite:{type}-reviewer` を指定し、実 ID と completion notification を回収する |
| named agent が公開されず独立子は利用可能 | 配布内 `agents/{type}-reviewer.md` と `agents/_reviewer-base.md`、必要な参照を読み、本文・制約・差分・仕様・絶対 workdir を native 子の prompt へ明示する |
| 独立子・必要な並列性・読取専用制約を維持できない | 起動前に不足能力を診断し `[review:error]`。自己レビューや人数削減で代替しない |

Codex の `spawn_agent` では named reviewer の frontmatter `model: inherit` と `effort: high` を尊重する。公開 schema が effort を設定できる場合は設定する。Grok でも同じ本文を渡すが、frontmatter が実際に適用されるとは仮定しない。ホストで強制できない制約は子の指示へ明示し、結果と変更前後の state snapshot で確認する。権限拒否された起動を別経路へ置換しない。

起動時に選定名簿と親/子の実 ID・時刻を保持し、全 completion を待つ。子が失敗したら既存の1回再試行を適用し、再失敗は incomplete として停止する。残りの成功結果は保持する。

### 回収ゲート

選定名簿は起動前の値を固定し、回収不能な reviewer を削除しない。raw 出力は編集せず絶対パスのファイルへ保存する。ホストの実出力から次の manifest を `REVIEW_TMP_DIR/rite-review-{session_id}-{pr_number}-{cycle_count}-{orchestrator_spawn_at}/reviewer-completions.json` に保存する（各値は pr-review で取得した現在 session・PR・cycle・初回 spawn 時刻）。同じディレクトリに reviewer ごとの raw 出力を置き、別 session / cycle の manifest を流用しない。

```json
{
  "schema_version": 1,
  "parent_agent_id": "actual-parent-id",
  "selected_reviewers": ["security-reviewer"],
  "reviewers": [{
    "reviewer": "security-reviewer",
    "agent_id": "actual-child-id",
    "status": "completed",
    "started_at": "2026-01-01T00:00:00Z",
    "ended_at": "2026-01-01T00:01:00Z",
    "output_file": "/absolute/review/security.md"
  }]
}
```

上記はフィールド例であり、実行時は選定 reviewer **全件**を記録する。ID・時刻・出力を推測しない。manifest と raw 出力を保持したまま次を実行する。

```bash
bash {plugin_root}/hooks/scripts/reviewer-completion-check.sh --input "{reviewer_completions_file}"
```

`{reviewer_completions_file}` は保存した manifest の絶対パス。非ゼロなら失敗 reviewer と理由を診断し `[review:error]` を返す。指摘統合・mergeable 判定には進まない。pass は回収条件だけの検証であり、指摘の正しさは既存の Critic フェーズで検証する。

## 質問と承認

通常の不足情報はそのモードで公開された質問ツールを使う。質問 UI が無い場合は会話で1問を出し、実際の回答が届くまで依存工程を停止する。未回答・timeout は承認ではない。batch の計画自動承認は active queue と cursor 照合で決める。

権限は各ホストの正式機構だけを使う。Codex の `require_escalated` などは、拒否された具体的操作と必要な権限を提示して審査結果を待つ。通常の質問・`--merge`・別ツールは権限拒否の解除にならない。拒否時は対象を変更せず state と cursor を保持し、理由と復旧操作を報告する。
