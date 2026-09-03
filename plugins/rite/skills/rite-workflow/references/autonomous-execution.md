# Autonomous Execution

計画・約束・質問だけで turn を終えず、いま実行する。依頼範囲内で可逆な行動は確認なしで進め、タスク完了またはユーザーにしか出せない入力でブロックされたときだけ turn を終える。
次に必要なものを先に列挙し、他の結果に依存しないものは同じ応答で全部要求する。

reviewer agent は frontmatter の `effort: high` で固定する。orchestrator のルーチン作業を effort 調整可能なモデルで実行する場合は、過剰な熟考・検証を避けるため低めの effort を選ぶ（ホスト固有設定として強制しない）。

コンテキストは十分残っているので、コンテキスト制限を理由に停止・要約・新セッション提案・作業の切り詰めをしない。枯渇時の再開は機構（flow-state・marker・SessionStart(compact) の復帰文・recover）が保証している。

報告は outcome と次の一手のみ。欠陥の詳細・自己評価・経緯の釈明は review record と commit が家であり、報告文へ複製しない。

## 正規確認ゲート

rite が意図して止まりユーザーに確認する正規ゲートは下表のみ。表外の一時失敗（pr-create 失敗、lint error、sub-skill sentinel 不在など）は質問せず 1 回自動再試行し、再失敗で停止して `/rite:recover` を案内する。ゲート表は rite-config.yml の設定にしない。

計画承認は standalone のみ AskUserQuestion。batch では自動承認。その他の表内ゲートは経路を問わず確認する（入力品質・破壊的操作）。

| ゲート | 発火条件 | standalone | batch |
|--------|----------|------------|-------|
| 計画承認 | open ステップ 3.4 | AskUserQuestion | 自動承認 |
| Issue 状態確認 | closed Issue / 親 Issue / 品質 C-D | AskUserQuestion | 停止（入力品質ゲート。自動承認しない） |
| dirty 衝突 | worktree 新規作成前、dirty ファイルが Issue 対象と重なる | AskUserQuestion（搬送 / そのまま続行 / 中止） | 同左 |
| 強制取得 | 他 live セッションの Issue claim（`rc=10`） | AskUserQuestion（中止推奨 / 強制取得して続行） | 同左（無人奪取禁止） |
| 破壊的操作 | `rm -rf`（stale worktree 残骸の削除）、dirty の破棄 | AskUserQuestion | 同左 |

破壊的操作（`rm -rf`、他セッションからの強制取得、dirty の破棄）は表に残す。
