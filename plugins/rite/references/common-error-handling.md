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

| Entity | Message | Recovery |
|--------|---------|----------|
| Issue | `エラー: Issue #{number} が見つかりません` | Verify with `gh issue list`, retry with correct number |
| PR | `エラー: PR #{number} が見つかりません` | Verify with `gh pr list`, retry with correct number |
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

## Non-blocking Contract (canonical 定義)

「Non-blocking Contract」とは、特定の sub-phase の失敗が **upstream phase 全体を失敗扱いにしない** ことを保証する設計上の契約。`/rite:pr:review` Phase 6.1.a (ローカル JSON 保存) や `/rite:pr:cleanup` Phase 2.5 (review 結果ファイル削除) など複数 phase で参照される。両方とも本セクションの定義を SoT とすること。

**契約の構成要素**:

| 観点 | 規約 |
|------|------|
| **失敗時の戻り値** | sub-phase は WARNING を stderr に出して `exit 0` で early return する (upstream の `||` chain を発火させない)。`set -e` 環境下でも upstream を kill しない |
| **retained flag emit** | `[CONTEXT] {SCOPE}_FAILED=1; reason={reason}` を stderr に必ず emit する。reason 値は各 phase の reason 表で列挙される |
| **IO エラーの可視化** | ファイル不在は silent no-op で OK だが、`rm` / `mkdir` / `mv` 等の **真の IO 失敗** (permission denied / disk full / readonly filesystem) は WARNING + stderr 5 行以上で必ず可視化する。`2>/dev/null` 等の silent suppression は禁止 |
| **Phase 全体の exit code** | 本 sub-phase 単独の失敗では Phase 全体の exit code を変更しない。downstream phase は retained flag を見て分岐する |
| **observability emit の必須化** | 異常終了経路 (signal trap 経由含む) でも `[CONTEXT]` flag が emit されるよう、trap handler 内で flag emit を行う (skip notification phase が flag を読む前提で動作する) |

**適用箇所**:
- `/rite:pr:review` Phase 6.1.a (Local JSON File Save)
- `/rite:pr:cleanup` Phase 2.5 (Review Results File Cleanup)
- 将来追加される sub-phase で「失敗しても upstream を kill しない」契約が必要なものは本セクションを参照すること

**Soft failure との違い**: `/rite:pr:fix` Phase 4.5 で使用される「soft failure」は **致命的だが exit 1 で fix loop を kill せず retained flag で caller に通知する**パターンで、本 Non-blocking Contract と類似する。両者の違いは: Non-blocking Contract は「sub-phase 失敗 = upstream 続行」で **本来非致命的な処理** (ローカル保存、削除) に適用、soft failure は「致命的だが loop 終了させない」で **コミット済み変更を保護したい** ケースに適用する。

**例外: Phase 内の retained flag 集計による hard fail 昇格**: Non-blocking Contract に従う sub-phase が複数存在し、それらの retained flag を Phase 内の後段 sub-phase (例: `/rite:pr:review` Phase 6.1.c) が集計して `exit 2` 等の hard fail に昇格させることは許容される。この場合、個々の sub-phase は `exit 0` (Non-blocking) を守るが、**Phase 全体として** retained flag の組み合わせにより hard fail するケースが発生しうる。これは Non-blocking Contract の違反ではなく、「sub-phase 単独の失敗」と「Phase 全体の判定」が別レイヤであるという設計上の意図的な区別である。

## Review Result JSON Schema Validation (canonical snippet)

<a id="jq-required-fields-snippet-canonical"></a>

`review-result-schema.md` で定義される JSON スキーマの必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) を検証する canonical jq snippet。Phase 6.1.a (review.md) と Phase 1.2.0 Priority 0 / 2 / 3 (fix.md) の 4 箇所から参照される (verified-review cycle 8 M-8 対応で canonicalize)。

**Canonical snippet** (jq 式):

```jq
(.schema_version | type == "string" and length > 0)
and (.pr_number | type == "number")
and (.findings | type == "array")
```

**Usage sites** (drift 防止のため新規箇所追加時は本リストに登録すること):

| Site | Purpose | Failure Reason |
|------|---------|----------------|
| `review.md` Phase 6.1.a | JSON tmpfile の post-condition 検証 | `schema_required_fields_missing` |
| `fix.md` Phase 1.2.0 Priority 0 (`--review-file`) | ユーザー明示ファイルの必須フィールド検証 | `explicit_file_schema_required_fields_missing` |
| `fix.md` Phase 1.2.0 Priority 2 (local file) | 最新 timestamp ファイルの必須フィールド検証 | `local_file_schema_required_fields_missing` |
| `fix.md` Phase 1.2.0 Priority 3 (PR comment Raw JSON) | PR コメント Raw JSON の必須フィールド検証 | `pr_comment_schema_required_fields_missing` |

**Rationale for type-explicit validation**: jq の and / truthiness 仕様 (`false` / `null` のみが falsy、空文字列 `""` / `0` / `[]` / `{}` はすべて truthy) のため、旧実装の `.schema_version and .pr_number` は `schema_version: ""` や `pr_number: "123"` (文字列型) を silent pass させる抜け穴があった。明示的に `type == "string" and length > 0` / `type == "number"` / `type == "array"` を要求することで、型違反と空文字列のすべてを reject する。

**Source検証**: [jq Manual](https://jqlang.org/manual/) — "false and null are considered 'false values', and anything else is a 'true value'. Everything else is 'true', even the number zero and the empty string, array and object." (`jq --help` or interactive `jq .` で確認可能)

**Finding ID validation (Phase 6.1.a のみ追加検証)**: 本 canonical snippet に加えて Phase 6.1.a では finding id の書式 (`^F-[0-9]{2,}$`) と一意性も検証する。これは write 側 (review.md) でのみ enforce される「生成規則」であり、read 側 (fix.md) では既に書き込まれた JSON を信頼するため検証不要。

```jq
(.findings | length == 0)
or (
  (.findings | all(.id? // "" | test("^F-[0-9]{2,}$")))
  and ([.findings[].id] | unique | length == (.findings | length))
)
```

Failure reason: `finding_id_format_or_uniqueness_violation`

## Hook Lock-Contention Classification (canonical)

<a id="hook-lock-contention-classification-canonical"></a>

`local-wm-update.sh` / `issue-comment-wm-sync.sh` などの hook が stderr に出力するメッセージから「lock contention (best-effort skip 許容)」と「non-lock failure (WARNING + stderr 表示義務)」を分類する canonical pattern。`review.md` Phase 6.2 / 6.4 と `fix.md` Phase 4.5 / 8.1 の 4 箇所から参照される (verified-review cycle 12 H-1 対応で canonicalize)。

**Canonical pattern** (grep 式):

```bash
grep -qiE '(file is locked|lock contention|resource busy)' "$err_file"
```

**Usage sites** (drift 防止のため新規箇所追加時は本リストに登録すること):

| Site | Purpose |
|------|---------|
| `review.md` Phase 6.2 Step 2 (`issue-comment-wm-sync`) | Phase 遷移時の backup sync |
| `review.md` Phase 6.4 (`_rite_review_p64_run_sync` helper) | Phase 6.4 の 3 step 全てで本 helper が参照 |
| `fix.md` Phase 4.5 (`local-wm-update.sh`) | 修正後の local work memory 更新 |
| `fix.md` Phase 8.1 (`local-wm-update.sh` post-fix sync) | E2E flow 経路の post-fix work memory 更新 |

**Rationale for exact phrase match**: 旧 loose pattern `grep -qiE 'lock|contention|busy'` は以下の silent suppression 問題を抱えていた:

- `permission denied` を含むメッセージは match しないが、hook が `"device busy"` / `"resource busy"` / `"file is busy"` を emit するとすべて silent に「lock contention best-effort skip」に落ちていた
- NFS timeout のメッセージに `"busy"` が含まれる経路
- 将来 hook の error message が翻訳や refactor で `"locked directory"` 等に変わった場合の false-positive 拡大 (単語単位 substring match は脆い)

これらを防ぐため、exact phrase match の厳格化された regex に統一する (cycle 10 S-1 で `review.md` の Step 2 以外には適用されたが、本 cycle 12 H-1 で 4 箇所全てに波及)。

**Non-lock failure (本 pattern が match しない) 時の責務**: WARNING + hook stderr 先頭 5 行の表示 (`head -5 "$err_file" | sed 's/^/  /' >&2`)、および「対処: hook の存在 / 実行権限 / 内容を確認してください」の案内を追加する。詳細は各 Usage site の実装例を参照。
