# Common Error Handling Patterns

Shared error patterns referenced by command files. When an error occurs, display the appropriate message, apply the recovery action, and decide whether to continue or abort.

## Standard Error Response Format

```
エラー: {summary}

考えられる原因:
- {cause_1}
- {cause_2}

対処:
1. {action_1}
2. {action_2}
```

## Common Patterns

### Entity Not Found (Issue / PR / Branch)

> `-R {owner_repo}` は [gh-cli-patterns.md の Owner/Repo Resolution](./gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）をリテラル置換する

| Entity | Message | Recovery |
|--------|---------|----------|
| Issue | `エラー: Issue #{number} が見つかりません` | Verify with `gh issue list -R {owner_repo}`, retry with correct number |
| PR | `エラー: PR #{number} が見つかりません` | Verify with `gh pr list -R {owner_repo}`, retry with correct number |
| Branch | `エラー: ブランチ {name} が見つかりません` | Verify with `git branch -a`, check spelling |

Common causes: wrong number/name, entity deleted, different repository.

### Permission Error

```
エラー: {entity} を変更する権限がありません

対処:
1. リポジトリへの書き込み権限を確認
2. `gh auth status` で認証状態を確認
3. 必要に応じて `gh auth login` で再認証
```

### Network / API Error

```
エラー: GitHub API への接続に失敗しました

対処:
1. ネットワーク接続を確認
2. `gh auth status` で認証状態を確認
3. しばらく待ってから再実行
```

For GraphQL API errors, retry up to 3 times with exponential backoff. See [GraphQL Helpers](./graphql-helpers.md#error-handling) for details.

### Projects API Error (Non-Blocking)

When Projects-related API calls fail, display a warning and continue. Projects operations are non-blocking.

```
警告: Projects API の呼び出しに失敗しました
{operation} をスキップします
```

## Environment Workaround Output Posture (canonical)

<a id="environment-workaround-output-posture"></a>

環境起因の制約への対処（sandbox 迂回・`dangerouslyDisableSandbox` 再実行・egress プロキシ断のリトライ・検証の代替経路など）の **人間向け出力姿勢** を定義する。本文は本セクションのみを SoT とする。各スキルは本規則を複製せず、1 行参照に留める（drift 防止）。

**規則**:

| 条件 | 人間向け出力 |
|------|-------------|
| **(a) 成功** — 迂回・リトライ・代替経路の結果、処理が完了した | **無言**。完了報告・進捗表示に迂回の前置き・背景解説・仕組みの説明を含めない（「サンドボックスの制約を先に共有します」等の定型前置きを含む） |
| **(b) 失敗** — 対処しても失敗が残り、人間の行動が必要 | **行動可能な 1 行のみ**（何をすればよいか）。プロキシの仕組み・診断過程・環境の背景説明は書かない |
| **(c) 機械可読経路** | `[CONTEXT]` marker は従来どおり emit する（監査・後段 routing 用。本規則は人間向け散文のみを対象とする） |

ユーザー可視メッセージには rite 開発リポジトリ固有の Issue / PR 番号を出さず、番号が担っていた理由・条件・対処を自己完結した文で示す。番号の出所は commit / PR body に置く。

**不変条件**:

- **fail-loud は不変** — 沈黙化するのは「成功した迂回の説明」であって、失敗の隠蔽ではない
- **権限ゲート自体は対象外** — `dangerouslyDisableSandbox` の確認 UI 等は Claude Code の管轄。本規則は narration（説明文）のみ
- **対処の機構は別 Issue** — リトライ回数・代替経路の実装は各スキル / helper が持つ（例: cleanup は ls-remote の一時的失敗に対して 1 回だけ再試行する）。本規則は「成功後にそれをどう語るか」だけを規定する

**適用対象（優先）**: ネットワーク git / sandbox 迂回を行うスキル（`cleanup` / `merge` / `ready` / `iterate` / `open` / `batch-run` 等）。新規スキルで同様の迂回を行う場合も本セクションを 1 行参照すること。

## Non-blocking Contract (canonical 定義)

「Non-blocking Contract」とは、特定の sub-phase の失敗が **upstream phase 全体を失敗扱いにしない** ことを保証する設計上の契約。`/rite:pr-review` ステップ 6.1.a (ローカル JSON 保存) や `/rite:cleanup` ステップ 6 (review 結果ファイル削除、旧 Phase 2.5) など複数 phase で参照される。両方とも本セクションの定義を SoT とすること。

**契約の構成要素**:

| 観点 | 規約 |
|------|------|
| **失敗時の戻り値** | sub-phase は WARNING を stderr に出して `exit 0` で early return する (upstream の `||` chain を発火させない)。`set -e` 環境下でも upstream を kill しない |
| **retained flag emit** | `[CONTEXT] {SCOPE}_FAILED=1; reason={reason}` を stderr に必ず emit する。reason 値は各 phase の reason 表で列挙される |
| **IO エラーの可視化** | ファイル不在は silent no-op で OK だが、`rm` / `mkdir` / `mv` 等の **真の IO 失敗** (permission denied / disk full / readonly filesystem) は WARNING + stderr 5 行以上で必ず可視化する。`2>/dev/null` 等の silent suppression は禁止 |
| **ステップ全体の exit code** | 本 sub-phase 単独の失敗では ステップ全体の exit code を変更しない。downstream の ステップ は retained flag を見て分岐する |
| **判定値と emit 可否の分離 (carve-out)** | 本契約が保証するのは **判定値 (`overall_assessment` 等) を変えない**ことであって、**その判定値を result pattern として emit してよいか**までは保証しない。記録・保存の失敗のうち caller が入力を作り直せば収束するものは、判定値を変えないまま pending marker を残し、後段の gate が emit を差し戻すことがある。**caller 起因の**差し戻しは 1 iteration で収束するため retry 上限を持たない。どの reason が marker を残すか・その exit code・sub-phase 間の非対称は下記「適用箇所」を参照 (6.1.a と 6.1.d で異なる) |
| **observability emit の必須化** | 異常終了経路 (signal trap 経由含む) でも `[CONTEXT]` flag が emit されるよう、trap handler 内で flag emit を行う (skip notification phase が flag を読む前提で動作する) |

**適用箇所**:
- `/rite:pr-review` ステップ 6.1.a (Local JSON File Save — 15 種の `LOCAL_SAVE_FAILED` reason のうち **14 種は `exit 0`** の完全な非ブロッキング。`signal_aborted` のみ signal trap 由来で rc=130/143/129 を返すが、reason emit と marker 削除は他 14 種と同一 (ステップ 6 の exit code は 6.1.c が決める)。**save-pending marker は保存の成否に依らず EXIT trap で削除する** — 成功時のみ削除すると本契約が ステップ 8.0.4 経由で blocking gate に化ける。marker path は caller から受け取らず `--pending-id` から helper 内で導出するため、caller 由来の任意 path が削除対象になる経路そのものが存在しない。marker が残るのは (i) trap 設置**前**の `exit 1` (`--content-file` 未指定 / unknown option) と `--pending-id` の形状違反で path を導出できなかった場合、(ii) `rm` 自体が失敗した場合の 2 群。(i) は caller 側を直せば 1 iteration で収束するのに対し、(ii) は環境起因で再実行では収束せず手動削除を要する。**`--pr` 欠落 / 非数値 (`pr_number_placeholder_residue`) と `--content-file` 不在 (`write_failure`) は marker を残さない** — どちらの gate も trap 設置**後**の `exit 0` のため marker は削除され、可視化は 6.1.c ケース 2 が担う。直下の 6.1.d はこの 2 つに対応する `pr_number_placeholder_residue` / `content_file_missing` をいずれも exit-1 + marker 残存の群に置くため、**6.1.a はこの 2 点で非対称**)
- `/rite:pr-review` ステップ 6.1.d (非実測指摘の関連 Issue コメント記録 — **3 群で帰結が異なる**。gh / IO 失敗 (`patch_failed` / `create_failed` / lookup degraded / `body_check_unavailable`) と signal 中断 (`signal_aborted`) は完全に非ブロッキングで、pending marker も削除する。本文不備 4 種 (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`) は `exit 0` かつ `overall_assessment` 不変だが **pending marker を保持し ステップ 8.0.3 が result pattern の emit を差し戻す** (caller 契約違反の再試行で 1 iteration 収束)。placeholder residue 5 種 + `content_file_missing` + `unknown_option` の 7 種は caller 契約違反として `exit 1` し、同じく marker が残る。**第 3 群: trap 設置後の `related_issue_unresolved` は exit 1 で表面化するが pending marker は残さない** (同 cycle 内で PR body / branch を直せないため差し戻しても収束しない。caller は rc=1 を skill 全体の hard fail と読まず sentinel の `outcome=failed` を読んで続行する)。**marker 削除自体の `rm` 失敗は上記いずれとも別群**で、marker が残り 8.0.3 が差し戻す — 環境起因のため再実行では収束せず手動削除を要する。6.1.a と異なり helper 側の検出・WARNING は無く無音で起きる)
- `/rite:cleanup` ステップ 6 (Review Results File Cleanup、旧 Phase 2.5)
- 将来追加される sub-phase で「失敗しても upstream を kill しない」契約が必要なものは本セクションを参照すること

**Soft failure との違い**: `/rite:fix` ステップ 4.5 で使用される「soft failure」は **致命的だが exit 1 で fix loop を kill せず retained flag で caller に通知する**パターンで、本 Non-blocking Contract と類似する。両者の違いは: Non-blocking Contract は「sub-phase 失敗 = upstream 続行」で **本来非致命的な処理** (ローカル保存、削除) に適用、soft failure は「致命的だが loop 終了させない」で **コミット済み変更を保護したい** ケースに適用する。

**例外: ステップ内の retained flag 集計による hard fail 昇格**: Non-blocking Contract に従う sub-phase が複数存在し、それらの retained flag を ステップ内の後段 sub-phase (例: `/rite:pr-review` ステップ 6.1.c) が集計して `exit 2` 等の hard fail に昇格させることは許容される。この場合、個々の sub-phase は `exit 0` (Non-blocking) を守るが、**ステップ全体として** retained flag の組み合わせにより hard fail するケースが発生しうる。これは Non-blocking Contract の違反ではなく、「sub-phase 単独の失敗」と「ステップ全体の判定」が別レイヤであるという設計上の意図的な区別である。

## [CONTEXT] Emit: stdout / stderr 2 系統の使い分け (canonical)

<a id="context-emit-stdout-stderr-convention-canonical"></a>

`[CONTEXT]` marker を emit する bash block は、目的に応じて **系統 A: retained-flag / 引数解析系 emit（stderr）** と **系統 B: 後続 phase への状態受け渡し emit（stdout）** の 2 系統に分かれる。この使い分けは pre-existing の運用規約として複数 skill (`fix.md` / `pr-review.md` / `iterate.md` / `wiki-lint.md` 等) に存在していたが、明文化された SoT が無かったため、過去にコメント転記時に規約の主張範囲が誤って拡大され、実際の stdout emit 箇所と矛盾する記述が生まれたことがあった。本セクションはその根本原因 (規約の SoT 不在) を解消する。

### 系統 A: retained-flag / 引数解析系 emit（stderr）

**用途**:
- sub-phase の失敗を示す retained flag: `[CONTEXT] {SCOPE}_FAILED=1; reason={reason}`。exit code により 2 パターンに分かれる — **(a) soft failure** (致命的だが loop を kill せず caller に通知): `exit 1` の直前で emit する。**(b) [Non-blocking Contract](#non-blocking-contract-canonical-定義)** (本来非致命的な処理の失敗): `exit 0` の直前で emit する。いずれのパターンも retained flag 自体は stderr に emit される
- 同一 bash block が失敗パスでユーザー向け `エラー:` / `WARNING:` メッセージも stderr に出力する引数解析ルーチンで、その解析結果 (成功パスの値も含む) を emit する場合

**なぜ成功パスの値も stderr に乗るのか**: 引数解析ルーチンは失敗パスで `エラー: ...` を stderr に出力する。同一ルーチン内の `[CONTEXT]` emit を全て stderr に統一することで、診断出力とデータ受け渡しが同一チャネルに局所化され、ルーチン全体の出力を 1 箇所 (stderr) で追跡できる。例: `fix.md` ステップ 1.0.1 の `--review-file` 引数解析では、失敗パスの `FIX_FALLBACK_FAILED=1` と成功パスの `REVIEW_FILE_PATH=...` / `REMAINING_ARGS=...` が両方とも stderr に emit される。

**命名規約**: retained flag は `{SCOPE}_FAILED=1; reason={reason}` 形式 (例: `FIX_FALLBACK_FAILED`, `REVIEW_SOURCE_PARSE_FAILED`, `POST_REVIEW_VERIFY_FAILED`)。reason 値は当該 phase の reason 表で列挙する。

### 系統 B: 後続 phase 状態受け渡し系 emit（stdout）

**用途**: Bash tool 呼び出し境界を越えるとシェル変数が保持されないため、後続の Bash block や LLM の分岐判断が必要とする値・enum・sentinel を emit する。判別軸は「失敗か成功か」でも「後続 phase が読むかどうか」でもない — 系統 A の引数解析ルーチンの成功パス値 (例: `REVIEW_FILE_PATH`) も、別の bash block (`fix.md` ステップ 1.2.0 Priority 0) が会話コンテキスト経由で後から読むため、両系統とも Bash tool 呼び出し境界を越えて消費される点は共通である。真の判別軸は「同一 bash block 内でユーザー向け診断メッセージ (`エラー:` / `WARNING:`) と同じ stderr チャネルに併置されるか」である。系統 A は診断メッセージと同居する (引数解析の失敗パスの `エラー:` と併記、または Non-blocking Contract の retained flag 自体が診断情報の一部)。系統 B は CONTEXT emit 自体が診断メッセージと同一 stderr チャネルに置かれない (stdout に置かれる) 純粋な状態伝達であり、`WIKI_INGEST_FAILED` のような失敗ステータスも、近傍に `WARNING:` 等の診断メッセージが存在しても、CONTEXT emit 自体が別チャネル (stdout) に置かれる限り系統 B に含まれる。

**代表例**: `doc_heavy_pr` (pr-review.md ステップ 1.2.7)、`WT_ENSURE` (`lib/worktree-git.sh` ensure-session-worktree)、`WIKI_INGEST_DONE` / `WIKI_INGEST_SKIPPED` / `WIKI_INGEST_FAILED` (pr-review.md ステップ 6.5.W、cleanup.md ステップ 9 — `WIKI_INGEST_FAILED` は失敗ステータスだが、CONTEXT emit 自体は stdout に置かれ診断メッセージ (stderr) と同一チャネルに併置されないため系統 B に分類される)、`ROOT_CAUSE_GATE`、`ITERATE_ISSUE` / `ITERATE_CYCLE_MAX` (iterate.md ステップ 0/0.6)、`lint_action` (wiki-lint.md ステップ 8.1)。

**注意**: `_FAILED=1; reason=...` という命名シェイプだけでは系統 A/stderr を意味しない。系統 A の命名規約 (前節) と同じ形をした `WIKI_INGEST_FAILED` は系統 B/stdout である。系統の判別は必ず下記の判定ルール表 (診断メッセージと同一 stderr チャネルでの併置の有無) で行うこと。

**詳細パターン**: enum 値・begin/end marker block・legitimate-absence 判定などの具体的な実装パターンは [`bash-cross-boundary-state-transfer.md`](../skills/wiki-lint/references/bash-cross-boundary-state-transfer.md) を参照 (現状 wiki-lint/wiki-ingest 発の文書だが、Pattern 1-3 は系統 B 全般に適用可能な汎用パターンとして書かれている)。

### 判定ルール (新規 bash block を書く際)

| 状況 | emit 先 |
|------|---------|
| 失敗パスで retained flag を emit する (soft failure: `exit 1` 直前 / Non-blocking Contract: `exit 0` 直前) | stderr (`{SCOPE}_FAILED=1; reason=...`) |
| 同一 bash block が失敗パスで `エラー:` / `WARNING:` をユーザー向けに出力し、その `[CONTEXT]` emit 自体も同じ stderr チャネルに併置して成功パスの値も後続処理へ渡す (引数解析等) | stderr (ブロック全体で統一) |
| 純粋な状態計算 (成功/enum/sentinel) で、エラーメッセージを伴わない | stdout |
| 列挙値・集合を伝達する | stdout (begin/end marker、[`bash-cross-boundary-state-transfer.md`](../skills/wiki-lint/references/bash-cross-boundary-state-transfer.md#pattern-2-marker-delimited-multi-value-block) 参照) |
| 失敗/skip ステータスだが、CONTEXT emit 自体はユーザー向け診断メッセージ (`エラー:` / `WARNING:`) と同一 stderr チャネルに併置されない (近傍に WARNING があっても別チャネル。例: `WIKI_INGEST_FAILED`) | stdout |

**両系統に共通する規約**: `[CONTEXT]` prefix を必ず付与し、LLM が `grep` で決定論的に抽出できる `key=value` 形式 (`; ` 区切りで複数フィールド可) にする。stdout/stderr いずれも Bash tool の会話コンテキストに取り込まれるため、grep 側は redirect 先を区別せず literal prefix で検索すればよい。

## Review Result JSON Schema Validation (canonical snippet)

<a id="jq-required-fields-snippet-canonical"></a>

`review-result-schema.md` で定義される JSON スキーマの必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) を検証する canonical jq snippet。ステップ 6.1.a (pr-review.md) と ステップ 1.2.0 Priority 0 / 2 / 3 (fix.md) の 4 箇所から参照される (verified-review cycle 8 M-8 対応で canonicalize)。

**Canonical snippet** (jq 式):

```jq
(.schema_version | type == "string" and length > 0)
and (.pr_number | type == "number")
and (.findings | type == "array")
```

**Usage sites** (drift 防止のため新規箇所追加時は本リストに登録すること):

| Site | Purpose | Failure Reason |
|------|---------|----------------|
| `pr-review.md` ステップ 6.1.a | JSON tmpfile の post-condition 検証 | `schema_required_fields_missing` |
| `fix.md` ステップ 1.2.0 Priority 0 (`--review-file`) | ユーザー明示ファイルの必須フィールド検証 | `explicit_file_schema_required_fields_missing` |
| `fix.md` ステップ 1.2.0 Priority 2 (local file) | 最新 timestamp ファイルの必須フィールド検証 | `local_file_schema_required_fields_missing` |
| `fix.md` ステップ 1.2.0 Priority 3 (PR comment Raw JSON) | PR コメント Raw JSON の必須フィールド検証 | `pr_comment_schema_required_fields_missing` |

**Rationale for type-explicit validation**: jq の and / truthiness 仕様 (`false` / `null` のみが falsy、空文字列 `""` / `0` / `[]` / `{}` はすべて truthy) のため、旧実装の `.schema_version and .pr_number` は `schema_version: ""` や `pr_number: "123"` (文字列型) を silent pass させる抜け穴があった。明示的に `type == "string" and length > 0` / `type == "number"` / `type == "array"` を要求することで、型違反と空文字列のすべてを reject する。

**Source検証**: [jq Manual](https://jqlang.org/manual/) — "false and null are considered 'false values', and anything else is a 'true value'. Everything else is 'true', even the number zero and the empty string, array and object." (`jq --help` or interactive `jq .` で確認可能)

**merge ゲート必須キーの validation (ステップ 6.1.a のみ追加検証)**: 本 canonical snippet に加えて ステップ 6.1.a では `verdict` (`mergeable` / `fix-needed` の 2 値 enum) と `reviewers[]` (重複の無い非空配列) も検証し、欠落・不正を同じ `schema_required_fields_missing` で拒否する。merge ゲート (`hooks/pre-tool-bash-guard.sh`) がこの 2 キーを読むため、write 側で満たしていない JSON は保存しても merge できない。本 snippet 側を 3 件のまま据え置くのは、read 側 3 サイト (fix.md Priority 0 / 2 / 3) が書込済み JSON を信頼する設計で、snippet を広げると read 側が誤って厳格化されるため。契約の SoT は [review-result-schema.md §verdict と reviewers](./review-result-schema.md#verdict-と-reviewers)。

**Finding ID validation (ステップ 6.1.a のみ追加検証)**: 本 canonical snippet に加えて ステップ 6.1.a では finding id の書式 (`^F-[0-9]{2,}$`) と一意性も検証する。これは write 側 (pr-review.md) でのみ enforce される「生成規則」であり、read 側 (fix.md) では既に書き込まれた JSON を信頼するため検証不要。

検証は **2 段**に分かれる。`findings[]` 側の欠陥のみが hard fail (`JSON_SAVED=false`) で、`non_blocking_findings[]` 側に閉じた欠陥は非ブロッキング marker に落とす — advisory な監査記録の欠陥を理由に blocking findings ごと保存を失う fail-unsafe を避けるため (review-result-schema.md §non_blocking_findings 配列)。

```jq
# (1) findings[] 側 — hard fail (reason=finding_id_format_or_uniqueness_violation)
# 左辺は括弧で束縛する。`[.findings[].id] | unique | length == (.findings | length)` と書くと
# パイプ後の `.` が unique 済み配列になり "Cannot index array with string findings" で rc=5 になる
(.findings | length == 0)
or (
  (.findings | all(.id? // "" | test("^F-[0-9]{2,}$")))
  and (([.findings[].id] | unique | length) == (.findings | length))
)
```

```jq
# (2) 和集合 (findings[] ∪ non_blocking_findings[]) — 非ブロッキング
#     marker: NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION
# 非配列は空配列に畳む ($nb)。畳まないと length が非 0 になる型 ("abc"→3 / 3→3 / {"a":1}→1) が
# $total を水増しし、非ブロッキングと宣言した経路が型によって hard fail に化ける
((if (.non_blocking_findings | type) == "array" then .non_blocking_findings else [] end)) as $nb
| ((.findings | length) + ($nb | length)) as $total
| ($total == 0)
or (
  ([(.findings[]?, $nb[])] | all(.id? // "" | test("^F-[0-9]{2,}$")))
  and (([(.findings[]?, $nb[]) | .id] | unique | length) == $total)
)
```

Failure reason: `finding_id_format_or_uniqueness_violation` ((1) のみ。(2) は reason ではなく observability marker)

## Hook Lock-Contention Classification (canonical)

<a id="hook-lock-contention-classification-canonical"></a>

`local-wm-update.sh` / `issue-comment-wm-sync.sh` などの hook が stderr に出力するメッセージから「lock contention (best-effort skip 許容)」と「non-lock failure (WARNING + stderr 表示義務)」を分類する canonical pattern。`pr-review.md` ステップ 6.2 / 6.4 と `fix.md` ステップ 5.1 の 3 箇所から参照される (verified-review cycle 12 H-1 対応で canonicalize)。

**Canonical pattern** (grep 式):

```bash
grep -qiE '(file is locked|lock contention|resource busy)' "$err_file"
```

**Usage sites** (drift 防止のため新規箇所追加時は本リストに登録すること):

| Site | Purpose |
|------|---------|
| `pr-review.md` ステップ 6.2 Step 2 (`issue-comment-wm-sync`) | ステップ遷移時の backup sync |
| `pr-review.md` ステップ 6.4 (`_rite_review_p64_run_sync` helper) | ステップ 6.4 の 3 step 全てで本 helper が参照 |
| `fix.md` ステップ 5.1 (`local-wm-update.sh`) | E2E flow 経路の post-fix local work memory 更新 |

**Rationale for exact phrase match**: 旧 loose pattern `grep -qiE 'lock|contention|busy'` は以下の silent suppression 問題を抱えていた:

- `permission denied` を含むメッセージは match しないが、hook が `"device busy"` / `"resource busy"` / `"file is busy"` を emit するとすべて silent に「lock contention best-effort skip」に落ちていた
- NFS timeout のメッセージに `"busy"` が含まれる経路
- 将来 hook の error message が翻訳や refactor で `"locked directory"` 等に変わった場合の false-positive 拡大 (単語単位 substring match は脆い)

これらを防ぐため、exact phrase match の厳格化された regex に統一する (cycle 10 S-1 で `pr-review.md` の Step 2 以外には適用されたが、本 cycle 12 H-1 で 4 箇所全てに波及)。

**Non-lock failure (本 pattern が match しない) 時の責務**: WARNING + hook stderr 先頭 5 行の表示 (`head -5 "$err_file" | sed 's/^/  /' >&2`)、および「対処: hook の存在 / 実行権限 / 内容を確認してください」の案内を追加する。詳細は各 Usage site の実装例を参照。
