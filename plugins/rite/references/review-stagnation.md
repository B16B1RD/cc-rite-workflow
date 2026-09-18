# レビュー停滞の診断と見直し

Issue に関連付いた通常 caller は `flow-state.sh review-start --stagnation --selection <絶対パス>` で run の診断記録を開始する。有効化後は同じ run の `--stagnation` を省略しない。時計・観測・検証済み修正・見直しは `review_context` の session / run / PR / cycle / HEAD に結び付け、同じ flow-state の `review_run` に保持する。通常の phase 更新・recover・停止で履歴や counter をリセットしない。関連 Issue がない standalone レビューは仕様入力を持たないため既存経路を維持する。

## 判定の順序

1. 所有者・HEAD・最新仕様・全 reviewer の回収・保存 receipt・実測証跡を検証する。破損、欠損、保存失敗、権限拒否を見直しで迂回しない。
2. 未完了 cycle は同じ cycle の回収・保存を再開する。完了済み cycle の欠損修復と既存の発散・回数 breaker を先に適用する。
3. 未観測を示す `action:observe` のまま先へ進めず、保存済み全指摘を観測し、`review_run.current_decision` の `action: continue|replan|stop` と `reasons: []` に従う。`continue` は通常の品質ゲートへ戻す意味で、merge の許可ではない。

観測時には元 receipt のハッシュと、既存 fatal triage helper がそのコピーから生成した派生 receipt のハッシュを保存する。以降はこの2種類だけを許可し、正規の分類後も観測・見直しの再送と履歴検証を継続できる。それ以外の証跡・指摘・受入条件の変更は拒否する。

iterate の全品質ゲートと non-blocking sweep の成功後、`flow-state.sh review-close` が現在の観測・receipt・未解決指摘・受入条件を確認して `review_run.completed_context` を保存する。返信のみで draft を残す場合は `review-defer` が `deferred_context` と `deferred_reason:replied-only` を保存する。後者は品質上の完了を意味せず、未解決指摘と判定を変更しない。phase・counter・履歴は維持する。次 Issue への切替時だけ旧 run を `review_run_history` に移すため、default draft batch は cleanup を挟まず継続できる。同じ Issue の再開や次 cycle には終了記録を流用しない。両コマンドとも未回収・観測欠損・見直し未完了・停止済み run を拒否する。停止済み run の具体的な停止理由は通常の終了通知でも上書きしない。

前回診断後の実作業が **1800 秒を超えた**場合は診断する。時間だけでは停止・merge・品質緩和を行わない。同じ根因が3観測に現れ、その間にその根因を対象とした検証済み修正と異なる HEAD が2回あれば見直す。同一 HEAD の再レビュー、未検証修正、別 run は再発回数を増やさない。

見直しは同一 run で最大2回。同じ観測で時間と再発が同時に成立しても1回とする。見直し後に根因が解消し受入条件の充足が進めば継続する。見直し後も同じ根因が2回の修正をまたいで再発し、受入条件の充足が進まなければ非収束として停止する。進展は見直し時の充足集合と比較し、その後に新たな充足が一度でも記録されれば、この非収束条件には該当しない。枠の消費や時間超過だけでは停止しない。範囲内解決不能は代替案と契約上の理由を保存して停止する。

## 時計の入力と運用

`flow-state.sh review-clock --input <絶対パスの JSON>` の入力:

| フィールド | 内容 |
|---|---|
| `review_context` | 現在 cycle の context の完全コピー |
| `segment_id` | 同一 run 内で一意の区間 ID。再送は同じ値 |
| `kind` | `work` / `external_wait` / `interruption` |
| `started_at`, `ended_at` | 実時計で取得した ISO 8601 時刻。開始・終了のある明示区間だけ加算 |

同一 ID・同一内容の再送は冪等で、異なる内容の上書きと区間の重なりは拒否する。`external_wait` と `interruption` は実作業に加算しない。reviewer の起動時刻、ファイルの保存間隔、run 開始からの差分だけで実作業時間を推定しない。

caller は以下の共有ブロックを工程境界で実行する。`{plugin_root}` は解決済み配布 root、`{clock_kind}` は上記3値、`{clock_close_mode}` は通常の `normal` または復旧時の `recover` へリテラル置換する。作業開始時に open、終了時と context を進める前に close する。CI 等の外部待機は work close → external_wait open、待機終了後は close → work open とする。

recover は保存済み open があれば先に `recover` で close する。`ended_at` が未保存の区間全体は `interruption` として閉じ、不明な中断時刻を推測しない。`ended_at` がある保存再試行では時刻・種類を変更しない。open が無い未確定 gap を補って実作業へ算入しない。

```bash
# review-clock-open
set -euo pipefail
clock_kind="{clock_kind}"
case "$clock_kind" in work|external_wait|interruption) ;; *) echo "ERROR: invalid review clock kind" >&2; exit 1 ;; esac
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: review clock session missing" >&2; exit 1; }
clock_context=$(jq -ce --arg sid "$session_id" '.review_cycle.review_context | select(type == "object" and .session_id == $sid)' "$fs_path") \
  || { echo "ERROR: review clock context missing or mismatched" >&2; exit 1; }
clock_file="$state_root/.rite/state/review-clock-$session_id.json"
mkdir -p "$(dirname "$clock_file")"
[ ! -e "$clock_file" ] || { echo "ERROR: review clock already open; close or recover it first" >&2; exit 1; }
clock_tmp=$(mktemp "$clock_file.XXXXXX")
trap 'rm -f "$clock_tmp"' EXIT
jq -n --argjson context "$clock_context" --arg id "$(basename "$clock_tmp")" \
  --arg kind "$clock_kind" --arg start "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{review_context:$context,segment_id:$id,kind:$kind,started_at:$start}' > "$clock_tmp"
# Hard-link publication is atomic and refuses an existing destination.
ln "$clock_tmp" "$clock_file"
```

```bash
# review-clock-close
set -euo pipefail
clock_close_mode="{clock_close_mode}"
case "$clock_close_mode" in normal|recover) ;; *) echo "ERROR: invalid review clock close mode" >&2; exit 1 ;; esac
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: review clock session missing" >&2; exit 1; }
clock_file="$state_root/.rite/state/review-clock-$session_id.json"
jq -e 'type == "object"' "$clock_file" >/dev/null \
  || { echo "ERROR: review clock open record missing or corrupt" >&2; exit 1; }
if ! jq -e 'has("ended_at")' "$clock_file" >/dev/null; then
  clock_tmp=$(mktemp "$clock_file.XXXXXX")
  trap 'rm -f "$clock_tmp"' EXIT
  jq --arg mode "$clock_close_mode" --arg end "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.kind = (if $mode == "recover" then "interruption" else .kind end) | .ended_at = $end' \
    "$clock_file" > "$clock_tmp"
  mv "$clock_tmp" "$clock_file"
fi
# Freeze ended_at before submission so a saved-but-not-removed retry is identical.
bash {plugin_root}/hooks/flow-state.sh review-clock --input "$clock_file"
rm "$clock_file"
```

## 観測と根因

`flow-state.sh review-observe --input <絶対パスの JSON> --issue <最新 Issue JSON の絶対パス>` を保存済みレビューに適用する。Issue JSON は `gh issue view --json number,body` で再取得し、取得失敗を古い snapshot で補わない。

| フィールド | 内容 |
|---|---|
| `review_context` | 保存済みレビューの context の完全コピー。観測の一意キー |
| `issue_number`, `issue_body` | 最新 Issue JSON の番号と本文の完全コピー |
| `roots[]` | `{defect,trigger,violated_contract,finding_ids}`。欠陥、再現条件、違反契約、保存済み指摘 ID の配列 |
| `acceptance` | `{satisfied:[文字列],evidence:文字列}`。保存済み受入条件表の充足済み `id` 集合と実測根拠 |

保存済み全 blocking finding を根因へ漏れなく対応付ける。helper は対応する `verification.measured=true` の `repro` / `failing_test` を保存結果からコピーする。表示ラベルだけの根因や caller が作った未測定の再現証跡を代用しない。同一観測の同一入力は冪等とし、異なる入力で履歴を上書きしない。

`acceptance.satisfied` は保存結果の `acceptance_criteria[]` のうち `status:satisfied`、または `status:human-verified` かつ `head` が保存結果の `commit_sha` と一致する行の `id` 集合に完全一致させる。各行の evidence は非空とする。受入条件表が `skipped:no_issue|no_ac_section` の場合は空配列、表の欠損は error とする。

欠陥・再現条件・違反契約の組が同じものを同一根因とする。親は過去の根因記述と照合し、言い換えや指摘 ID の変化だけで別根因にしない。解消は全指摘・実測の再現結果から判断し、指摘数の減少だけで扱わない。受入条件の識別文は同じ意味なら維持し、保存済み充足集合と最新仕様を照合する。同一 run で Issue 本文が変わった場合は旧仕様の進展を流用せず error とする。本文の照合（観測・`check` / `verify`・見直し・修正計画の gate の全経路で共通）は、`## 9. Decision Log` 節内のトリアージ書式行（`- YYYY-MM-DD D-NN: … / Reason: … / Impact: …`）と、行全体が `<!-- rite:nbr:comment-id:… -->` の行（非実測記録 helper が自分の marker と認める形。CRLF 行末・値の空白を含む）を除いて行う。この 2 種は rite 自身が review 中に Issue へ追記する記録であり、誰が書いたかを問わず仕様変更とみなさない（追記と同様に、これらの行の削除・差し替えも検出しない）。節は見出し行の完全一致で始まり、次の `## ` 見出し・`---`・`</details>`・本文末のいずれかで終わる（トリアージの追記先と同じ境界）。除外行と空行だけになった節は見出しごと除外し、除去した行が残す空行と本文末尾の改行は照合しない（本文末尾の空白は照合する）。コードフェンス（行頭の空白 3 つまでに続く 3 つ以上の backtick（後続に backtick を含まない行）または `~` で開き、同じ文字が同数以上並ぶ行で閉じる。閉じなければ本文末まで続く）内の行は除外も見出しの計数もしない。フェンス外で見出しが 2 回以上現れる本文は境界を一意に決められないため、除外せず原文どおり比較し、その理由を stderr に出す。節外の同書式行・自由書式の Decision Log 行・それ以外の HTML コメント・Goal / 受入条件の変更は仕様変更として error になる。観測に保存する `issue_body` は原文のまま置く。書式変更やラベル追加を進展とせず、新たな充足の実測根拠を `acceptance.evidence` に保存する。

## 見直し・修正・再開

`action=replan` のときは [一括修正計画](../skills/fix/references/fix-plan.md) に代替案・選択・再発防止検証を含め、`flow-state.sh review-replan --plan <絶対パス> --issue <最新 Issue JSON の絶対パス>` で保存する。通常の scope check は観測欠損・未完了の見直しを拒否する。見直しの保存前に編集を開始しない。

`review-fix-scope-check.sh verify --kind all` の成功時に検証済み tree fingerprint と対象根因を保存する。次の `review-start` で新 HEAD・clean tree と検証済み内容の一致を検査して修正 HEAD を確定し、再発判定に用いる。コマンドの成功申告、未検証の commit、別 context の結果を修正履歴に加えない。

停止は caller の既存失敗 sentinel へ返し、batch は cursor を当該 Issue に保ち `active=false` にする。PR・branch・作業差分・履歴・最後の検証済み状態を保持し、停止理由と復旧工程を報告する。同一 run の再開は保存済み判定と未完工程から続け、停止履歴を消して新しい見直し枠を作らない。

## 停止後の退路と再開

停止は「この run でのレビュー継続を止める」ことであり、「この run に触れる操作をすべて止める」ことではない。停止した run でレビューを進める操作は次の 2 つだけで、どちらも停止理由を消さない。

**抜ける（全停止理由で可）**: 別 Issue 番号の `set` をそのまま実行する。旧 run は `review_run_history` へ退避され、live state の `cycle_count` は 0 から始まる。停止は「この run はもう cycle を積まない」判断が下りた状態なので、完了・保留と同格に扱ってセッションを手放す。ownership cleanup を前置きしても同じ結果になる。

停止していない run は従来どおり完了・保留・ownership cleanup のいずれかを要求される。この緩和は停止した run に限る。

退避はセッションを手放すだけで停止を帳消しにしない。退避された記録は run（`status`・`stop_reason`・観測・修正履歴・使用済みの再試行権）に加えて、退避時点の `cycle_count` と、凍結 `review_cycle` があればそれも保持する。**同じ Issue 番号・同じ PR 番号へ戻る `set`（live state に run が無い状態から）は、その PR の退避記録のうち最も新しい停止済みのものを、そのまま復元する**（完了・保留で終わった run は復元しない — counter と観測は既に下りた判定に使い切っており、戻すと次のレビューへブレーカー予算を持ち越す） — 新しい run を作り直さないので、`review-start` は復元された停止理由で拒否され続け、counter もゼロから積み直されない。往復はどの停止理由でも解除にならない。復元された記録は履歴から取り除かれる。

**戻り方**: 復元を起こすのは Issue を切り替える `set`（PR 番号 0）ではなく、PR 番号と Issue 番号が揃う取り込み `set` である。したがって退避した PR へ戻る順序は、まず元 Issue へ着手し、続けてその PR の iterate へ入る 2 手になる。PR 番号だけを指定して別 Issue の state から入ると、退避記録の Issue 番号が一致しないため `set` が `archived review run for this PR belongs to another Issue or session` で止まる。

**復元直後の順序**: 復元された run は停止したままで、セッションも退避前と同じく非 active に戻る。通常の phase 更新はそこから拒否される（停止直後とまったく同じ挙動で、復元が新たに課す制約ではない）。先に再試行権を発行すれば、以後は通常の run として進む。

**復元できない退避記録は `set` を落とす**。同じ PR の停止した記録が、対の保存より前に作られていて `cycle_count` と凍結 `review_cycle` を持たない場合、および Issue 番号・`session_id` が一致しない場合は、読み飛ばさず停止理由を示して `set` を拒否する。読み飛ばすと、退避が差し止めているはずの新しい run をそのまま渡すことになる。停止していない記録は差し止めるものが無いので従来どおり読み飛ばす。

保持するのは `cycle_count` そのものであって凍結 context から導出した値ではない。凍結 `review_cycle` の有無に依らず counter は退避と復元を往復する。

この保持と復元はセッションの flow-state に載る。別セッション（別 `session_id`）では退避記録が見えないため、復元も再試行権の消費判定も効かない。`cycle_count` をはじめとする既存の counter と同じ性質である。

**再試行権で再開する（`circuit-breaker:divergence` のみ）**: `flow-state.sh review-retry --plan <一括修正計画の絶対パス> --issue <最新 Issue JSON の絶対パス>` が、次の条件をすべて満たすときに限り再試行権を 1 つ発行する。

1. `stop_reason` が `circuit-breaker:divergence` である。`circuit-breaker:max-cycles` と `stagnation:*` は再開できない
2. 停止時の context・HEAD・receipt・観測が一致し、変更されていない
3. 全 blocking 指摘に、通常の fix 経路と同じ計画内容の検証（状態遷移の許可判定を除く）を通る修正計画と検証項目が対応している。`review-fix-scope-check.sh check` そのものを前段として実行する必要はない — 同コマンドは停止した run では状態遷移の許可判定で拒否される
4. その run で再試行権が未使用である。権利は run に付いて回り、退避と復元を往復しても使用済みのまま戻る（完了・保留で終わった run は復元されないため、その PR の次のレビューは新しい run として始まる）

発行は条件をすべて検証したあとに一度だけ書き込む。1 つでも崩れていれば権利を発行せず、run は `stopped` のまま残る。人間の承認は条件に含めない。

発行すると `stop_reason` は run 直下から `review_run.retry.stop_reason` へ移り、`status` が `active` に戻る。権利が買えるのは fix → 検証 → review の 1 巡だけで、その review に blocking 指摘が残っていれば `retry.outcome=unresolved` を記録して元の停止理由で再停止する。残っていなければ `retry.outcome=resolved` として通常の run に戻る。いずれの場合も権利は再発行されない。決着は観測が行うため、観測を経ずに閉じた run や別経路で再停止した run では `outcome` は未確定のまま残る。

再試行権は退避された run にも復元された run にも等しく付いて回る。発行後の run は本当に `active` なので、`review-close` / `review-defer` も通常の run と同じ条件で通る。`close` は未解決 blocking と未充足受入条件を従来どおり拒否し、`defer` は返信のみの draft を残す既存の意味のままである。これは「停止した run を閉じられる」ことではなく、再試行権を発行した run がその 1 巡の間は通常の run として扱われるということで、権利の使用済み記録は `close` / `defer` / 退避のいずれを経ても残る。

再試行権は停止理由の解消認定ではない。計画の存在は収束を証明しないため、これは制限付きの再試行であって品質ゲートの解除ではない。`cycle_count` は run を通じて積み上がり続けるので、再試行を挟んでも最終的に再開不可の `circuit-breaker:max-cycles` に到達する。

helper が保証するのは context・保存証跡・入力構造・範囲・時計と回数・冪等性である。根因の意味的同一性、仕様解釈、受入条件の充足、代替案の妥当性は親の判断として根拠を残す。保証範囲は同梱 helper と通常 caller の経路に限り、任意の state 直接編集や未対応ホストの予告なし中断検出まで保証しない。
