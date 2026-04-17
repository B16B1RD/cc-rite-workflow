# /rite:issue:create end-to-end smoke test

**Issue**: #552 / Extends: #525

本書は `/rite:issue:create` の「sub-skill return 直後の自動継続」と「ユーザー向け完了メッセージ」を検証するための手動 smoke test 手順を定める。既存の Phase 5.4.4.1 sentinel detection と異なり、回帰検出のために人間の目視確認が必要な項目を列挙する。

## 目的

#552 で修正した 2 種類の回帰を検知する:

- **Bug1**: `/rite:issue:create` orchestrator が sub-skill return 直後に同 turn 内で次 phase に進まず、ユーザーの `continue` 介入を要求する自動継続停止
- **Bug2**: 最終出力の `[create:completed:{N}]` sentinel がユーザー向け完了シグナルとして不十分で、「完了したのか途中なのか」判別困難

## 前提条件

- cc-rite-workflow のローカル版が有効（`rite@rite-marketplace: false`、ドッグフーディング注意事項参照）
- 対象リポジトリ: cc-rite-workflow 本体または別のテストリポジトリ
- テスト実行前に `.rite-flow-state` が存在しないか `active: false` であること

## シナリオ 1: Bug Fix preset（Phase 0.5 スキップ経路）

**AC-1 / AC-6 / AC-7 を検証する最小シナリオ**

### 手順

1. 新規セッションで以下を実行:
   ```
   /rite:issue:create バグ修正: XXX が発生する場合の処理を追加
   ```
   入力には `バグ` / `bug` / `修正` 等のキーワードを含め、Phase 0.4 で Bug Fix goal classification が推定されるようにする。

2. Phase 0.1.5 の parent pre-detection で「No」を選択（単一 Issue として作成）

3. Phase 0.3 の duplicate search で新規作成として続行

4. Phase 0.4 の goal classification で「既存機能のバグ修正」を選択

5. interview が自動的にスキップされ、Phase 0.6 → create-register に到達することを確認

### 期待される動作

- **同 turn 内で**以下の順序で出力が完了する:
  1. `[interview:skipped]` 返却
  2. Phase 0.6 評価 → Delegation Routing の Pre-write
  3. `rite:issue:create-register` が自動起動
  4. Issue body 確認ダイアログ → 承認
  5. Projects 登録
  6. `✅ Issue #{N} を作成しました: {url}` （#552 新規）
  7. `次のステップ: ...` ブロック
  8. `[create:completed:{N}]` （最終行）

- ユーザーが `continue` を入力する必要がない
- Issue が GitHub 上に実際に作成される

### 失敗時の確認項目

| 症状 | 確認先 |
|------|--------|
| `[interview:skipped]` 後に turn が終了 | `.rite-flow-state` が `create_post_interview` で active:true のまま残存 → stop-guard が block していたか診断 log `.rite-stop-guard-diag.log` で確認 |
| `✅ Issue #{N}` が出力されない | `create-register.md` Phase 4.2 の完了メッセージセクションが最新版か確認 |
| `[create:completed:{N}]` が最終行でない | `create-register.md` Phase 4.3 以降の出力順序確認 |

## シナリオ 2: Feature preset（Phase 0.5 フル実施経路）

**AC-2 / AC-5 / AC-6 を検証する**

### 手順

1. 新規セッションで以下を実行:
   ```
   /rite:issue:create feature: 新しい XXX 機能を追加
   ```

2. Phase 0.1.5 pre-detection で「No」を選択

3. Phase 0.3 で新規作成として続行

4. Phase 0.4 で「新機能の追加」を選択

5. Phase 0.4.1 で M complexity 程度を想定（files 2-5）

6. Phase 0.5 interview に回答（5-10 回のラウンド）

7. 「ない、この内容で進めてください」で interview 終了

8. Phase 0.6 で「単一 Issue として作成」を選択

9. `create-register` 自動起動を観察

### 期待される動作

- interview 終了後、同 turn 内で Phase 0.6 → `create-register` に進行
- シナリオ 1 と同様、`✅ Issue #{N} を作成しました` + 次のステップ + `[create:completed:{N}]` が出力される
- ユーザーの `continue` 介入なし

## シナリオ 3: AC-4 後方互換性 grep 確認

**AC-4 を検証する（自動検証可能）**

### 手順

```bash
# sentinel marker 形式が従来通り `[create:completed:{N}]` であることを確認
grep -rn '\[create:completed:' plugins/ docs/ 2>/dev/null
```

### 期待される動作

- 全ての出現箇所で `[create:completed:{数字}]` または `[create:completed:{N}]` のプレースホルダー形式
- 形式変更 (例: `[create:done:...]` / `[issue:created:...]` 等) が存在しない

## シナリオ 4: AC-7 stop-guard incident emit 検証（3 phase 網羅）

**AC-7 を検証する（manual の stop attempt を 3 phase (`create_post_interview` / `create_delegation` / `create_post_delegation`) それぞれで再現）**

AC-7 は 3 つの phase いずれでも emit されることを要求するため、以下 Scenario 4a/4b/4c を全て実施する。各 Scenario で flow-state を手動生成せず、`flow-state-update.sh` 経由で公式 schema に合わせることで regression を防ぐ。

### 共通前提

flow-state は以下のいずれかの方法で正しい schema (`active`, `issue_number`, `branch`, `phase`, `previous_phase`, `pr_number`, `parent_issue_number`, `next_action`, `updated_at`, `session_id`, `last_synced_phase`) が生成される:

- **推奨**: `bash plugins/rite/hooks/flow-state-update.sh create --phase {phase} --issue 0 --branch "" --pr 0 --next "test"`
- **手動作成する場合**: 実 schema (11 フィールド) をすべて含める必要がある。不足フィールドがあると `phase-transition-whitelist.sh` / `jq` の parse で fail するか silent skip される

### Scenario 4a: `create_post_interview` phase

1. flow-state を初期化:
   ```bash
   bash plugins/rite/hooks/flow-state-update.sh create \
     --phase "create_post_interview" --issue 0 --branch "" --pr 0 \
     --next "Proceed to Phase 0.6 (Task Decomposition Decision)"
   ```
2. Claude Code で `/clear` → 空のメッセージで stop 試行
3. 期待: stop-guard が exit 2 で block、`manual_fallback_adopted` sentinel が stderr に echo される

### Scenario 4b: `create_delegation` phase

1. flow-state を遷移:
   ```bash
   bash plugins/rite/hooks/flow-state-update.sh patch \
     --phase "create_delegation" \
     --next "Wait for sub-skill (create-register or create-decompose) to output completion report"
   ```
2. stop 試行 → 上記と同様に sentinel が stderr に echo されることを確認

### Scenario 4c: `create_post_delegation` phase

1. flow-state を遷移:
   ```bash
   bash plugins/rite/hooks/flow-state-update.sh patch \
     --phase "create_post_delegation" \
     --next "Sub-skill completed. Deactivate flow state and output next steps."
   ```
2. stop 試行 → 同様に sentinel が stderr に echo されることを確認

### 期待される動作（全 Scenario 共通）

- stop-guard が exit 2 で block し、CREATE_HINT を含むメッセージを stderr に出力
- `workflow-incident-emit.sh` から capture した `[CONTEXT] WORKFLOW_INCIDENT=1; type=manual_fallback_adopted; ...` sentinel line が stderr に echo される（stop-hook stderr は Claude Code の exit-2 契約で assistant にフィードされる）
- diag log (`.rite-stop-guard-diag.log`) に `incident_emit type=manual_fallback_adopted rc=0 sentinel_captured=1 phase={phase}` が記録される

### 検証コマンド

```bash
# 1. diag log で emit 成否を確認（sentinel_captured=1 なら成功、=0 なら helper 呼び出し失敗）
tail -10 .rite-stop-guard-diag.log | grep incident_emit

# 2. stderr 出力で sentinel line を確認 (現行実装では .rite/workflow-incidents/ ディレクトリは作成されない。
#    sentinel は stderr のみで届く — stop-guard が exit 2 で stderr を assistant にフィードした後、
#    Phase 5.4.4.1 が会話コンテキストを grep して検出する仕組み)
# 実行後、Claude Code 側の会話コンテキスト (assistant response) に sentinel が現れることを目視確認
```

### 失敗時の確認項目

| 症状 | 確認先 |
|------|--------|
| sentinel_captured=0 の log が残る | `plugins/rite/hooks/workflow-incident-emit.sh` の実行権限 / shebang / 構文を確認 |
| diag log に `incident_emit` 行が全く残らない | `CREATE_INCIDENT_TYPE` が set されていない = `CREATE_HINT` が空 → 該当 phase が case 分岐に含まれているか確認 |
| stderr に sentinel が現れない | stop-guard.sh で stdout ではなく stderr への echo リダイレクトが正しいか確認 (`>&2`) |

## 回帰検出のトリガー

以下の修正 PR 後に本 smoke test を最低 1 回実施すること:

- `plugins/rite/commands/issue/create.md`
- `plugins/rite/commands/issue/create-interview.md`
- `plugins/rite/commands/issue/create-register.md`
- `plugins/rite/commands/issue/create-decompose.md`
- `plugins/rite/hooks/stop-guard.sh`

## 実施記録テンプレート

```markdown
### Smoke test 実施記録

- 実施日: YYYY-MM-DD
- 実施者: @username
- シナリオ: 1 / 2 / 3 / 4
- 結果: PASS / FAIL
- 観察事項: （自由記述）
- 関連 PR: #{number}
```
