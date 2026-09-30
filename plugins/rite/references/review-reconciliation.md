# 採否の矛盾・再発・巻き戻しの裁定

NB sweep、スコープ外処分、cleanup follow-up は同じ採否ゲートを使う。これは既存候補の採否を確定する手順であり、新しい指摘や id の生成、全体の再レビューは行わない。

## 入口と照合範囲

`review-adoption-check.sh` は読取専用で、任意の `--history-dir DIR --pr N --kind sweep|triage|followup [--issue N]` を受け取る。ゲートは 3 経路ともこれらを渡し、`.rite/state/adoption-history-{pr}-{kind}.json` に履歴を保存する。この履歴は一時的な判定記録と異なり cleanup で削除しない。

helper は同じ契約の過去 PR の履歴、または既存の `RECONCILE` を照合し、`reconciliation[]` に既存候補の `ids`、`fingerprint`、`signals`、`history`、`record`、`reason` を返す。ファイル名の一致だけでは裁定を起動しない。`signals` は照合の手がかりであり、意味上のトリガーを認定した結果ではない。

AC の履歴照合では、項目先頭のチェック状態だけを比較から除く。同じ Issue・AC ID・保証本文なら完了チェックの更新後も照合し、保証本文や Given/When/Then の変更は区別する。保存するキーと fingerprint にはチェック状態を含む原文を残すため、入力変更後の古い裁定回答は再利用しない。

ゲートは request を hold ファイルの `reconciliation[]` に保存する。親はここから対象を取得する。履歴は同じ契約かつ候補全文（id を除く）が同じ記録だけを置き換え、別の候補は保持する。各記録の元の HEAD は `entry.head`、受理した回答は `entry.reconciliation` に残る。履歴は採否記録であり、Issue 作成や台帳など外部への書き込みが成功した証拠ではない。

## 親の裁定

1. 親は request が指す現在の契約・候補の証拠・照合された履歴だけを読む。分類の独立したコンテキストが必要なら既存の分類役を使い、新しい reviewer は追加しない。候補 id が複数の記録に重複していたら、まず根因ごとに 1 記録へまとめてゲートから新しい request を得る。
2. 下表で意味上のトリガーと解決方法を認定する。単なる同一ファイルへの変更や語句の一致を、処分矛盾・再発・巻き戻しに置き換えない。
3. 対応する `adoption.records[]` の `reconciliation` に回答を書き、同じゲートを再実行する。判定記録や候補も直した場合は fingerprint が変わるため、先に新しい request を取得してから回答を作る。

| trigger | 認定条件 | resolution と処置 |
|---|---|---|
| `conflict` | 同じ契約・前提に対する処分が矛盾する | `fix_implementation` で実装修正、`change_contract` で契約変更を確認、または `consolidate` で既存の処分・追跡先へ統合 |
| `recurrence` | 検証済みの修正後に同じ契約へ再違反する | `fix_implementation` または `change_contract` のみ |
| `reversal` | 契約に関わる追加・削除・復元が過去の変更と逆向きになる | `fix_implementation` / `change_contract` / `consolidate` を選び、次に必要な観測点を `observations` に必ず書く |
| `none` | 上の意味上のトリガーに該当しない | `normal` のみ。通常の V/C/T 採否へ戻る |

回答は次の固定キーだけを持つ（新しい指摘・id・候補を混入させない）。

```json
{
  "fingerprint": "request の値",
  "trigger": "none",
  "resolution": "normal",
  "premise": "今回成立する前提",
  "reason": "トリガーと解決方法の判断理由",
  "evidence": "現在の契約と証拠・履歴の対応",
  "observations": ""
}
```

`premise` / `reason` / `evidence` は非空。`observations` は `reversal` 以外でもキーを残す（観測点がなければ空文字）。`resolution` は `normal` / `fix_implementation` / `change_contract` / `consolidate` のみ。

`signals` に `prior_conflict` があるときは `none` / `normal` で矛盾を無視できず、helper は `record_invalid` にする。前提と処分を照合してトリガーを認定するか、誤った判定記録を修正して新しい request を取得する。

`change_contract` は要件の決定が必要なので人間へ確認し、ゲートを保留したまま停止する。確認の依頼は、どの契約のどの要件を変えるか・なぜ AI では決められないか・どう判断するか（変える案と維持する案それぞれの帰結）・期待する回答を、前提知識のない人に分かる言葉で示す（[question_resolution](../skills/rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) 規則 6。人間が応答しない経路では規則 7）。`fix_implementation` は同じ PR の採否出口に従って修正する。マージ後など同じ PR で直せない場合も、元の出口の保留を解除しない。同じ前提の再掲は、既存の `prior` と、同じ根因を追跡する `tracker` があればそれに紐付けて `consolidate` する。未解決の ADOPT を再掲という理由だけで REJECT にしない。REJECT は引き続き `V=C=T=false` の場合だけで、裁定は採否条件を上書きしない。

## 保留と再開

未裁定・入力変更・契約変更はゲートが held にする。`hold.detail` / `hold.resume` が本書へ戻る入口、`hold.reconciliation[]` が request 本文になる。保留中は起票や完了通知へ進まず、元の caller の停止手順を守る。

fingerprint は HEAD、候補、`reconciliation` 以外の判定記録、現在の契約、照合した履歴に結び付く。Issue / PR 本文の引用では、引用片を保持した適用条件の変更も検出するため、引用元本文全体を fingerprint に含める。同じ入力でのみ回答を再利用できる。HEAD は無関係な変更でも再確認し、契約や履歴が変わった場合も新しい request に裁定を書き直す。過去履歴自体を書き換えて回答を一致させてはならない。
