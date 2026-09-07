ステップ 6 failure reasons (reason 表の本文は `common-error-handling.md#jq-required-fields-snippet-canonical` の canonical jq snippet を参照):

| reason (ステップ 5.1.2.A、pr-review.md 本文が emit) | Description |
|--------|-------------|
| `pr_number_placeholder_residue` | ステップ 5.1.2.A (fingerprint, `FINGERPRINT_COMPUTE_FAILED`) で `pr_number` が数値以外のとき emit。ステップ 6.1.a (`review-result-save.sh`, `LOCAL_SAVE_FAILED`) も同名 reason を emit する (下記 6.1.a bullet 参照) |

> **Note**: ステップ 6.1.a / 6.1.b / 6.1.c の reason は委譲先 helper が emit する (`hooks/review-result-save.sh` / `hooks/review-comment-post.sh` / `hooks/review-skip-notification.sh`、SoT は各 helper の docstring)。委譲済 reason は「この SKILL.md 自身が emit する reason」と区別できるよう **markdown table 行にせず bullet 形式**で列挙し、本文 prose でも `reason=...` 構文を使わず bare backtick 名で参照する。helper の stderr `[CONTEXT]` emit は caller の bash 出力として LLM コンテキストに surface するため、下記 reason はレビュー flow 上で従来どおり観測される。

**ステップ 6.1.a reasons** (`review-result-save.sh` が `[CONTEXT] LOCAL_SAVE_FAILED=1; reason=...` を emit。通常の環境・永続化失敗は従来どおり非ブロッキングだが、次の provenance 契約違反は非ゼロで停止する。`signal_aborted` も signal trap 由来の非ゼロを返す):
- `gate_not_applied`: `measured_gate` receipt が欠落または不正。実測ゲートを迂回した JSON のため保存しない
- `gate_record_mismatch`: `measured_gate.commit_sha` がトップレベル `commit_sha` と一致しないため保存しない
- `timestamp_not_injected`: 入力 JSON の `timestamp` が正規 placeholder でなく、helper 外で実値を書いたため保存しない
- `pr_number_placeholder_residue`: `--pr` が数値以外 (空文字 / placeholder 残留) のまま渡された (cleanup.md ステップ 6 の numeric gate と対称化し永久 orphan 化を防ぐ)
- `date_command_failure`: `TZ='Asia/Tokyo' date` の実行が失敗 (空 timestamp による file 上書きを防止)
- `mkdir_failure`: `.rite/review-results/` directory creation failed
- `mktemp_failure`: JSON tmpfile allocation failed
- `write_failure`: JSON content の tmpfile への書き込み失敗、または jq timestamp 注入 (`jq '.timestamp = $ts'`) の失敗。後者は注入が入力 JSON を parse するため発火する経路で、**syntactically invalid JSON / literal JSON body substitute 漏れの実検出 reason はこちら** (後続 `json_invalid` の `jq empty` より先に評価される)
- `timestamp_injection_mv_failure`: timestamp 注入後 inner mv (`mv "$json_ts_injected" "$json_tmp"`) が失敗 (sentinel 残留 JSON を final path に書かないため後続処理を skip)
- `json_invalid`: timestamp 注入成功後の `jq empty` post-condition backstop。注入段階 (`write_failure`) が入力 JSON を parse・再シリアライズして valid JSON を保証するため、syntactic invalidity はこの check に到達せず実際は `write_failure` として発火する。defense-in-depth の保険として残置 (effectively unreachable)
- `schema_required_fields_missing`: JSON は parse 可能だが必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型 / verdict が `mergeable`・`fix-needed` の 2 値 enum / reviewers[] が重複の無い非空配列) が欠落、または body が空白のみ (JSON 文書 0 件。**真に空の body は上流の非空検査が `write_failure` へ回すため本 reason には来ない**)。**実際に落ちた条件は helper が `欠落/不正:` 行で名指しする**ので、原因の特定には本列挙ではなく helper の出力を見る (同行に出るのは欠落キー名の列挙とは限らず、body 自体が評価できない形では `判定不能 (...)` のラベルが入る) (本列挙は helper 側の条件が増減すると古びうる。機械的に同期されているのは `reviewers[]` の一意性条項のみ)
- `guardrail_audit_log_keys_violation`: `guardrail_audit_log` が配列でない、または要素キー集合がスキーマ正 7 キー (`reviewer`, `filter_category`, `original_severity`, `file_line`, `description`, `filter_reason`, `verification`) と一致しない（空配列 `[]` は通る。余分・欠落は保存しない）
- `finding_id_format_or_uniqueness_violation`: **`findings[]` 側**の id が `^F-[0-9]{2,}$` 書式違反または重複 (`non_blocking_findings[]` 側に閉じた id 欠陥は非ブロッキング marker `NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION` に落ち、本 reason には計上されない)
- `scope_enum_violation`: schema 1.1.0 JSON で findings[].scope が enum 違反 (期待: `current-pr` / `follow-up` / `nit-noted`)
- `critical_high_scope_nit_noted_invariant`: schema 1.1.0 JSON で cross-field invariant #4 違反 (severity ∈ {CRITICAL, HIGH} × scope == nit-noted)
- `collision_resolution_exhausted`: 同一秒衝突回避 `~<4桁hex>` suffix を付与しても再衝突を検出 (同秒 3 回目以上 / `$RANDOM` fallback `0` / parallel race、後続 mv を skip して silent overwrite を防ぐ)
- `mktemp_failure_mv_err`: mv stderr 退避用 tempfile の mktemp が失敗 (mv 失敗時の stderr 詳細が失われるため explicit に通知)
- `mv_failure`: Atomic move of JSON tmpfile to final path failed
- `signal_aborted`: INT / TERM / HUP で中断された (`signal=` を併記)。cleanup だけを呼ぶと marker は消え `saved=false` は出るが reason が 1 件も出ず、ステップ 8.0.4 Routing の「`saved=false` なら reason を転記」が入力を持たないまま、既定 `post_comment: false` では ステップ 6.1.c が `--local-save-failed` だけを見てケース 1 に落ち**存在しないパスを「保存済み」として提示する**。sibling の `review-nonblocking-record.sh` が同 phase で同名 reason を持つのと同じ理由。signal trap 由来のため下記 Eval-order enumeration には載らない

**ステップ 6.1.b reasons** (`review-comment-post.sh` が `[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=...` を emit し、**hard error として ステップ 6 を fail**。例外: `post_comment_mode=false` 誤呼出は silent skip exit 0):
- `p61b_post_comment_mode_invalid`: `--post-comment-mode` が `true`/`false` 以外
- `p61b_pr_number_invalid`: `--pr` が literal substitute されていない / 数値以外 (`p61c_pr_number_invalid` と対称)
- `json_saved_from_p61a_unset`: `--json-saved` が `true`/`false` 以外 (ステップ 6.1.a の `[CONTEXT] JSON_SAVED=` 読取漏れ)
- `iso_timestamp_from_p61a_unset`: `--iso-timestamp` が ISO 8601 形状でない (sentinel 残留 / 空文字 / placeholder 形式 / 非 ISO 形状を allowlist で一括 reject — ステップ 6.1.a の `[CONTEXT] ISO_TIMESTAMP=` 読取漏れ)。ステップ 6.1.a の早期失敗 degraded 値 `unknown` も reject される (期待動作 — 再投入では解決せず、6.1.a の `LOCAL_SAVE_FAILED` reason の解消が必要。helper が専用診断を表示する)
- `tmpfile_write_failure`: PR コメント本文の中間 tmpfile (mktemp) 失敗、または `--content-file` 不在
- `raw_json_timestamp_injection_failed`: Raw JSON セクション内 sentinel の awk 置換 / post-condition (Raw JSON 内残留なし / Markdown 不変) が失敗
- `gh_comment_post_failure`: `gh pr comment` 投稿が exit != 0 で失敗 (network / auth / rate-limit / permission、rc>=128 時は signal 番号併記)

**ステップ 6.1.c reasons** (`review-skip-notification.sh` が `[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=...` を emit。ケース 2 の `p61c_persistence_unrecoverable` は **hard error として ステップ 6 を `exit 2` で fail**、その他の gate 違反は exit 1。正常経路 `post_comment_mode=false` は続行):
- `p61c_post_comment_mode_invalid`: `--post-comment-mode` が `false` 以外 (`true` 誤呼出 / 不正値、`p61b_post_comment_mode_invalid` と対称)
- `p61c_pr_number_invalid`: `--pr` が literal substitute されていない / 数値以外 (`p61b_pr_number_invalid` と対称)
- `p61c_file_timestamp_unset`: `--file-timestamp` placeholder が literal substitute されていない
- `p61c_file_timestamp_unknown_without_failure`: `file_timestamp='unknown'` だが `local_save_failed != '1'` (整合性違反、ケース 1 での `.../unknown.json` 誤提示を遮断)
- `p61c_local_save_failed_invalid`: `--local-save-failed` が不正値 (空文字/0/1 以外)
- `p61c_persistence_unrecoverable`: ケース 2 (`post_comment_mode=false` ∧ `LOCAL_SAVE_FAILED=1`) で silent data loss 防止のため ステップ 6 全体を `exit 2` で fail

**ステップ 6.1.d reasons** (`review-nonblocking-record.sh` が `[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=...` を emit。**記録の成否は `overall_assessment` を変えない** (AC-3)。ただし **result pattern を emit してよいかの可否**は別で、本文検査 4 段 (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`) と caller 契約違反 7 種では pending marker が残るため ステップ 8.0.3 が差し戻す。**caller 契約違反 7 種** (placeholder residue 5 種 + `content_file_missing` + `unknown_option`) は skill 定義のバグのため `exit 1` で loud に落とす。Non-blocking Contract の canonical 定義は [common-error-handling.md#non-blocking-contract-canonical-定義](../../../references/common-error-handling.md#non-blocking-contract-canonical-定義)、reason 語彙の SoT は helper docstring、gate 集合と Issue の MUST list の差分は [references/measured-gate-record.md#placeholder-gate-mapping](measured-gate-record.md#placeholder-gate-mapping) を参照):
- `pr_number_placeholder_residue`: `--pr` が数値以外 (`exit 1`)。**flag namespace が異なるため 6.1.a の同名 reason (`LOCAL_SAVE_FAILED`) とは別物** — 6.1.d は `NONBLOCKING_RECORD_FAILED` で emit する
- `owner_repo_placeholder_residue`: `--owner-repo` が allowlist を満たさない (`exit 1`)。ブレース残留・空白に加え、**3 セグメント `HOST/OWNER/REPO`**・パストラバーサル・許可外文字も拒否する (`gh -R` は先頭セグメントをホスト名として解釈するため、3 セグメント値は記録を別 GitHub インスタンスへ送出する)。reason 名は placeholder 由来だが trigger は「形式不正一般」であり、`pr_number_placeholder_residue` (数値以外すべて) と同じ粒度
- `non_blocking_count_placeholder_residue`: `--count` が数値以外 (`exit 1`)。0 件時も `--count 0` を明示的に渡す (空文字は substitute 漏れと区別できない)
- `iteration_id_placeholder_residue`: `--iteration-id` が未置換 (`exit 1`)。未置換のままでは gate の cycle 一致判定が恒久的に成立しない
- `content_file_placeholder_residue`: `--content-file` のパスにブレースが残留 (`exit 1`)。`body_file_empty` と融合させない (skill 定義のバグと本文生成失敗は復旧手順が異なる)
- `content_file_missing`: `--content-file` のパスにファイルが存在しない (`exit 1`)。step 1 の Write tool 呼び出し漏れ = caller 契約違反であり IO 失敗ではないため loud に落とす (非空検査に潰すと記録ゼロのまま gate が pass する)
- `body_file_empty`: 本文ファイルは存在するが空のため投稿を中止 (非ブロッキング、`exit 0`)。空 body の PATCH は 1 行目 marker を消し以降の lookup を恒久破綻させる。caller 契約違反のため **pending marker を残す** (8.0.3 が差し戻す)
- `body_marker_missing`: 本文 1 行目が marker 見出しで始まっていないため投稿を中止 (非ブロッキング、`exit 0`)。空 body と同じ破綻 (1 行目 marker の消失) を非空本文でも起こすため、`body_file_empty` と別 reason で検査する。caller 契約違反のため **pending marker を残す** (8.0.3 が差し戻す)
- `body_sentinel_missing`: 本文の**最終非空行**が機械専用 sentinel `<!-- rite:nbr:v1 -->` と一致しないため投稿を中止 (非ブロッキング、`exit 0`)。sentinel は lookup 述語の第 3 条件 (**最終非空行の等値**) であり、欠いた本文や sentinel を本文途中にだけ持つ本文を投稿すると次 cycle の lookup が自分の投稿を検出できず記録コメントが cycle ごとに増殖する (1 行目 marker 欠落と同じ結末を別条件で起こすため別 reason)。read 側が最終非空行の等値なので write 側も**同一の jq 述語**で検査する (片側だけ緩いと人間のコメントを掴んで破壊し、片側だけ厳しいと増殖する)。caller 契約違反のため **pending marker を残す**
- `body_check_unavailable`: 本文の最終非空行を算出する jq の**評価自体が失敗**した (jq 不在 / 実行不能 等の環境起因、非ブロッキング、`exit 0`)。`body_sentinel_missing` と発生位置は同じだが**原因が違う** — 本文を作り直しても解消しないため pending marker は**残さず**、gh / IO 起因と同じ無条件削除バケットに属する (8.0.3 は差し戻さない)。**ACTION**: jq の実行環境を確認する (`jq --version`)。本文の再生成は無効。stderr に jq の診断が転記されるので原因はそこを見る。
- `count_body_mismatch`: 本文中の `📎 non_blocking_count: {n}` 行の値と `--count` が不一致 (非ブロッキング、`exit 0`)。ステップ 6.1.d step 1 の本文 variant 選択と step 2 の `--count` 置換は LLM の 2 つの独立した置換であり、片方だけずれると事実と異なる記録が投稿される (`--count 0` + variant A 本文 で 0 件のはずが記録が無音で消える、あるいは逆に `--count N>0` + variant B「0 件」本文 で虚偽の記録が残る)。投稿を中止して非ブロッキングに `outcome=failed` へ倒すことで、両 gate (6.1.d step 3 / 8.0.3) の既存の転記条件に自動的に載せ、無音喪失/虚偽記録を observable にする。**ACTION**: caller (LLM) 起因で決定論的に再現するため (gh / network とは無関係)、step 1 の本文生成と step 2 の `--count` 置換を再確認し、6.1.d step 1-2 を再実行して記録を復旧する。**6.1.d step 3 と 8.0.3 の `**Check**` (prose 層) は `outcome` を問わず pass するが、8.0.3 の Pre-Check (機械強制) は pending marker 残存により `exit 1` で差し戻す。よって step 1-2 の再実行は必須であり、転記だけで済ませてはならない。** 差し戻しを強制する集合は exit-1 の caller 契約違反 7 種**に加えて本文検査 4 段** (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`) である
- `patch_failed`: 既存コメントの PATCH が失敗 (非ブロッキング、`exit 0`)。`rc=` / signal 終了時は `signal=` を併記
- `create_failed`: 新規コメント作成が失敗 (非ブロッキング、`exit 0`)。`rc=` / `signal=` は同上
- `unknown_option`: 未知のフラグが渡された (`exit 1`)。caller 契約違反であり、引数解析の途中で落ちるため `pr=` を伴わない
- `signal_aborted`: INT / TERM / HUP で中断された (`rc=` / `signal=` を併記)。terminal sentinel の `outcome=aborted` だけでは「helper が完走しなかった」ことしか読めないため、中断された事実を本 reason で loud に残す。**「未投稿」とは断定しない** — signal が `gh` の POST 実行中に届いた場合コメントは既に受理されていることがあり、helper には投稿完了状態を読む手段が無い。次 cycle の lookup + PATCH が自己修復する
- `related_issue_unresolved`: 関連 Issue を解決できない (closing keyword も `issue-{N}` branch 命名も無い、または PR body / headRefName の読取失敗)。trap 設置後のため terminal sentinel は `outcome=failed` で出る。pending marker は残さない (同 cycle 内で PR body / branch を直せないため差し戻しても収束しない)。**`exit 1`** で表面化する (silent skip しない)

**ステップ 8.0.3 reasons** (機械強制 = pending marker 検査。emit 元は helper ではなく **SKILL.md ステップ 8.0.3 の bash block 自身**。gate の可否のみを決め `overall_assessment` は変えない。本表を 8.0.3 節ではなくここに置くのは、8.0.3 節の表が TC-5e の gate 別 per-row pin の対象であり、同節に 2 つ目の表を置くと「gate 表」の同定が曖昧になるため):

| reason | flag | Description |
|--------|------|-------------|
| `pending_marker_absent` | `NONBLOCKING_GATE=pass` | marker が不在 = 6.1.d の helper が完走し EXIT trap で削除した。機械強制を通過 |
| `pending_marker_present` | `NONBLOCKING_GATE_FAILED=1` | marker が残存 = 6.1.d が本 cycle で完走していない、**または** caller 契約違反 (本文検査 4 段) で記録を拒否した。**`exit 1`** で落とし ステップ 6.1.d へ戻す (どちらかは `NONBLOCKING_RECORD_FAILED` の reason で判別する)。marker はここでは削除しない (削除すると 6.1.d を実行せず再評価だけで通せる) |
| `pending_marker_placeholder_residue` | `NONBLOCKING_GATE=degraded` | `{pending_marker}` が literal substitute されず `{...}` 形状のまま到達。機械強制を skip し `**Check**` の prose 判定のみで続行 |
| `pending_marker_unavailable` | `NONBLOCKING_GATE=degraded` | ステップ 6.1.a step 0 が marker を作成できなかった (read-only な `${TMPDIR}` 等、同 step で WARNING 済)。同上 |

**ステップ 8.0.4 reasons** (機械強制 = save-pending marker 検査 + 本 cycle 結果 JSON の実在検査。emit 元は **SKILL.md ステップ 8.0.4 の bash block 自身**と、そこから呼ばれる `hooks/scripts/review-save-json-verify.sh` (`save_result_json_*` の 2 種)。8.0.3 と同一形状で、gate の可否のみを決め `overall_assessment` は変えない):

| reason | flag | Description |
|--------|------|-------------|
| `save_pending_marker_absent` | `REVIEW_SAVE_GATE=pass` | marker が不在 = ステップ 6.1.a の helper が本 cycle で完走し EXIT trap で削除した。**marker 層としての**機械強制を通過 (gate 全体の可否は下記 positive 層と合わせて決まる) |
| `save_result_json_absent` | `REVIEW_SAVE_GATE_FAILED=1` | 本 cycle の commit SHA (ステップ 1.2.5) を `commit_sha` に持つ結果 JSON が現 run の results dir に**実在しない** (results dir 自体が無い場合を含む)。**`exit 1`** で落とし ステップ 6.1.a **step 0** へ戻す (**ただし会話に本 cycle の `REVIEW_SAVE_PENDING_MARKER` / `REVIEW_SAVE_PENDING_ID` が 1 つも無い場合の戻り先は ステップ 5.3.0.M step 2** — 6.1.a だけ再実行すると実測必須ゲートを走らせないまま JSON が再生成され、次の評価で本 gate が pass してしまう。helper の ACTION 行が SoT)。helper が期待 SHA と現 run の JSON 一覧 (basename + `commit_sha`) を stderr に出すため、「区間ごと未実行」と「本 cycle 分だけ未保存」を切り分けられる。**ファイルが 1 件でもあれば pass、にはしない** — 前 cycle の JSON で素通りするため。emit 元は `hooks/scripts/review-save-json-verify.sh` |
| `gate_record_mismatch` | `REVIEW_SAVE_GATE_FAILED=1` | トップレベル `commit_sha` が本 cycle と一致する JSON はあるが、同じ JSON の `measured_gate.commit_sha` が欠落または不一致。ステップ 5.3.0.M step 2 から再実行して receipt 付き JSON を保存する |
| `save_result_json_undecidable` | `REVIEW_SAVE_GATE=degraded` | positive 検査の入力・環境を揃えられない (`{pr_number}` / `{current_commit_sha}` の置換漏れ・形状不正、jq 不在、state root / run 開始点 pin を解決できない、results dir を**読めない**)。positive 層の機械強制のみ skip し `**Check**` の prose 判定へ続行。**置換漏れを fail にしない**のは、差し戻し先 (6.1.a) を何度実行しても直らず非収束ループになるため (`save_pending_marker_placeholder_residue` と同じ論拠)。WARNING で原因を名指しし、黙って pass にはしない。emit 元は同 helper |
| `save_pending_marker_present` | `REVIEW_SAVE_GATE_FAILED=1` | marker が残存 = 6.1.a が本 cycle で走っていない。**`exit 1`** で落とし ステップ 6.1.a **step 0** へ戻す。marker はここでは削除しない (削除すると 6.1.a を実行せず再評価だけで通せる)。**保存失敗では発火しない** — helper は `LOCAL_SAVE_FAILED` でも marker を削除するため (D-04 非ブロッキング契約の維持) |
| `save_pending_marker_placeholder_residue` | `REVIEW_SAVE_GATE=degraded` | `{save_pending_marker}` が literal substitute されず `{...}` 形状のまま到達。機械強制を skip し `**Check**` の prose 判定のみで続行 |
| `save_pending_marker_unavailable` | `REVIEW_SAVE_GATE=degraded` | ステップ 5.3.0.M step 2 が marker を作成できなかった (read-only な `${TMPDIR}` 等、同 step で WARNING 済)。同上 |

**Persistence error contract**: 従来の16種の環境・永続化 reason は `signal_aborted` を除き非ブロッキングのまま維持する。一方、`gate_not_applied` / `gate_record_mismatch` / `timestamp_not_injected` は JSON provenance の caller 契約違反なので helper が rc=1 を返し、ステップ 6 を停止する。未適用 JSON を会話コンテキストだけで先へ送る fallback は作らない。
