# /rite:issue-create end-to-end smoke test

本書は `/rite:issue-create` の「sub-skill return 直後の自動継続」と「ユーザー向け完了メッセージ」を検証するための手動 smoke test 手順を定める。かつて存在した `start.md` ステップ 8.5 sentinel detection (その後機構撤去され、start.md 自体も削除済) と異なり、回帰検出のために人間の目視確認が必要な項目を列挙する。

## 目的

以下の 2 種類の回帰を検知する:

- **Bug1**: `/rite:issue-create` orchestrator が sub-skill return 直後に同 turn 内で次 phase に進まず、ユーザーの `continue` 介入を要求する自動継続停止
- **Bug2**: 最終出力の `[create:returned-to-caller:{N}]` sentinel (旧形式は `[create:completed:{N}]` で、後にこの名前へ rename された) がユーザー向け完了シグナルとして不十分で、「完了したのか途中なのか」判別困難

## 前提条件

- cc-rite-workflow のローカル版が有効（`rite@rite-marketplace: false`、ドッグフーディング注意事項参照）
- 対象リポジトリ: cc-rite-workflow 本体または別のテストリポジトリ
- テスト実行前に `.rite-flow-state` が存在しないか `active: false` であること

## シナリオ 1: Single Issue path（ステップ 4 経路）

**AC-1 / AC-6 を検証する最小シナリオ。flat workflow の規模ヒューリスティック（ステップ 3.1）が「単一 Issue」と判定するケース。**

### 手順

1. 新規セッションで以下を実行:
   ```
   /rite:issue-create バグ修正: XXX が発生する場合の処理を追加
   ```
   distinct change が単一かつ scope keyword なしの入力にし、ステップ 3.1 で「大型タスク候補」に該当しないようにする。

2. ステップ 2 の duplicate search で新規作成として続行

3. ステップ 3.1 で単一 Issue 判定 → ステップ 4 へ自動遷移

4. ステップ 4.1 の AskUserQuestion で title / type=fix / priority / complexity=S-M / labels を確認

5. ステップ 4.3 で Issue 作成 + Projects 登録の実行を観察

### 期待される動作

- **同 turn 内で** 以下の順序で出力が完了する:
  1. ステップ 2 重複候補表示 → 新規作成選択
  2. ステップ 3.1 規模判定 → 単一 Issue
  3. ステップ 4.1 Issue 情報確認 → 承認
  4. ステップ 4.3 `create-issue-with-projects.sh` 実行
  5. ステップ 4.4 `✅ Issue #{N} を作成しました` テーブル + 次のアクション
  6. `<!-- skill return signal: caller must continue next step -->` + `<!-- [create:returned-to-caller:{N}] -->` の 2 行 HTML コメント sentinel (ステップ 4.4 末尾、user-visible な最終行は完了メッセージ。旧 `[create:completed:{N}]` から rename された形式で、active disambiguation marker を併記)

- ユーザーが `continue` を入力する必要がない
- Issue が GitHub 上に実際に作成され、Projects に Status=Todo / Priority / Complexity が設定される

### 失敗時の確認項目

| 症状 | 確認先 |
|------|--------|
| ステップ 4 到達後 turn が終了 | `.rite-flow-state-diag.log` の `flow_state_*` 行を確認し、かつて存在した `start.md ステップ 8.5 retrospective scan` 相当の遡及検出 (機構撤去済 — 現行は手動で会話コンテキストを grep) が `manual_fallback_adopted` を拾ったか確認 |
| `✅ Issue #{N}` が出力されない | `skills/issue-create/SKILL.md` ステップ 4.4 のテンプレートが現行版か確認 |
| `[create:returned-to-caller:{N}]` が user-visible な最終行になる | ステップ 4.4 / 5.6 完了レポート末尾の出力順序を確認（sentinel は HTML コメント化されているか。旧 `[create:completed:{N}]` から rename された形式） |
| Projects 登録が `failed` | `create-issue-with-projects.sh` の戻り値 `project_registration` を確認、AskUserQuestion で retry / skip を選択 |
| helper が `issue-create gate` で止まり Issue が作られない | stderr の `不足:` の step について、ステップ 2 / 4.1 / 4.2.1（分解は 5.1.1 / 5.2）の `issue-create-gate.sh record` が実行されたか確認 |

## シナリオ 2: Decompose path（ステップ 5 経路）

**AC-2 / AC-5 / AC-6 を検証する。flat workflow の規模ヒューリスティック（ステップ 3.1）が「大型タスク」と判定するケース。**

### 手順

1. 新規セッションで以下を実行:
   ```
   /rite:issue-create プロジェクト全体に auth, logging, caching を一括導入
   ```
   distinct change を複数 + scope keyword（"全体" / "一括"）を含め、ステップ 3.1 の大型タスク判定を発火させる。

2. ステップ 2 で新規作成として続行

3. ステップ 3.1 で大型タスク候補と判定

4. ステップ 3.2 AskUserQuestion で「Sub-Issue に分解（推奨）」を選択 → ステップ 5 へ

5. ステップ 5 で親 Issue + Sub-Issue 群の作成を観察（実装は `create.md` ステップ 5 を参照）

### 期待される動作

- ステップ 3.2 選択後、同 turn 内でステップ 5 に進行
- ステップ 5.6 `✅ Issue #{parent_issue_number} を分解して {sub_count} 件の Sub-Issue を作成しました` テーブル出力
- ステップ 5.6 完了レポート末尾 + `<!-- skill return signal: caller must continue next step -->` + `<!-- [create:returned-to-caller:{parent_issue_number}] -->` の 2 行 HTML sentinel (旧 `[create:completed:{N}]` から rename された形式で、active disambiguation marker を併記)
- ユーザーの `continue` 介入なし

## シナリオ 3: AC-4 後方互換性 grep 確認

**AC-4 を検証する（自動検証可能）**

### 手順

```bash
# sentinel marker 形式が `[create:returned-to-caller:{N}]` であることを確認
# (旧 `:completed` 形式から rename された。本コマンドは新形式の存在を grep で pin する。)
grep -rn '\[create:returned-to-caller:' plugins/ docs/ 2>/dev/null

# 旧形式の残存がないことも確認 (AC-1: 旧 sentinel literal 0 件)
# suffix を持つ形式 (`[create:completed:{N}]` / `[lint:completed:auto]`) も含めて全形式を捕捉するため
# 固定文字列 (`grep -rnF ':completed]'`) ではなく regex を使う。固定文字列 `:completed]` は末尾 `]` が
# `completed` 直後の形式 (`[ingest:completed]` 等) しかマッチせず、suffix を持つ create/lint 形式を取り逃す。
grep -rnE '\[[a-z]+:completed(:[^]]*)?\]' plugins/rite/commands/ plugins/rite/skills/ 2>/dev/null
```

### 期待される動作

- 全ての出現箇所で `[create:returned-to-caller:{数字}]` または `[create:returned-to-caller:{N}]` のプレースホルダー形式 (旧 `:completed` 形式から rename された)
- 形式変更 (例: `[create:done:...]` / `[issue:created:...]` / `[create:completed:...]` (旧形式の意図しない残存) 等) が存在しない
- 2 つ目の `grep -rnE '\[[a-z]+:completed(:[^]]*)?\]'` コマンドが 0 件を返す (AC-1: `plugins/rite/commands/` および `plugins/rite/skills/` 配下に旧 sentinel literal の残存なし)。本 regex は suffix なし形式 (`[ingest:completed]` / `[cleanup:completed]` / `[ready:completed]` / `[merge:completed]`) と suffix あり形式 (`[create:completed:{N}]` / `[lint:completed:auto]`) の両方を捕捉する

## シナリオ 4: AC-7 retrospective scan による `manual_fallback_adopted` 検出

**AC-7 を検証する（implicit stop が起きた場合に次セッションが retrospective scan で sentinel を拾えるか）**

> **⚠️ Historical (廃止済機構のテスト手順)**: 本シナリオが前提とする `start.md ステップ 8.5 retrospective scan` は機構撤去され、start.md 自体も削除済。v3 では各 caller が plain な `WARNING` / `ERROR` を stderr に出力し、中断作業は `/rite:recover` で復帰する。tracking Issue の auto-register 経路は現行体系に存在しないため、本シナリオの手順 3 / 期待される動作 1 行目は実行不能。session-end.sh の legacy glob fallback 契約 (Scenario 4a の本来の検証対象) のみ現行でも有効。

flat workflow への移行後、Stop hook による exit-2 block は廃止された。AC-7 の責務は、かつて存在した `start.md ステップ 8.5 retrospective scan` が次セッションの会話コンテキストを grep して `manual_fallback_adopted` 系 sentinel を検出し tracking Issue を auto-register する経路に移行していた (同経路も上記の通り削除済)。

### 共通前提

flow-state は `flow-state.sh` 経由で生成する (手動作成は schema drift の原因となる):

- 推奨: `bash plugins/rite/hooks/flow-state.sh set --phase {phase} --issue 0 --branch "" --pr 0 --next "test"`

### Scenario 4a: implicit stop シミュレート

> **Note**: 本シナリオの `create_post_interview` は flat workflow 統合により書き込み経路が無くなった legacy phase 名。`flow-state.sh set` は forward-compat で未知 phase でも受容するため初期化は通る。本シナリオの testing 目的は、`session-end.sh` の inline glob fallback (`[[ "$_state_phase" == create_* ]]`) が legacy create_* phase を依然として検出できる契約 (forward-compat) を保証することにある。

1. flow-state を `create_post_interview` で初期化 (上記コマンド)。phase 名が legacy であることは意図的な setup
2. Claude Code で `/clear` → `/rite:issue-start <N>` を再実行し、前セッションの implicit stop を模した state を残したまま再開
3. かつて存在した start.md ステップ 8.5 retrospective scan が `manual_fallback_adopted` キーワードを会話コンテキストから検出し、tracking Issue を auto-register することを確認 (削除済 — 冒頭の Historical 注記参照。現行体系では実行不能)

### 期待される動作

- かつて存在した `start.md ステップ 8.5` 実行中に `manual_fallback_adopted` を含む sentinel が前セッション会話に存在する場合、tracking Issue が GitHub に作成される (削除済 — 現行体系では発生しない)
- `.rite-flow-state-diag.log` に `flow_state_*` 行が記録され、phase transition の経過が監査可能
- `session-end.sh` の inline glob fallback が legacy create_* phase を正しく detect する (`session-end.test.sh` TC-create-lifecycle-warn-A〜D で覆われる契約)

### 検証コマンド

```bash
# 1. diag log で flow-state 操作の rc/エラーを確認
tail -20 .rite-flow-state-diag.log

# 2. 前セッション会話の grep
# Claude Code の会話履歴 (assistant response の保存先) から sentinel を grep
# manual_fallback_adopted / [create:returned-to-caller:*] / [ready:returned-to-caller] 等の sentinel literal を確認 (旧形式は `:completed` で、後に rename された)
```

### 失敗時の確認項目

| 症状 | 確認先 |
|------|--------|
| retrospective scan が sentinel を取り逃す | かつて存在した `start.md ステップ 8.5` の grep パターン確認 (削除済 — 現行は手動 grep で代替) |
| diag log に flow-state 行が全く残らない | `flow-state.sh` の write path で mv/jq が silent fail していないか — 全 mv site で rc capture + WARNING が出ている前提で、欠落がないか確認する |
| `session-end.sh` の inline glob が legacy create_* phase を取り逃す | `session-end.test.sh` TC-create-lifecycle-warn-A〜D が PASS しているか確認 |

## 回帰検出のトリガー

以下の修正 PR 後に本 smoke test を最低 1 回実施すること:

- `plugins/rite/skills/issue-create/SKILL.md`
- かつて存在した `plugins/rite/commands/issue/start.md` (ステップ 8.5 retrospective scan — 削除済、historical 参照)
- `plugins/rite/hooks/session-end.sh`（lifecycle 未完了検出の inline glob）
- `plugins/rite/hooks/flow-state.sh`

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
